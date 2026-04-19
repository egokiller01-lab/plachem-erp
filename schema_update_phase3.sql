-- ==============================================================================
-- PLACHEM ERP Phase 3: Monthly Closing Schema & Logic (2차 REVISED)
-- ==============================================================================

-- 1. ADD COGS COLUMNS TO SALES_ITEMS
ALTER TABLE public.sales_items
ADD COLUMN IF NOT EXISTS cogs_unit_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS cogs_amount numeric GENERATED ALWAYS AS (qty * cogs_unit_price) STORED;

COMMENT ON COLUMN public.sales_items.cogs_unit_price IS '매출 확정 시점의 제품 이동평균단가(MAC). 과거 수정 시에도 절대 불변 원칙.';

-- 2. CREATE COGS FIXING TRIGGER FUNCTIONS
-- 2-1: BEFORE INSERT ONLY (UPDATE 방지)
CREATE OR REPLACE FUNCTION public.trg_set_cogs_on_sales_item()
RETURNS TRIGGER AS $$
DECLARE
    v_header_status varchar;
BEGIN
    SELECT status INTO v_header_status FROM public.sales_headers WHERE id = NEW.sales_header_id;
    
    IF v_header_status = 'confirmed' THEN
        IF NEW.cogs_unit_price = 0 THEN
            NEW.cogs_unit_price := COALESCE((SELECT moving_avg_cost FROM public.products WHERE id = NEW.product_id), 0);
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_cogs_sales_item_insert ON public.sales_items;
-- 범위 축소: 딱 INSERT 순간에만 발동. 의도치 않은 UPDATE 연쇄 오류 완벽 차단.
CREATE TRIGGER trg_cogs_sales_item_insert
BEFORE INSERT ON public.sales_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_set_cogs_on_sales_item();

-- 2-2: 헤더가 draft -> confirmed로 넘어갈 때 (강력한 WHEN 조건 적용)
CREATE OR REPLACE FUNCTION public.trg_set_cogs_on_sales_header_confirm()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.sales_items s
    SET cogs_unit_price = COALESCE(p.moving_avg_cost, 0)
    FROM public.products p
    WHERE s.product_id = p.id
      AND s.sales_header_id = NEW.id 
      AND s.cogs_unit_price = 0;
      
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_cogs_sales_header_confirm ON public.sales_headers;
-- 방어막: 단순히 UPDATE될 때가 아니라 상태가 draft에서 confirmed로 전이되는 정확한 순간에만 발동
CREATE TRIGGER trg_cogs_sales_header_confirm
AFTER UPDATE ON public.sales_headers
FOR EACH ROW
WHEN (OLD.status = 'draft' AND NEW.status = 'confirmed')
EXECUTE FUNCTION public.trg_set_cogs_on_sales_header_confirm();

-- 3. MONTHLY CLOSINGS TABLES
CREATE TABLE IF NOT EXISTS public.monthly_closings (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    closing_year varchar(4) NOT NULL,
    closing_month varchar(2) NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'draft', 
    total_inventory_value numeric DEFAULT 0,
    closed_at timestamptz,
    closed_by uuid,
    reopen_at timestamptz,
    reopen_by uuid,
    reopen_reason text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    remark text,
    UNIQUE(closing_year, closing_month)
);

CREATE TABLE IF NOT EXISTS public.monthly_closing_items (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    closing_id bigint NOT NULL REFERENCES public.monthly_closings(id) ON DELETE CASCADE,
    product_id bigint NOT NULL REFERENCES public.products(id),
    opening_qty numeric DEFAULT 0,
    in_qty numeric DEFAULT 0,
    out_qty numeric DEFAULT 0,
    ending_qty numeric DEFAULT 0,
    opening_mac numeric DEFAULT 0,
    ending_mac numeric DEFAULT 0,
    opening_value numeric DEFAULT 0,
    in_value numeric DEFAULT 0,
    out_value numeric DEFAULT 0,
    ending_value numeric DEFAULT 0,
    created_at timestamptz DEFAULT now()
);

-- 4. CLOSING LOGS TABLE
CREATE TABLE IF NOT EXISTS public.closing_activity_logs (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    action_type varchar(20) NOT NULL,
    closing_id bigint REFERENCES public.monthly_closings(id),
    closing_year varchar(4),
    closing_month varchar(2),
    acted_by uuid,
    acted_at timestamptz DEFAULT now(),
    reason text,
    note text
);

-- 5. CLOSING VALIDATION FUNCTION (대상 월 시뮬레이션 기반 완벽 검증)
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
    v_prod RECORD;
    v_txn RECORD;
    v_prior_closing_id bigint;
    
    v_opening_qty numeric; v_opening_mac numeric;
    v_ending_qty numeric; v_ending_mac numeric;
    v_has_baseline boolean; v_txn_count int; v_is_negative boolean;
