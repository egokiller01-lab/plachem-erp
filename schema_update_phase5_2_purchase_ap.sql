-- ==========================================
-- [Phase 5-2] 일반 매입(Purchase) AP 통합 (SQL)
-- ==========================================

-- [1] 매입 헤더 확장 (지급기한 추가)
ALTER TABLE public.purchase_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] 매입 확정 RPC 고도화 (confirm_purchase_document - AP 연동)
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 전표 확인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 총 매입액 산출 (공급가액 + 부가세)
    SELECT SUM(net_amount + vat_amount) INTO v_total_amount 
    FROM public.purchase_items 
    WHERE purchase_header_id = p_doc_id;

    -- 5. 매입채무(AP) 자동 생성
    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_payable (
            vendor_id, 
            ref_type, 
            ref_id, 
            doc_date, 
            due_date, 
            total_amount, 
            status, 
            remark,
            created_by
        )
        VALUES (
            v_head.supplier_id, 
            'PURCHASE', 
            v_head.id, 
            v_head.purchase_date, 
            COALESCE(v_head.due_date, v_head.purchase_date + INTERVAL '30 days'), 
            v_total_amount, 
            'unpaid', 
            format('매입전표 자동생성 (%s)', v_head.purchase_no),
            auth.uid()
        )
        RETURNING id INTO v_ap_id;
    END IF;

    -- 6. 상태 업데이트 (기존 트리거가 수불/MAC 처리함)
    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('매입 전표가 확정되었으며, 매입채무(%s)가 생성되었습니다.', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 매입 확정 취소 RPC 고도화 (unconfirm_purchase_document - AP 연동)
CREATE OR REPLACE FUNCTION public.unconfirm_purchase_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- 2. 상태 확인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- [Phase 5-2] 연결 AP 체크 (지급액 존재 시 차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
    FROM public.accounts_payable 
    WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 대급 지급이 진행된 매입 전표입니다. (지급액: %s) 회계 지급 취소를 먼저 진행하세요.', v_ap_paid));
    END IF;

    -- 4. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- [Phase 5-2] 연결 AP 무효화
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable 
        SET status = 'void', remark = format('매입 확정 취소로 인한 자동 무효화 (%s)', p_reason) 
        WHERE id = v_ap_id;
    END IF;

    -- 5. 상태 업데이트 (트리거가 재고/MAC 역반영함)
    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매입 확정이 취소되었으며 매입채무가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
