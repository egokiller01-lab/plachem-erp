-- ==============================================================================
-- PLACHEM ERP Phase 2: Schema Amendment Script (Revised V3)
-- ==============================================================================

-- 1. BASELINE TABLE: INVENTORY VALUATION SNAPSHOTS
CREATE TABLE IF NOT EXISTS public.inventory_valuation_snapshots (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    product_id bigint NOT NULL REFERENCES public.products(id),
    snapshot_date date NOT NULL,
    qty numeric NOT NULL DEFAULT 0,
    avg_cost numeric NOT NULL DEFAULT 0,
    created_at timestamptz DEFAULT now(),
    remark text
);

CREATE INDEX IF NOT EXISTS idx_inv_val_snap_prod_date ON public.inventory_valuation_snapshots(product_id, snapshot_date);

-- 2. ADD COLUMNS TO PRODUCTS
ALTER TABLE public.products
ADD COLUMN IF NOT EXISTS moving_avg_cost numeric DEFAULT 0;

COMMENT ON COLUMN public.products.moving_avg_cost IS '이동평균법에 의한 재고 단가 (전면 재계산 로직에 의해서만 갱신)';

-- 3. ADD COLUMNS TO HEADERS
ALTER TABLE public.purchase_headers
ADD COLUMN IF NOT EXISTS total_net_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS total_vat_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS attachment_url text;

ALTER TABLE public.sales_headers
ADD COLUMN IF NOT EXISTS total_net_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS total_vat_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS attachment_url text;

-- 4. ADD COLUMNS TO ITEMS (product_id excluded as it already exists)
ALTER TABLE public.purchase_items
ADD COLUMN IF NOT EXISTS net_unit_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS vat_rate numeric DEFAULT 10,
ADD COLUMN IF NOT EXISTS net_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS vat_amount numeric DEFAULT 0;

ALTER TABLE public.sales_items
ADD COLUMN IF NOT EXISTS net_unit_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS vat_rate numeric DEFAULT 10,
ADD COLUMN IF NOT EXISTS net_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS vat_amount numeric DEFAULT 0;


-- ==============================================================================
-- 5. FUNCTION: RECALCULATE MOVING AVERAGE COST (With Baseline & Negative Check)
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.recalculate_mac_for_product(p_product_id bigint)
RETURNS void AS $$
DECLARE
    v_stock numeric := 0;
    v_mac numeric := 0;
    v_record RECORD;
    v_last_snapshot_date date := '1900-01-01'::date;
BEGIN
    -- [1] Baseline 확보: 가장 최근의 마감 스냅샷 조회
    SELECT snapshot_date, qty, avg_cost
    INTO v_last_snapshot_date, v_stock, v_mac
    FROM public.inventory_valuation_snapshots
    WHERE product_id = p_product_id
    ORDER BY snapshot_date DESC, id DESC
    LIMIT 1;

    -- [1-1] NULL 방지: 스냅샷이 없는 경우 초기값(1900-01-01, 0, 0)을 유지하도록 보정
    v_last_snapshot_date := COALESCE(v_last_snapshot_date, '1900-01-01'::date);
    v_stock := COALESCE(v_stock, 0);
    v_mac := COALESCE(v_mac, 0);

    -- [2] 수불 내역 순차 재계산 (스냅샷 이후의 확정된 데이터 대상)
    FOR v_record IN
        SELECT 
            txn_date,
            txn_type,         -- 'IN' or 'OUT'
            qty,              -- 거래 수량
            net_unit_price,   -- 입고 건의 경우 순매입단가
            doc_no            -- 확인용 문서번호
        FROM (
            -- 1) 확정된 매입 (IN)
            SELECT ph.purchase_date AS txn_date, ph.created_at, 'IN' AS txn_type, pi.qty, pi.net_unit_price, ph.purchase_no AS doc_no
            FROM public.purchase_items pi
            JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
            WHERE pi.product_id = p_product_id 
              AND ph.status = 'confirmed'
              AND ph.purchase_date > v_last_snapshot_date
            
            UNION ALL
            
            -- 2) 확정된 매출 (OUT)
            SELECT sh.sales_date AS txn_date, sh.created_at, 'OUT' AS txn_type, si.qty, 0 AS net_unit_price, sh.sales_no AS doc_no
            FROM public.sales_items si
            JOIN public.sales_headers sh ON sh.id = si.sales_header_id
            WHERE si.product_id = p_product_id 
              AND sh.status = 'confirmed'
              AND sh.sales_date > v_last_snapshot_date
        ) combined_txns
        ORDER BY txn_date ASC, created_at ASC
    LOOP
        IF v_record.txn_type = 'IN' THEN
            -- 입고 시: 단가 갱신 및 재고 증가
            IF (v_stock + v_record.qty) > 0 THEN
                v_mac := ((v_stock * v_mac) + (v_record.qty * v_record.net_unit_price)) / (v_stock + v_record.qty);
            ELSE
                v_mac := v_record.net_unit_price;
            END IF;
            v_stock := v_stock + v_record.qty;
            
        ELSIF v_record.txn_type = 'OUT' THEN
            -- 출고 시: 재고만 차감
            v_stock := v_stock - v_record.qty;
            
            -- [정책] 음수 재고 감지 시 트랜잭션 차단
            IF v_stock < 0 THEN
                RAISE EXCEPTION 'Negative stock detected for product ID % during MAC recalculation at doc %. (Remaining: %)', 
                p_product_id, v_record.doc_no, v_stock;
            END IF;
        END IF;
    END LOOP;

    -- [3] 최종 산출된 MAC를 products 테이블에 업데이트 (Value 정정)
    UPDATE public.products
    SET moving_avg_cost = ROUND(v_mac, 2)
    WHERE id = p_product_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ==============================================================================
-- 6. TRIGGER: STATUS CHANGE ON PURCHASE HEADERS
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.trigger_mac_on_header_status_change()
RETURNS TRIGGER AS $$
DECLARE
    v_item RECORD;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        -- [명시적 상태 전이 제어]
        -- 1. draft -> confirmed (확정)
        -- 2. confirmed -> cancelled (취소)
        -- 3. confirmed -> draft (확정 해제)
        IF (OLD.status = 'draft' AND NEW.status = 'confirmed') OR
           (OLD.status = 'confirmed' AND NEW.status = 'cancelled') OR
           (OLD.status = 'confirmed' AND NEW.status = 'draft') 
        THEN
            FOR v_item IN 
                SELECT DISTINCT product_id 
                FROM public.purchase_items 
                WHERE purchase_header_id = NEW.id AND product_id IS NOT NULL
            LOOP
                -- 대상 제품에 대해 각각 전수 재계산 수행
                PERFORM public.recalculate_mac_for_product(v_item.product_id);
            END LOOP;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_mac_header_update ON public.purchase_headers;

CREATE TRIGGER trg_mac_header_update
AFTER UPDATE ON public.purchase_headers
FOR EACH ROW
EXECUTE FUNCTION public.trigger_mac_on_header_status_change();