BEGIN
    -- [1] 이전 달 마감 여부
    SELECT id INTO v_prior_closing_id FROM public.monthly_closings WHERE closing_year = v_prior_year AND closing_month = v_prior_month_str AND status = 'closed';
    
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE status = 'closed') INTO v_prior_closed;
    IF v_prior_closed AND v_prior_closing_id IS NULL THEN
        v_errors := v_errors || jsonb_build_object('type', 'PRIOR_MONTH_NOT_CLOSED', 'msg', '선행하는 이전 월의 마감이 확정되지 않았습니다.');
    END IF;

    -- [2] 대상 월 이하 일자 Draft 문서 검사 (Production 모델 분리: 이번 버전에선 MAC 계산 스콥 외이므로 제외 원칙 준수)
    SELECT jsonb_agg(doc_no) INTO v_unconfirmed_docs
    FROM (
        SELECT purchase_no AS doc_no FROM public.purchase_headers WHERE status = 'draft' AND purchase_date <= v_end_date
        UNION ALL
        SELECT sales_no AS doc_no FROM public.sales_headers WHERE status = 'draft' AND sales_date <= v_end_date
    ) t;
    
    IF v_unconfirmed_docs IS NOT NULL THEN
        v_errors := v_errors || jsonb_build_object('type', 'DRAFT_DOCS_EXIST', 'msg', '대상 월 이하 일자에 미확정(draft) 문서가 있습니다. (생산모듈 제외)', 'data', v_unconfirmed_docs);
    END IF;

    -- [3] 헤더/아이템 금액 일치 검사
    SELECT jsonb_agg(header_no) INTO v_mismatched_totals
    FROM (
        SELECT ph.purchase_no AS header_no FROM public.purchase_headers ph
        JOIN (SELECT purchase_header_id, SUM(COALESCE(amount, net_amount + vat_amount)) AS items_total FROM public.purchase_items GROUP BY purchase_header_id) pi 
          ON pi.purchase_header_id = ph.id
        WHERE ph.purchase_date <= v_end_date AND ABS(COALESCE(ph.total_amount, ph.total_net_amount + ph.total_vat_amount) - pi.items_total) > 1
        UNION ALL
        SELECT sh.sales_no AS header_no FROM public.sales_headers sh
        JOIN (SELECT sales_header_id, SUM(amount) AS items_total FROM public.sales_items GROUP BY sales_header_id) si 
          ON si.sales_header_id = sh.id
        WHERE sh.sales_date <= v_end_date AND ABS(COALESCE(sh.total_amount, sh.total_net_amount + sh.total_vat_amount) - si.items_total) > 1
    ) t;
    
    IF v_mismatched_totals IS NOT NULL THEN
       v_errors := v_errors || jsonb_build_object('type', 'AMOUNT_MISMATCH', 'msg', '헤더와 아이템 합계 금액이 불일치하는 문서가 존재합니다.', 'data', v_mismatched_totals);
    END IF;

    -- [4] 대상 월 시뮬레이션 기반: 음수 재고 / MAC 누락 / 완전 누락된 기초 베이스라인 검사
    FOR v_prod IN SELECT id, product_code FROM public.products
    LOOP
        v_has_baseline := false; v_opening_qty := NULL; v_opening_mac := NULL;
        
        IF v_prior_closing_id IS NOT NULL THEN
            SELECT ending_qty, ending_mac INTO v_opening_qty, v_opening_mac
            FROM public.monthly_closing_items WHERE closing_id = v_prior_closing_id AND product_id = v_prod.id;
            IF FOUND THEN v_has_baseline := true; END IF;
        END IF;

        IF NOT v_has_baseline THEN
            SELECT qty, avg_cost INTO v_opening_qty, v_opening_mac
            FROM public.inventory_valuation_snapshots
            WHERE product_id = v_prod.id AND snapshot_date < v_start_date ORDER BY snapshot_date DESC LIMIT 1;
            IF FOUND THEN v_has_baseline := true; END IF;
        END IF;

        v_ending_qty := COALESCE(v_opening_qty, 0);
        v_ending_mac := COALESCE(v_opening_mac, 0);
        v_txn_count := 0; v_is_negative := false;

        FOR v_txn IN
            SELECT txn_date, txn_type, qty, net_unit_price FROM (
                SELECT ph.purchase_date AS txn_date, 'IN' AS txn_type, pi.qty, pi.net_unit_price
                FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
                WHERE pi.product_id = v_prod.id AND ph.status = 'confirmed' AND ph.purchase_date >= v_start_date AND ph.purchase_date <= v_end_date
                UNION ALL
                SELECT sh.sales_date AS txn_date, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price
                FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
                WHERE si.product_id = v_prod.id AND sh.status = 'confirmed' AND sh.sales_date >= v_start_date AND sh.sales_date <= v_end_date
            ) t ORDER BY txn_date ASC
        LOOP
            v_txn_count := v_txn_count + 1;
            IF v_txn.txn_type = 'IN' THEN
                IF (v_ending_qty + v_txn.qty) > 0 THEN v_ending_mac := ((v_ending_qty * v_ending_mac) + (v_txn.qty * v_txn.net_unit_price)) / (v_ending_qty + v_txn.qty); ELSE v_ending_mac := v_txn.net_unit_price; END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
            ELSIF v_txn.txn_type = 'OUT' THEN
                v_ending_qty := v_ending_qty - v_txn.qty;
                IF v_ending_qty < 0 THEN v_is_negative := true; END IF;
            END IF;
        END LOOP;

        IF NOT v_has_baseline AND v_txn_count > 0 THEN
            v_missing_baselines := v_missing_baselines || to_jsonb(v_prod.product_code);
        END IF;
        IF v_is_negative THEN v_negative_stocks := v_negative_stocks || to_jsonb(v_prod.product_code); END IF;
        IF v_ending_qty > 0 AND (v_ending_mac IS NULL OR v_ending_mac = 0) THEN v_null_macs := v_null_macs || to_jsonb(v_prod.product_code); END IF;
    END LOOP;

    IF jsonb_array_length(v_missing_baselines) > 0 THEN v_errors := v_errors || jsonb_build_object('type', 'NO_BASELINE', 'msg', '기초 스냅샷/이월데이터가 없어 계산이 불가합니다. 반드시 기초 스냅샷을 먼저 생성하십시오.', 'data', v_missing_baselines); END IF;
    IF jsonb_array_length(v_negative_stocks) > 0 THEN v_errors := v_errors || jsonb_build_object('type', 'NEGATIVE_STOCK', 'msg', '대상 월 시뮬레이션 중 음수 재고가 발생한 품목이 있습니다.', 'data', v_negative_stocks); END IF;
    IF jsonb_array_length(v_null_macs) > 0 THEN v_errors := v_errors || jsonb_build_object('type', 'NULL_MAC', 'msg', '기말 재고가 존재하나 MAC가 0인 품목이 있습니다.', 'data', v_null_macs); END IF;

    RETURN jsonb_build_object('is_valid', jsonb_array_length(v_errors) = 0, 'errors', v_errors);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 6. MONTHLY CLOSING EXECUTION FUNCTION (OUT 원가 분리 및 명확화)
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
    v_issue_mac numeric; -- 출고 시점의 전용 캐싱 원가 (혼동 방지)
