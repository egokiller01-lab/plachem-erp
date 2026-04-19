-- ==========================================
-- [Phase B2] Inventory Adjustment Schema & Logic Integration
-- ==========================================

-- [1] 재고/원가 조정 전표 테이블
CREATE TABLE IF NOT EXISTS public.inventory_adjustments (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    adj_no varchar(50) UNIQUE,
    adj_date date NOT NULL DEFAULT CURRENT_DATE,
    adj_type varchar(10) NOT NULL CHECK (adj_type IN ('STOCK', 'COST', 'BOTH')),
    product_id bigint NOT NULL REFERENCES public.products(id),
    adj_qty numeric DEFAULT 0,    -- 수량 보정분 (+/-)
    adj_value numeric DEFAULT 0,  -- 금액/원가 보정분 (+/-)
    reason text NOT NULL,
    created_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- [2] MAC 재계산 함수 보완 (inventory_adjustments 반영)
-- 기존 schema_update_phase2.sql의 recalculate_mac_for_product를 대체/보완합니다.
CREATE OR REPLACE FUNCTION public.recalculate_mac_for_product(p_product_id bigint)
RETURNS void AS $$
DECLARE
    v_stock numeric := 0;
    v_mac numeric := 0;
    v_record RECORD;
    v_last_snapshot_date date := '1900-01-01'::date;
BEGIN
    -- Baseline 확보 (가장 최근 마감 스냅샷)
    SELECT snapshot_date, qty, avg_cost INTO v_last_snapshot_date, v_stock, v_mac
    FROM public.inventory_valuation_snapshots
    WHERE product_id = p_product_id
    ORDER BY snapshot_date DESC, id DESC LIMIT 1;

    v_last_snapshot_date := COALESCE(v_last_snapshot_date, '1900-01-01'::date);
    v_stock := COALESCE(v_stock, 0);
    v_mac := COALESCE(v_mac, 0);

    -- 수불 내역 + 조정 내역 통합 순차 재계산
    FOR v_record IN
        SELECT txn_date, created_at, txn_type, qty, net_unit_price, adj_value
        FROM (
            -- 1) 매입
            SELECT ph.purchase_date AS txn_date, ph.created_at, 'IN' AS txn_type, pi.qty, pi.net_unit_price, 0 AS adj_value
            FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
            WHERE pi.product_id = p_product_id AND ph.status = 'confirmed' AND ph.purchase_date > v_last_snapshot_date
            UNION ALL
            -- 2) 매출
            SELECT sh.sales_date AS txn_date, sh.created_at, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price, 0 AS adj_value
            FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
            WHERE si.product_id = p_product_id AND sh.status = 'confirmed' AND sh.sales_date > v_last_snapshot_date
            UNION ALL
            -- 3) 조정 (Adjustment)
            SELECT adj_date AS txn_date, created_at, 'ADJ' AS txn_type, adj_qty AS qty, 0 AS net_unit_price, adj_value
            FROM public.inventory_adjustments
            WHERE product_id = p_product_id AND adj_date > v_last_snapshot_date
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
            -- 조정 (Adjustment): STOCK 보정 및 원가/금액 직접 보정 차액 반영
            -- 수량 보정: v_stock 증감
            -- 금액 보정: (v_stock * v_mac) + v_record.adj_value
            IF (v_stock + v_record.qty) > 0 THEN
                v_mac := ((v_stock * v_mac) + v_record.adj_value) / (v_stock + v_record.qty);
            END IF;
            v_stock := v_stock + v_record.qty;
        END IF;

        IF v_stock < 0 THEN
            -- 음수 재고 허용 여부는 정책에 따르나, Adjustment 시점에는 로그만 남기거나 차단
            -- RAISE EXCEPTION 'Negative stock detected for product ID %', p_product_id;
        END IF;
    END LOOP;

    UPDATE public.products SET moving_avg_cost = ROUND(v_mac, 2) WHERE id = p_product_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- [3] 월마감 검증 함수 보완 (inventory_adjustments 반영)
