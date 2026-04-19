-- ==========================================
-- [Phase 4-B] 생산 실시간 재고 연동 (RPC & MAC)
-- ==========================================

-- [1] 권한 체크용 헬퍼 함수 (이미 존재할 가능성이 높으나 보장용)
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text AS $$
    SELECT role FROM public.profiles WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER;

-- [2] 생산 확정 RPC (confirm_production_document)
CREATE OR REPLACE FUNCTION public.confirm_production_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
    v_current_stock numeric;
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

    -- 3. 해당 월 마감 여부 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') 
          AND closing_month = to_char(v_head.production_date, 'MM') 
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN
        RETURN jsonb_build_object('success', false, 'message', '해당 월이 이미 마감되어 확정할 수 없습니다.');
    END IF;

    -- 4. 음수 재고 체크 (Strict Prohibit)
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.product_name 
        FROM public.production_inputs i 
        JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        -- 현재 재고 조회 (v_product_stock 뷰 활용)
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('재고 부족: [%s] (현재: %s, 필요: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
    END LOOP;

    -- 5. 수불부(inventory_transactions) 기록
    -- 5-1. 원재료 출고
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', v_head.id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    -- 5-2. 완제품 입고
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', v_head.id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    -- 6. 헤더 상태 업데이트
    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    -- 7. MAC 재계산 (Inputs -> Outputs 순서)
    -- Inputs
    FOR v_item IN SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id LOOP
        PERFORM public.recalculate_mac_for_product(v_item.product_id);
    END LOOP;
    -- Outputs
    FOR v_item IN SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id LOOP
        PERFORM public.recalculate_mac_for_product(v_item.product_id);
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '생산 전표가 성공적으로 확정되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 생산 확정 취소 RPC (unconfirm_production_document)
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
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- 2. 문서 존재 및 상태 확인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 3. 해당 월 마감 여부 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') 
          AND closing_month = to_char(v_head.production_date, 'MM') 
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN
        RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 취소할 수 없습니다. 먼저 마감을 취소하십시오.');
    END IF;

    -- 4. 로그 기록 (Snapshot)
    INSERT INTO public.document_history_logs (doc_type, doc_id, doc_no, action_type, acted_by, reason, original_data)
    VALUES (
        'PRODUCTION', 
        p_doc_id, 
        v_head.production_no, 
        'UNCONFIRM', 
        auth.uid(), 
        p_reason,
        jsonb_build_object(
            'header', to_jsonb(v_head),
            'inputs', (SELECT jsonb_agg(to_jsonb(i)) FROM public.production_inputs i WHERE i.production_header_id = p_doc_id),
            'outputs', (SELECT jsonb_agg(to_jsonb(o)) FROM public.production_outputs o WHERE o.production_header_id = p_doc_id)
        )
    );

    -- 5. 수불부(inventory_transactions) 삭제
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;

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

    RETURN jsonb_build_object('success', true, 'message', '생산 확정이 취소되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] MAC 엔진 고도화 (Production 수불 반영)
-- 기존 recalculate_mac_for_product 함수를 수정하여 inventory_transactions의 PROD 내역을 포함시킵니다.
CREATE OR REPLACE FUNCTION public.recalculate_mac_for_product(p_product_id bigint)
RETURNS void AS $$
DECLARE
    v_stock numeric := 0;
    v_mac numeric := 0;
    v_record RECORD;
    v_last_snapshot_date date := '1900-01-01'::date;
BEGIN
    -- Baseline 확보
    SELECT snapshot_date, qty, avg_cost INTO v_last_snapshot_date, v_stock, v_mac
    FROM public.inventory_valuation_snapshots
    WHERE product_id = p_product_id
    ORDER BY snapshot_date DESC, id DESC LIMIT 1;

    v_last_snapshot_date := COALESCE(v_last_snapshot_date, '1900-01-01'::date);
    v_stock := COALESCE(v_stock, 0);
    v_mac := COALESCE(v_mac, 0);

    FOR v_record IN
        SELECT txn_date, created_at, txn_type, qty, net_unit_price, adj_value
        FROM (
            SELECT ph.purchase_date AS txn_date, ph.created_at, 'IN' AS txn_type, pi.qty, pi.net_unit_price, 0 AS adj_value
            FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
            WHERE pi.product_id = p_product_id AND ph.status = 'confirmed' AND ph.purchase_date > v_last_snapshot_date
            UNION ALL
            SELECT sh.sales_date AS txn_date, sh.created_at, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price, 0 AS adj_value
            FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
            WHERE si.product_id = p_product_id AND sh.status = 'confirmed' AND sh.sales_date > v_last_snapshot_date
            UNION ALL
            SELECT adj_date AS txn_date, created_at, 'ADJ' AS txn_type, adj_qty AS qty, 0 AS net_unit_price, adj_value
            FROM public.inventory_adjustments
            WHERE product_id = p_product_id AND adj_date > v_last_snapshot_date
            UNION ALL
            -- [Production 반영]
            SELECT txn_date, created_at, 
                   CASE WHEN qty_in > 0 THEN 'IN' ELSE 'OUT' END AS txn_type,
                   COALESCE(qty_in, qty_out) AS qty,
                   0 AS net_unit_price, 0 AS adj_value
            FROM public.inventory_transactions
            WHERE product_id = p_product_id AND ref_table = 'production_headers' AND txn_date > v_last_snapshot_date
        ) combined_txns
        ORDER BY txn_date ASC, created_at ASC
    LOOP
        IF v_record.txn_type = 'IN' THEN
            IF (v_stock + v_record.qty) > 0 THEN
                v_mac := ((v_stock * v_mac) + (v_record.qty * v_record.net_unit_price)) / (v_stock + v_record.qty);
            ELSE
                v_mac := v_record.net_unit_price;
            END IF;
            v_stock := v_stock + v_record.qty;
        ELSIF v_record.txn_type = 'OUT' THEN
            v_stock := v_stock - v_record.qty;
        ELSIF v_record.txn_type = 'ADJ' THEN
            IF (v_stock + v_record.qty) > 0 THEN v_mac := ((v_stock * v_mac) + v_record.adj_value) / (v_stock + v_record.qty); END IF;
            v_stock := v_stock + v_record.qty;
        END IF;
    END LOOP;

    UPDATE public.products SET moving_avg_cost = ROUND(v_mac, 2) WHERE id = p_product_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 보안 강화 (RLS WITH CHECK)
ALTER TABLE public.production_inputs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.production_outputs ENABLE ROW LEVEL SECURITY;

-- 기존 정책 제거
DROP POLICY IF EXISTS "PI_Write_If_Draft" ON public.production_inputs;
DROP POLICY IF EXISTS "PO_Write_If_Draft" ON public.production_outputs;

-- 신규 정책: 헤더가 draft 상태일 때만 수정/삭제 가능
CREATE POLICY "PI_Manage_If_Draft" ON public.production_inputs FOR ALL TO authenticated
USING ( EXISTS (SELECT 1 FROM public.production_headers h WHERE h.id = production_inputs.production_header_id AND h.status = 'draft') )
WITH CHECK ( EXISTS (SELECT 1 FROM public.production_headers h WHERE h.id = production_inputs.production_header_id AND h.status = 'draft') );

CREATE POLICY "PO_Manage_If_Draft" ON public.production_outputs FOR ALL TO authenticated
USING ( EXISTS (SELECT 1 FROM public.production_headers h WHERE h.id = production_outputs.production_header_id AND h.status = 'draft') )
WITH CHECK ( EXISTS (SELECT 1 FROM public.production_headers h WHERE h.id = production_outputs.production_header_id AND h.status = 'draft') );
