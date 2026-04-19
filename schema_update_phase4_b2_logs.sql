-- ==========================================
-- [Phase B2] Reopen & Unconfirm 기초 인프라 (Logs & RPC Skeletons)
-- ==========================================

-- [1] 전표 이력 및 마감 취소 상세 로그 테이블
CREATE TABLE IF NOT EXISTS public.document_history_logs (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    doc_type varchar(20) NOT NULL,    -- 'PURCHASE', 'SALES', 'CLOSING'
    doc_id bigint,                   -- 관련 테이블의 ID
    doc_no varchar(50),              -- 문서 번호 (참고용)
    action_type varchar(20) NOT NULL, -- 'UNCONFIRM', 'REOPEN'
    acted_by uuid REFERENCES auth.users(id),
    acted_at timestamptz DEFAULT now(),
    reason text NOT NULL,
    original_data jsonb,             -- 삭제/변경 전 전체 데이터 스냅샷
    summary text,                    -- 영향 수량/금액 요약 설명
    created_at timestamptz DEFAULT now()
);

COMMENT ON TABLE public.document_history_logs IS '전표 확정 취소 및 마감 취소 시의 상세 데이터 백업 및 감사 로그';

-- [2] 월마감 취소 RPC (reopen_monthly_closing) 보완
CREATE OR REPLACE FUNCTION public.reopen_monthly_closing(
    p_year varchar, 
    p_month varchar, 
    p_reason text, 
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_closing_id bigint;
    v_future_closed_exists boolean;
BEGIN
    -- [1] 권한 체크 (Admin 전용)
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- [2] 대상 월 존재 및 마감 상태 확인
    SELECT id INTO v_closing_id FROM public.monthly_closings 
    WHERE closing_year = p_year AND closing_month = p_month AND status = 'closed';
    
    IF v_closing_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '마감된 내역을 찾을 수 없거나 이미 Reopen 상태입니다.');
    END IF;

    -- [3] 직전 월 제한 확인 (대상 월보다 미래의 월이 마감되어 있는지 체크)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE (closing_year > p_year OR (closing_year = p_year AND closing_month > p_month))
          AND status = 'closed'
    ) INTO v_future_closed_exists;

    IF v_future_closed_exists THEN
        RETURN jsonb_build_object('success', false, 'message', '더 최근의 월이 마감되어 있어 이 월을 Reopen할 수 없습니다. (순차 소급 필요)');
    END IF;

    -- [4] 로그 기록 및 상태 변경 (실행 단계에서 구체화 가능하도록 스켈레톤 유지)
    UPDATE public.monthly_closings 
    SET status = 'draft', 
        reopen_at = now(), 
        reopen_by = p_user_uuid, 
        reopen_reason = p_reason, 
        updated_at = now() 
    WHERE id = v_closing_id;

    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason)
    VALUES ('CLOSING', v_closing_id, 'REOPEN', p_user_uuid, p_reason);

    RETURN jsonb_build_object('success', true, 'message', '성공적으로 마감이 취소되었습니다.', 'closing_id', v_closing_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- [3] 매입 확정 취소 RPC (unconfirm_purchase_document) 스켈레톤
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
BEGIN
    -- [1] 권한 체크
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- [2] 문서 존재 및 상태 확인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '이미 Draft 상태이거나 확정되지 않은 문서입니다.'); END IF;

    -- [3] 해당 월 마감 여부 확인 (Sealed 판정)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') 
          AND closing_month = to_char(v_head.purchase_date, 'MM') 
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN
        RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 수정할 수 없습니다. 먼저 월마감을 취소하십시오.');
    END IF;

    -- [4] 로그 및 데이터 스냅샷 (보완된 6단계)
    INSERT INTO public.document_history_logs (
        doc_type, doc_id, doc_no, action_type, acted_by, reason, original_data, summary
    )
    SELECT 
        'PURCHASE', 
        v_head.id, 
        v_head.purchase_no, 
        'UNCONFIRM', 
        p_user_uuid, 
        p_reason,
        jsonb_build_object(
            'header', to_jsonb(v_head),
            'items', (SELECT jsonb_agg(to_jsonb(i)) FROM public.purchase_items i WHERE i.purchase_header_id = p_doc_id)
        ),
        format('Purchase Unconfirm: %s items affected. Total Amount: %s', 
            (SELECT count(*) FROM public.purchase_items WHERE purchase_header_id = p_doc_id),
            (v_head.total_net_amount + v_head.total_vat_amount)
        );

    -- [5] 실제 상태 환원 처리 (7단계)
    UPDATE public.purchase_headers 
    SET status = 'draft', 
        updated_at = now()
    WHERE id = p_doc_id;

    -- 참고: status가 confirmed -> draft로 변경될 때 
    -- 기존 DB 트리거(trg_mac_header_update)에 의해 MAC가 자동 재계산됩니다.

    RETURN jsonb_build_object('success', true, 'message', '매입 확정 취소가 완료되었습니다. (Draft 상태로 환원됨)');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- [4] 매출 확정 취소 RPC (unconfirm_sales_document) 스켈레톤
CREATE OR REPLACE FUNCTION public.unconfirm_sales_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
BEGIN
    -- [1] 권한 체크
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- [2] 문서 존재 및 상태 확인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '이미 Draft 상태이거나 확정되지 않은 문서입니다.'); END IF;

    -- [3] 해당 월 마감 여부 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') 
          AND closing_month = to_char(v_head.sales_date, 'MM') 
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN
        RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 수정할 수 없습니다. 먼저 월마감을 취소하십시오.');
    END IF;

    -- [4] 로그 및 데이터 스냅샷 (보완된 6단계)
    INSERT INTO public.document_history_logs (
        doc_type, doc_id, doc_no, action_type, acted_by, reason, original_data, summary
    )
    SELECT 
        'SALES', 
        v_head.id, 
        v_head.sales_no, 
        'UNCONFIRM', 
        p_user_uuid, 
        p_reason,
        jsonb_build_object(
            'header', to_jsonb(v_head),
            'items', (SELECT jsonb_agg(to_jsonb(i)) FROM public.sales_items i WHERE i.sales_header_id = p_doc_id)
        ),
        format('Sales Unconfirm: %s items affected. Total Amount: %s', 
            (SELECT count(*) FROM public.sales_items WHERE sales_header_id = p_doc_id),
            (v_head.total_net_amount + v_head.total_vat_amount)
        );

    -- [5] 실제 상태 환원 및 원가 초기화 처리 (7단계)
    -- 1) 품목의 매출원가 박제 해제
    UPDATE public.sales_items 
    SET cogs_unit_price = 0 
    WHERE sales_header_id = p_doc_id;

    -- 2) 헤더 상태 변경
    UPDATE public.sales_headers 
    SET status = 'draft', 
        updated_at = now()
    WHERE id = p_doc_id;

    -- 참고: status 변경 시 트리거에 의해 MAC가 자동 재계산됩니다.

    RETURN jsonb_build_object('success', true, 'message', '매출 확정 취소가 완료되었습니다. (원가 고정 해제 및 Draft 환원됨)');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