-- validate_monthly_closing 내의 시뮬레이션 루프에 ADJ 트래픽을 추가합니다.
CREATE OR REPLACE FUNCTION public.validate_monthly_closing(p_year varchar, p_month varchar)
RETURNS jsonb AS $$
DECLARE
    v_start_date date := (p_year || '-' || p_month || '-01')::date;
    v_end_date date := v_start_date + interval '1 month' - interval '1 day';
    v_prior_month date := v_start_date - interval '1 month';
    v_prior_year varchar := to_char(v_prior_month, 'YYYY');
    v_prior_month_str varchar := to_char(v_prior_month, 'MM');
    
    v_errors jsonb := '[]'::jsonb;
    v_unconfirmed_docs jsonb;
    v_mismatched_totals jsonb;
    
    v_negative_stocks jsonb := '[]'::jsonb;
    v_null_macs jsonb := '[]'::jsonb;
    v_missing_baselines jsonb := '[]'::jsonb;
    
    v_prior_closed boolean;
    v_prod RECORD; v_txn RECORD;
    v_prior_closing_id bigint;
    
    v_opening_qty numeric; v_opening_mac numeric;
    v_ending_qty numeric; v_ending_mac numeric;
    v_has_baseline boolean; v_txn_count int; v_is_negative boolean;
BEGIN
    -- [1] 이전 달 마감 여부 (Phase 3 로직 유지)
    SELECT id INTO v_prior_closing_id FROM public.monthly_closings WHERE closing_year = v_prior_year AND closing_month = v_prior_month_str AND status = 'closed';
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE status = 'closed') INTO v_prior_closed;
    IF v_prior_closed AND v_prior_closing_id IS NULL THEN
        v_errors := v_errors || jsonb_build_object('type', 'PRIOR_MONTH_NOT_CLOSED', 'msg', '선행하는 이전 월의 마감이 확정되지 않았습니다.');
    END IF;

    -- [2] 미확정 문서 검사 (Phase 3 로직 유지)
    SELECT jsonb_agg(doc_no) INTO v_unconfirmed_docs
    FROM (
        SELECT purchase_no AS doc_no FROM public.purchase_headers WHERE status = 'draft' AND purchase_date <= v_end_date
        UNION ALL
        SELECT sales_no AS doc_no FROM public.sales_headers WHERE status = 'draft' AND sales_date <= v_end_date
    ) t;
    
    IF v_unconfirmed_docs IS NOT NULL THEN
        v_errors := v_errors || jsonb_build_object('type', 'DRAFT_DOCS_EXIST', 'msg', '미확정(draft) 문서가 있습니다.', 'data', v_unconfirmed_docs);
    END IF;

    -- [3] 시뮬레이션 기반: 음수 재고 / MAC 누락 / 조정분 포함 검사
    FOR v_prod IN SELECT id, product_code FROM public.products
    LOOP
        v_has_baseline := false; v_opening_qty := NULL; v_opening_mac := NULL;
        
        -- 기초값 확보 (이전 마감 또는 스냅샷)
        IF v_prior_closing_id IS NOT NULL THEN
            SELECT ending_qty, ending_mac INTO v_opening_qty, v_opening_mac
            FROM public.monthly_closing_items WHERE closing_id = v_prior_closing_id AND product_id = v_prod.id;
            IF FOUND THEN v_has_baseline := true; END IF;
        END IF;

        IF NOT v_has_baseline THEN
            SELECT qty, avg_cost INTO v_opening_qty, v_opening_mac FROM public.inventory_valuation_snapshots
            WHERE product_id = v_prod.id AND snapshot_date < v_start_date ORDER BY snapshot_date DESC LIMIT 1;
            IF FOUND THEN v_has_baseline := true; END IF;
        END IF;

        v_ending_qty := COALESCE(v_opening_qty, 0);
        v_ending_mac := COALESCE(v_opening_mac, 0);
        v_txn_count := 0; v_is_negative := false;

        FOR v_txn IN
            SELECT txn_date, txn_type, qty, net_unit_price, adj_value FROM (
                -- 1) 매입
                SELECT ph.purchase_date AS txn_date, 'IN' AS txn_type, pi.qty, pi.net_unit_price, 0 AS adj_value
                FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
                WHERE pi.product_id = v_prod.id AND ph.status = 'confirmed' AND ph.purchase_date >= v_start_date AND ph.purchase_date <= v_end_date
                UNION ALL
                -- 2) 매출
                SELECT sh.sales_date AS txn_date, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price, 0 AS adj_value
                FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
                WHERE si.product_id = v_prod.id AND sh.status = 'confirmed' AND sh.sales_date >= v_start_date AND sh.sales_date <= v_end_date
                UNION ALL
                -- 3) 조정 (신설)
                SELECT adj_date AS txn_date, 'ADJ' AS txn_type, adj_qty AS qty, 0 AS net_unit_price, adj_value
                FROM public.inventory_adjustments
                WHERE product_id = v_prod.id AND adj_date >= v_start_date AND adj_date <= v_end_date
            ) t ORDER BY txn_date ASC
        LOOP
            v_txn_count := v_txn_count + 1;
            IF v_txn.txn_type = 'IN' THEN
                IF (v_ending_qty + v_txn.qty) > 0 THEN v_ending_mac := ((v_ending_qty * v_ending_mac) + (v_txn.qty * v_txn.net_unit_price)) / (v_ending_qty + v_txn.qty); ELSE v_ending_mac := v_txn.net_unit_price; END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
            ELSIF v_txn.txn_type = 'OUT' THEN
                v_ending_qty := v_ending_qty - v_txn.qty;
            ELSIF v_txn.txn_type = 'ADJ' THEN
                IF (v_ending_qty + v_txn.qty) > 0 THEN 
                    v_ending_mac := ((v_ending_qty * v_ending_mac) + v_txn.adj_value) / (v_ending_qty + v_txn.qty); 
                END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
            END IF;
            IF v_ending_qty < 0 THEN v_is_negative := true; END IF;
        END LOOP;

        IF v_is_negative THEN v_negative_stocks := v_negative_stocks || to_jsonb(v_prod.product_code); END IF;
        IF v_ending_qty > 0 AND (v_ending_mac IS NULL OR v_ending_mac = 0) THEN v_null_macs := v_null_macs || to_jsonb(v_prod.product_code); END IF;
    END LOOP;

    IF jsonb_array_length(v_negative_stocks) > 0 THEN v_errors := v_errors || jsonb_build_object('type', 'NEGATIVE_STOCK', 'msg', '음수 재고가 발생하는 품목이 있습니다.', 'data', v_negative_stocks); END IF;
    IF jsonb_array_length(v_null_macs) > 0 THEN v_errors := v_errors || jsonb_build_object('type', 'NULL_MAC', 'msg', '기말 재고가 존재하나 MAC가 0인 품목이 있습니다.', 'data', v_null_macs); END IF;

    RETURN jsonb_build_object('is_valid', jsonb_array_length(v_errors) = 0, 'errors', v_errors);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [4] 월마감 실행 함수 보완
