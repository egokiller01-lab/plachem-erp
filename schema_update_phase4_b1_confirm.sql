-- ==========================================
-- [Phase B1] 매입/매출 확정 권한 통제 (RPC & RLS)
-- ==========================================

-- [1] 전표 헤더 테이블 RLS 설정
-- 매입 헤더
ALTER TABLE public.purchase_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "PH_Select" ON public.purchase_headers;
DROP POLICY IF EXISTS "PH_Insert" ON public.purchase_headers;
DROP POLICY IF EXISTS "PH_Edit_Draft" ON public.purchase_headers;

CREATE POLICY "PH_Select" ON public.purchase_headers FOR SELECT TO authenticated USING ( true );
CREATE POLICY "PH_Insert" ON public.purchase_headers FOR INSERT TO authenticated WITH CHECK ( status = 'draft' );
CREATE POLICY "PH_Edit_Draft" ON public.purchase_headers FOR UPDATE TO authenticated 
USING ( status = 'draft' ) WITH CHECK ( status = 'draft' );

-- 매출 헤더
ALTER TABLE public.sales_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "SH_Select" ON public.sales_headers;
DROP POLICY IF EXISTS "SH_Insert" ON public.sales_headers;
DROP POLICY IF EXISTS "SH_Edit_Draft" ON public.sales_headers;

CREATE POLICY "SH_Select" ON public.sales_headers FOR SELECT TO authenticated USING ( true );
CREATE POLICY "SH_Insert" ON public.sales_headers FOR INSERT TO authenticated WITH CHECK ( status = 'draft' );
CREATE POLICY "SH_Edit_Draft" ON public.sales_headers FOR UPDATE TO authenticated 
USING ( status = 'draft' ) WITH CHECK ( status = 'draft' );


-- [2] 확정 전용 RPC 함수 (보안 로직)
-- 매입 확정 RPC
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_status text;
BEGIN
    -- 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 상태 체크
    SELECT status INTO v_status FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;
    IF v_status != 'draft' THEN RETURN jsonb_build_object('success', false, 'message', 'Draft 상태인 문서만 확정 가능합니다.'); END IF;

    -- 상태 업데이트 (트리거가 반응하여 재고/MAC 자동 반영함)
    UPDATE public.purchase_headers SET status = 'confirmed' WHERE id = p_doc_id;
    
    RETURN jsonb_build_object('success', true, 'message', '매입이 성공적으로 확정되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 매출 확정 RPC
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_status text;
BEGIN
    -- 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 상태 체크
    SELECT status INTO v_status FROM public.sales_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;
    IF v_status != 'draft' THEN RETURN jsonb_build_object('success', false, 'message', 'Draft 상태의 전표만 확정할 수 있습니다.'); END IF;

    -- 상태 업데이트
    UPDATE public.sales_headers SET status = 'confirmed' WHERE id = p_doc_id;
    
    RETURN jsonb_build_object('success', true, 'message', '매출이 성공적으로 확정되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- [3] 함수 실행 권한 설정
REVOKE ALL ON FUNCTION public.confirm_purchase_document FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_sales_document FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_purchase_document TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_sales_document TO authenticated;
