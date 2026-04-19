-- ==========================================
-- [Phase 8-2] 여신 하드 차단 및 예외 승인 (SQL)
-- ==========================================

-- [1] 여신 예외 승인 요청 테이블
CREATE TABLE IF NOT EXISTS public.credit_exception_requests (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    sales_header_id bigint NOT NULL REFERENCES public.sales_headers(id) ON DELETE CASCADE,
    requested_by uuid NOT NULL REFERENCES auth.users(id),
    status varchar(20) NOT NULL DEFAULT 'pending', -- pending, approved, rejected, void (invalidated)
    reason text NOT NULL,
    approved_by uuid REFERENCES auth.users(id),
    approver_comment text,
    processed_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credit_req_sales ON public.credit_exception_requests(sales_header_id);

-- [2] 승인 무효화 트리거 (Auto-Invalidation)
-- 전표의 거래처(customer_id)나 총액(total_amount) 변경 시 기존 승인을 void 처리
CREATE OR REPLACE FUNCTION public.trg_invalidate_credit_approval()
RETURNS TRIGGER AS $$
BEGIN
    -- 중요 필드 변경 시 기존 모든 'approved' 또는 'pending' 요청을 무효화
    IF (OLD.customer_id IS DISTINCT FROM NEW.customer_id) OR 
       (OLD.total_amount IS DISTINCT FROM NEW.total_amount) THEN
        
        UPDATE public.credit_exception_requests
        SET status = 'void', 
            approver_comment = format('데이터 변경으로 인한 자동 무효화 (이전 총액: %s -> 현재: %s)', OLD.total_amount, NEW.total_amount)
        WHERE sales_header_id = NEW.id AND status IN ('approved', 'pending');
        
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_sales_header_credit_integrity
BEFORE UPDATE ON public.sales_headers
FOR EACH ROW
EXECUTE FUNCTION public.trg_invalidate_credit_approval();

-- [3] 여신 예외 승인 처리 RPC (manage_credit_exception)
CREATE OR REPLACE FUNCTION public.manage_credit_exception(
    p_req_id bigint,
    p_action varchar, -- 'approve', 'reject'
    p_comment text
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    IF p_action = 'approve' THEN
        UPDATE public.credit_exception_requests
        SET status = 'approved', approved_by = auth.uid(), approver_comment = p_comment, processed_at = now()
        WHERE id = p_req_id AND status = 'pending';
    ELSIF p_action = 'reject' THEN
        UPDATE public.credit_exception_requests
        SET status = 'rejected', approved_by = auth.uid(), approver_comment = p_comment, processed_at = now()
        WHERE id = p_req_id AND status = 'pending';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', '처리가 완료되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [4] 매출 확정 RPC 고도화 (confirm_sales_document - Hard Block 적용)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_credit_res jsonb;
    v_is_approved boolean;
BEGIN
    -- 1. 권한 및 상태 확인
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '전표를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 전표입니다.'); END IF;

    -- 2. 여신 한도 체크 (Hard Control)
    v_credit_res := public.check_customer_credit(v_head.customer_id, v_head.total_amount);
    
    IF (v_credit_res->>'is_exceeded')::boolean THEN
        -- 예외 승인 여부 확인
        SELECT EXISTS (
            SELECT 1 FROM public.credit_exception_requests 
            WHERE sales_header_id = p_doc_id AND status = 'approved'
        ) INTO v_is_approved;

        IF NOT v_is_approved THEN
            RETURN jsonb_build_object(
                'success', false, 
                'error_type', 'CREDIT_EXCEEDED',
                'message', format('여신 한도 초과로 확정이 차단되었습니다. (관리자 승인 필요) %s', v_credit_res->>'message')
            );
        END IF;
    END IF;

    -- 3. 기존 원가 로직 및 재고 업데이트 (간략화된 예시, 실제 로직 유지 필요)
    -- ... (기존 확정 로직 수행) ...
    
    -- 상태 업데이트
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출이 정상적으로 확정되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT SELECT, INSERT ON public.credit_exception_requests TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_credit_exception TO authenticated;
