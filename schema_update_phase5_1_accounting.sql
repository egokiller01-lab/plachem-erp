-- ==========================================
-- [Phase 5-1] 회계/AP(매입채무) 연동 (SQL)
-- ==========================================

-- [1] 기존 생산 테이블 확장 (추가비용 채무 여부 선택용)
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS is_additional_cost_payable boolean DEFAULT true;

-- [2] 매입채무 테이블 (ACCOUNTS_PAYABLE)
CREATE TABLE IF NOT EXISTS public.accounts_payable (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    vendor_id bigint NOT NULL REFERENCES public.customers(id),
    ref_type varchar(50) NOT NULL, -- 'PRODUCTION_SUBCON', 'PURCHASE'
    ref_id bigint NOT NULL,
    doc_date date NOT NULL,
    due_date date,
    total_amount numeric NOT NULL DEFAULT 0,
    paid_amount numeric NOT NULL DEFAULT 0,
    status varchar(20) NOT NULL DEFAULT 'unpaid' CHECK (status IN ('unpaid', 'partially_paid', 'paid', 'void')),
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_ap_vendor ON public.accounts_payable(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ap_ref ON public.accounts_payable(ref_type, ref_id);

-- [3] 지급 기록 테이블 (PAYMENT_RECORDS)
CREATE TABLE IF NOT EXISTS public.payment_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    ap_id bigint NOT NULL REFERENCES public.accounts_payable(id) ON DELETE CASCADE,
    payment_date date NOT NULL,
    amount numeric NOT NULL CHECK (amount > 0),
    payment_method varchar(20) NOT NULL DEFAULT 'BANK' CHECK (payment_method IN ('BANK', 'CASH', 'LINK')),
    remark text,
    created_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- [4] 생산 확정 RPC 고도화 (confirm_production_document - AP 자동 생성 추가)
-- 이미 존재하는 함수를 수정하여 AP 연동 추가
CREATE OR REPLACE FUNCTION public.confirm_production_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
    v_current_stock numeric;
    
    v_total_material_cost numeric := 0;
    v_total_production_cost numeric := 0;
    v_total_output_qty numeric := 0;
    v_calculated_unit_cost numeric := 0;
    
    v_ap_amount numeric := 0;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 문서 확인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    -- 3. 마감 확인 (생산일 기준)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 재고 체크 및 원재료비 산출
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.moving_avg_cost, p.product_name
        FROM public.production_inputs i JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('재고 부족: [%s] (현재: %s, 필요: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    -- 5. 원가 계산 및 배부
    v_total_production_cost := v_total_material_cost + COALESCE(v_head.processing_fee, 0) + COALESCE(v_head.additional_cost, 0);
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    IF v_total_output_qty > 0 THEN v_calculated_unit_cost := v_total_production_cost / v_total_output_qty; ELSE v_calculated_unit_cost := 0; END IF;

    -- 6. 수불부 기록 및 단가 저장
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', v_head.id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', v_head.id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    UPDATE public.production_outputs SET unit_cost = v_calculated_unit_cost WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] 매입채무(AP) 자동 생성
    IF v_head.production_type = 'SUBCON' AND v_head.vendor_id IS NOT NULL THEN
        -- AP 금액 결정: 가공비 + (청구분인 경우 부대비용)
        v_ap_amount := COALESCE(v_head.processing_fee, 0);
        IF COALESCE(v_head.is_additional_cost_payable, true) THEN
            v_ap_amount := v_ap_amount + COALESCE(v_head.additional_cost, 0);
        END IF;

        IF v_ap_amount > 0 THEN
            INSERT INTO public.accounts_payable (vendor_id, ref_type, ref_id, doc_date, total_amount, status, created_by)
            VALUES (v_head.vendor_id, 'PRODUCTION_SUBCON', v_head.id, v_head.production_date, v_ap_amount, 'unpaid', auth.uid())
            RETURNING id INTO v_ap_id;
        END IF;
    END IF;

    -- 7. 상태 업데이트 및 MAC 재계산
    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('생산 전표가 확정되었으며, 미지급금(%s)이 생성되었습니다.', ROUND(v_ap_amount, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 생산 확정 취소 RPC 고도화 (unconfirm_production_document - AP 연동 추가)
CREATE OR REPLACE FUNCTION public.unconfirm_production_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 마감 확인
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 취소할 수 없습니다.'); END IF;

    -- [Phase 5-1] 연결 AP 체크 (지급액 존재 시 차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PRODUCTION_SUBCON' AND ref_id = p_doc_id LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 대급 지급이 진행된 전표입니다. (지급액: %s) 회계 취소를 먼저 진행하세요.', v_ap_paid));
    END IF;

    -- 로그 및 수불 삭제
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, to_jsonb(v_head));
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] 연결 AP 무효화 (또는 삭제)
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable SET status = 'void', remark = '생산 확정 취소로 인한 자동 취소' WHERE id = v_ap_id;
    END IF;

    -- 상태 환원 및 MAC 재재계산
    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '생산 확정이 취서되었으며 미지급 전표가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [6] 지급 등록 RPC (register_payment)
CREATE OR REPLACE FUNCTION public.register_payment(
    p_ap_id bigint, 
    p_amount numeric, 
    p_date date, 
    p_method varchar, 
    p_remark text
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_ap_record RECORD;
    v_is_month_closed boolean;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    -- 2. 마감 확인 (지급일 기준)
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 일자의 월 마감이 완료되어 지급을 등록할 수 없습니다.'); END IF;

    -- 3. AP 존재 확인 및 잔액 체크
    SELECT * INTO v_ap_record FROM public.accounts_payable WHERE id = p_ap_id FOR UPDATE;
    IF v_ap_record IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '매입채무 정보를 찾을 수 없습니다.'); END IF;
    IF v_ap_record.status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '이미 취소된 전표입니다.'); END IF;
    
    IF (v_ap_record.total_amount - v_ap_record.paid_amount) < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', format('지급액이 미지급 잔액(%s)을 초과할 수 없습니다.', v_ap_record.total_amount - v_ap_record.paid_amount));
    END IF;

    -- 4. 지급 기록 생성
    INSERT INTO public.payment_records (ap_id, payment_date, amount, payment_method, remark, created_by)
    VALUES (p_ap_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AP 상태 및 누적 지급액 업데이트
    UPDATE public.accounts_payable 
    SET 
        paid_amount = paid_amount + p_amount,
        status = CASE 
                    WHEN (paid_amount + p_amount) >= total_amount THEN 'paid' 
                    ELSE 'partially_paid' 
                 END,
        updated_at = now()
    WHERE id = p_ap_id;

    RETURN jsonb_build_object('success', true, 'message', '지급 처리가 완료되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
