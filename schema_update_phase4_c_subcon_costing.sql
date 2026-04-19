-- ==========================================
-- [Phase 4-C] 외주 생산 관리 및 원가 배부 (SQL)
-- ==========================================

-- [1] 테이블 컬럼 확장
-- 1-1. 생산 헤더 확장
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS production_type varchar(20) DEFAULT 'INTERNAL' CHECK (production_type IN ('INTERNAL', 'SUBCON')),
ADD COLUMN IF NOT EXISTS vendor_id bigint REFERENCES public.customers(id),
ADD COLUMN IF NOT EXISTS processing_fee numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS additional_cost numeric DEFAULT 0;

-- 1-2. 생산 품목(Outputs) 확장 - 확정 시 단가 보관
ALTER TABLE public.production_outputs
ADD COLUMN IF NOT EXISTS unit_cost numeric;

-- [2] 생산 확정 RPC 고도화 (confirm_production_document)
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
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 문서 존재 및 상태 확인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;
    IF v_head.status != 'draft' THEN RETURN jsonb_build_object('success', false, 'message', 'Draft 상태인 문서만 확정 가능합니다.'); END IF;

    -- 3. 마감 여부 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') 
          AND closing_month = to_char(v_head.production_date, 'MM') 
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 이미 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 음수 재고 체크 및 총 원재료비 산출
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.product_name, p.moving_avg_cost
        FROM public.production_inputs i 
        JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        -- 재고 체크
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('재고 부족: [%s] (현재: %s, 필요: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
        
        -- 원재료 원가 합산 (현재 MAC * 투입수량)
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    -- 5. 총 제조 원가 및 배부 단가 계산
    v_total_production_cost := v_total_material_cost + COALESCE(v_head.processing_fee, 0) + COALESCE(v_head.additional_cost, 0);
    
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    
    IF v_total_output_qty > 0 THEN
        v_calculated_unit_cost := v_total_production_cost / v_total_output_qty;
    ELSE
        v_calculated_unit_cost := 0;
    END IF;

    -- 6. 수불부(inventory_transactions) 기록 및 단가 저장
    -- 6-1. 원재료 출고 (단가는 투입 시점의 MAC 적용)
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', v_head.id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    -- 6-2. 완제품 입고 (계산된 배부 단가 v_calculated_unit_cost 적용)
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', v_head.id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    -- 6-3. production_outputs에 단가 기록 (수량 비례 배부)
    UPDATE public.production_outputs 
    SET unit_cost = v_calculated_unit_cost 
    WHERE production_header_id = p_doc_id;

    -- 7. 헤더 상태 업데이트
    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    -- 8. MAC 재계산 (Inputs -> Outputs)
    FOR v_item IN (
        SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id
        UNION
        SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id
    ) LOOP
        PERFORM public.recalculate_mac_for_product(v_item.product_id);
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('생산 전표가 확정되었습니다. (제조원가: %s)', ROUND(v_calculated_unit_cost, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 생산 확정 취소 RPC 보완 (unconfirm_production_document)
CREATE OR REPLACE FUNCTION public.unconfirm_production_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
BEGIN
    -- 1. 권한 체크 (Admin 전용)
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    -- 2. 상태 확인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 취소할 수 없습니다.'); END IF;

    -- 4. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, to_jsonb(v_head));

    -- 5. 수불 삭제 및 단가 초기화
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    -- 6. 헤더 상태 환원
    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    -- 7. MAC 재재계산
    FOR v_item IN (
        SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id
        UNION
        SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id
    ) LOOP
        PERFORM public.recalculate_mac_for_product(v_item.product_id);
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '생산 확정이 취소되었으며 제조원가 기록이 초기화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