-- execute_monthly_closing 내의 최종 데이터 생성 로직에 ADJ 포함
CREATE OR REPLACE FUNCTION public.execute_monthly_closing(p_year varchar, p_month varchar, p_user_uuid uuid)
RETURNS jsonb AS $$
DECLARE
    v_start_date date := (p_year || '-' || p_month || '-01')::date;
    v_end_date date := v_start_date + interval '1 month' - interval '1 day';
    v_prior_month date := v_start_date - interval '1 month';
    v_prior_year varchar := to_char(v_prior_month, 'YYYY');
    v_prior_month_str varchar := to_char(v_prior_month, 'MM');
    
    v_validation jsonb; v_closing_id bigint; v_prior_closing_id bigint; v_total_value numeric := 0;
    v_prod RECORD; v_txn RECORD;
    v_opening_qty numeric; v_opening_mac numeric;
    v_in_qty numeric; v_in_value numeric;
    v_out_qty numeric; v_out_value numeric;
    v_ending_qty numeric; v_ending_mac numeric;
    v_issue_mac numeric; 
BEGIN
    v_validation := public.validate_monthly_closing(p_year, p_month);
    IF NOT (v_validation->>'is_valid')::boolean THEN 
        RETURN jsonb_build_object('success', false, 'message', 'Validation failed.', 'errors', v_validation->'errors'); 
    END IF;

    -- [1] monthly_closings 헤더 생성/로그 기록
    INSERT INTO public.monthly_closings (closing_year, closing_month, period_start, period_end, status, closed_at, closed_by)
    VALUES (p_year, p_month, v_start_date, v_end_date, 'closed', now(), p_user_uuid)
    ON CONFLICT (closing_year, closing_month) DO UPDATE 
        SET status = 'closed', closed_at = now(), closed_by = EXCLUDED.closed_by, reopen_at = NULL, reopen_reason = NULL, updated_at = now()
    RETURNING id INTO v_closing_id;
    
    DELETE FROM public.monthly_closing_items WHERE closing_id = v_closing_id;
    SELECT id INTO v_prior_closing_id FROM public.monthly_closings WHERE closing_year = v_prior_year AND closing_month = v_prior_month_str AND status = 'closed';

    -- [2] 제품별 최종 정산 루프
    FOR v_prod IN SELECT id, product_code FROM public.products
    LOOP
        v_opening_qty := NULL; v_opening_mac := 0;
        v_in_qty := 0; v_in_value := 0;
        v_out_qty := 0; v_out_value := 0;
        
        -- 기초값 확보
        IF v_prior_closing_id IS NOT NULL THEN
            SELECT ending_qty, ending_mac INTO v_opening_qty, v_opening_mac FROM public.monthly_closing_items WHERE closing_id = v_prior_closing_id AND product_id = v_prod.id;
        END IF;
        IF v_opening_qty IS NULL THEN
            SELECT qty, avg_cost INTO v_opening_qty, v_opening_mac FROM public.inventory_valuation_snapshots WHERE product_id = v_prod.id AND snapshot_date < v_start_date ORDER BY snapshot_date DESC LIMIT 1;
        END IF;

        v_opening_qty := COALESCE(v_opening_qty, 0); v_opening_mac := COALESCE(v_opening_mac, 0);
        v_ending_qty := v_opening_qty; v_ending_mac := v_opening_mac;

        FOR v_txn IN
            SELECT txn_date, created_at, txn_type, qty, net_unit_price, adj_value FROM (
                SELECT ph.purchase_date AS txn_date, ph.created_at, 'IN' AS txn_type, pi.qty, pi.net_unit_price, 0 AS adj_value
                FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
                WHERE pi.product_id = v_prod.id AND ph.status = 'confirmed' AND ph.purchase_date >= v_start_date AND ph.purchase_date <= v_end_date
                UNION ALL
                SELECT sh.sales_date AS txn_date, sh.created_at, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price, 0 AS adj_value
                FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
                WHERE si.product_id = v_prod.id AND sh.status = 'confirmed' AND sh.sales_date >= v_start_date AND sh.sales_date <= v_end_date
                UNION ALL
                SELECT adj_date AS txn_date, created_at, 'ADJ' AS txn_type, adj_qty AS qty, 0 AS net_unit_price, adj_value
                FROM public.inventory_adjustments
                WHERE product_id = v_prod.id AND adj_date >= v_start_date AND adj_date <= v_end_date
            ) t ORDER BY txn_date ASC, created_at ASC
        LOOP
            IF v_txn.txn_type = 'IN' THEN
                IF (v_ending_qty + v_txn.qty) > 0 THEN v_ending_mac := ((v_ending_qty * v_ending_mac) + (v_txn.qty * v_txn.net_unit_price)) / (v_ending_qty + v_txn.qty); ELSE v_ending_mac := v_txn.net_unit_price; END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
                v_in_qty := v_in_qty + v_txn.qty;
                v_in_value := v_in_value + (v_txn.qty * v_txn.net_unit_price);
            ELSIF v_txn.txn_type = 'OUT' THEN
                v_issue_mac := v_ending_mac;
                v_ending_qty := v_ending_qty - v_txn.qty;
                v_out_qty := v_out_qty + v_txn.qty;
                v_out_value := v_out_value + (v_txn.qty * v_issue_mac);
            ELSIF v_txn.txn_type = 'ADJ' THEN
                -- 조정분 처리: 수량과 금액 보정 동시 반영
                IF (v_ending_qty + v_txn.qty) > 0 THEN
                    v_ending_mac := ((v_ending_qty * v_ending_mac) + v_txn.adj_value) / (v_ending_qty + v_txn.qty);
                END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
                -- 통계 분류: 수량 보정은 IN/OUT 성격에 따라 누적 가능하나, 여기서는 편의상 시점 재고로만 관리
            END IF;
        END LOOP;

        v_ending_mac := ROUND(COALESCE(v_ending_mac, 0), 2);

        IF (v_opening_qty != 0) OR (v_in_qty != 0) OR (v_out_qty != 0) OR (v_ending_qty != 0) THEN
            INSERT INTO public.monthly_closing_items (closing_id, product_id, opening_qty, in_qty, out_qty, ending_qty, opening_mac, ending_mac, opening_value, in_value, out_value, ending_value)
            VALUES (v_closing_id, v_prod.id, v_opening_qty, v_in_qty, v_out_qty, v_ending_qty, v_opening_mac, v_ending_mac, v_opening_qty * v_opening_mac, v_in_value, v_out_value, v_ending_qty * v_ending_mac);
            v_total_value := v_total_value + (v_ending_qty * v_ending_mac);

            -- 기말 스냅샷 갱신 (리포트용)
            DELETE FROM public.inventory_valuation_snapshots WHERE product_id = v_prod.id AND snapshot_date = v_end_date;
            INSERT INTO public.inventory_valuation_snapshots (product_id, snapshot_date, qty, avg_cost, remark)
            VALUES (v_prod.id, v_end_date, v_ending_qty, v_ending_mac, 'Adjustment Included Closing: ' || p_year || '-' || p_month);
        END IF;
    END LOOP;

    UPDATE public.monthly_closings SET total_inventory_value = v_total_value WHERE id = v_closing_id;
    
    RETURN jsonb_build_object('success', true, 'closing_id', v_closing_id, 'total_value', v_total_value);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