BEGIN
    v_validation := public.validate_monthly_closing(p_year, p_month);
    IF NOT (v_validation->>'is_valid')::boolean THEN RETURN jsonb_build_object('success', false, 'message', 'Validation failed.', 'errors', v_validation->'errors'); END IF;

    INSERT INTO public.monthly_closings (closing_year, closing_month, period_start, period_end, status, closed_at, closed_by)
    VALUES (p_year, p_month, v_start_date, v_end_date, 'closed', now(), p_user_uuid)
    ON CONFLICT (closing_year, closing_month) DO UPDATE SET status = 'closed', closed_at = now(), closed_by = EXCLUDED.closed_by, reopen_at = NULL, reopen_by = NULL, reopen_reason = NULL, updated_at = now()
    RETURNING id INTO v_closing_id;
    
    DELETE FROM public.monthly_closing_items WHERE closing_id = v_closing_id;
    SELECT id INTO v_prior_closing_id FROM public.monthly_closings WHERE closing_year = v_prior_year AND closing_month = v_prior_month_str AND status = 'closed';

    FOR v_prod IN SELECT id, product_code FROM public.products
    LOOP
        v_opening_qty := NULL; v_opening_mac := 0;
        v_in_qty := 0; v_in_value := 0;
        v_out_qty := 0; v_out_value := 0;
        
        IF v_prior_closing_id IS NOT NULL THEN
            SELECT ending_qty, ending_mac INTO v_opening_qty, v_opening_mac FROM public.monthly_closing_items WHERE closing_id = v_prior_closing_id AND product_id = v_prod.id;
        END IF;

        IF v_opening_qty IS NULL THEN
            SELECT qty, avg_cost INTO v_opening_qty, v_opening_mac FROM public.inventory_valuation_snapshots WHERE product_id = v_prod.id AND snapshot_date < v_start_date ORDER BY snapshot_date DESC LIMIT 1;
        END IF;

        v_opening_qty := COALESCE(v_opening_qty, 0); v_opening_mac := COALESCE(v_opening_mac, 0);
        v_ending_qty := v_opening_qty; v_ending_mac := v_opening_mac;

        FOR v_txn IN
            SELECT txn_date, txn_type, qty, net_unit_price FROM (
                SELECT ph.purchase_date AS txn_date, ph.created_at, 'IN' AS txn_type, pi.qty, pi.net_unit_price
                FROM public.purchase_items pi JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
                WHERE pi.product_id = v_prod.id AND ph.status = 'confirmed' AND ph.purchase_date >= v_start_date AND ph.purchase_date <= v_end_date
                UNION ALL
                SELECT sh.sales_date AS txn_date, sh.created_at, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price
                FROM public.sales_items si JOIN public.sales_headers sh ON sh.id = si.sales_header_id
                WHERE si.product_id = v_prod.id AND sh.status = 'confirmed' AND sh.sales_date >= v_start_date AND sh.sales_date <= v_end_date
            ) t ORDER BY txn_date ASC, created_at ASC
        LOOP
            IF v_txn.txn_type = 'IN' THEN
                IF (v_ending_qty + v_txn.qty) > 0 THEN v_ending_mac := ((v_ending_qty * v_ending_mac) + (v_txn.qty * v_txn.net_unit_price)) / (v_ending_qty + v_txn.qty); ELSE v_ending_mac := v_txn.net_unit_price; END IF;
                v_ending_qty := v_ending_qty + v_txn.qty;
                v_in_qty := v_in_qty + v_txn.qty;
                v_in_value := v_in_value + (v_txn.qty * v_txn.net_unit_price);
            ELSIF v_txn.txn_type = 'OUT' THEN
                -- 명확한 OUT 원가 산출: 재고 이동(차감) 전에 적용 중인 MAC를 Issue_MAC 변수로 분리하여 고정
                v_issue_mac := v_ending_mac;
                v_ending_qty := v_ending_qty - v_txn.qty;
                
                v_out_qty := v_out_qty + v_txn.qty;
                v_out_value := v_out_value + (v_txn.qty * v_issue_mac); -- 분리한 명확한 출고원가 곱 연산
            END IF;
        END LOOP;

        v_ending_mac := ROUND(COALESCE(v_ending_mac, 0), 2);

        IF (v_opening_qty != 0) OR (v_in_qty != 0) OR (v_out_qty != 0) OR (v_ending_qty != 0) THEN
            INSERT INTO public.monthly_closing_items (closing_id, product_id, opening_qty, in_qty, out_qty, ending_qty, opening_mac, ending_mac, opening_value, in_value, out_value, ending_value)
            VALUES (v_closing_id, v_prod.id, v_opening_qty, v_in_qty, v_out_qty, v_ending_qty, v_opening_mac, v_ending_mac, v_opening_qty * v_opening_mac, v_in_value, v_out_value, v_ending_qty * v_ending_mac);
            v_total_value := v_total_value + (v_ending_qty * v_ending_mac);

            DELETE FROM public.inventory_valuation_snapshots WHERE product_id = v_prod.id AND snapshot_date = v_end_date;
            INSERT INTO public.inventory_valuation_snapshots (product_id, snapshot_date, qty, avg_cost, remark)
            VALUES (v_prod.id, v_end_date, v_ending_qty, v_ending_mac, 'Phase3 Closed: ' || p_year || '-' || p_month);
        END IF;
    END LOOP;

    UPDATE public.monthly_closings SET total_inventory_value = v_total_value WHERE id = v_closing_id;
    INSERT INTO public.closing_activity_logs (action_type, closing_id, closing_year, closing_month, acted_by, reason, note) VALUES ('CLOSE', v_closing_id, p_year, p_month, p_user_uuid, 'System Monthly Closing', 'Target month simulation completed');

    RETURN jsonb_build_object('success', true, 'closing_id', v_closing_id, 'total_value', v_total_value);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 7. REOPEN FUNCTION
CREATE OR REPLACE FUNCTION public.reopen_monthly_closing(p_year varchar, p_month varchar, p_reason text, p_user_uuid uuid)
RETURNS jsonb AS $$
DECLARE
    v_closing_id bigint;
BEGIN
    SELECT id INTO v_closing_id FROM public.monthly_closings WHERE closing_year = p_year AND closing_month = p_month AND status = 'closed';
    IF v_closing_id IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '마감된 내역을 찾을 수 없습니다.'); END IF;

    UPDATE public.monthly_closings SET status = 'draft', reopen_at = now(), reopen_by = p_user_uuid, reopen_reason = p_reason, updated_at = now() WHERE id = v_closing_id;
    INSERT INTO public.closing_activity_logs (action_type, closing_id, acted_by, reason) VALUES ('REOPEN', v_closing_id, p_user_uuid, p_reason);

    RETURN jsonb_build_object('success', true, 'closing_id', v_closing_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
