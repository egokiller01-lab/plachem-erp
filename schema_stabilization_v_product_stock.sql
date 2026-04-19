-- ==========================================
-- [Stabilization] v_product_stock 재정의
-- ==========================================

CREATE OR REPLACE VIEW public.v_product_stock AS
WITH all_movements AS (
    -- 1. 매입 (입고)
    SELECT pi.product_id, pi.qty AS qty_in, 0 AS qty_out
    FROM public.purchase_items pi
    JOIN public.purchase_headers ph ON ph.id = pi.purchase_header_id
    WHERE ph.status = 'confirmed'
    
    UNION ALL

    -- 2. 매출 (출고)
    SELECT si.product_id, 0 AS qty_in, si.qty AS qty_out
    FROM public.sales_items si
    JOIN public.sales_headers sh ON sh.id = si.sales_header_id
    WHERE sh.status = 'confirmed'

    UNION ALL

    -- 3. 재고 조정 (Adjustment)
    SELECT product_id, 
           CASE WHEN adj_qty > 0 THEN adj_qty ELSE 0 END AS qty_in,
           CASE WHEN adj_qty < 0 THEN ABS(adj_qty) ELSE 0 END AS qty_out
    FROM public.inventory_adjustments

    UNION ALL

    -- 4. 생산 및 기타 수불부 (Production etc.)
    -- inventory_transactions 테이블의 기록을 합산
    SELECT product_id, qty_in, qty_out
    FROM public.inventory_transactions
)
SELECT 
    p.id AS product_id,
    p.product_code,
    p.product_name,
    p.unit,
    p.category,
    COALESCE(SUM(m.qty_in), 0) - COALESCE(SUM(m.qty_out), 0) AS stock_qty,
    p.moving_avg_cost
FROM public.products p
LEFT JOIN all_movements m ON p.id = m.product_id
GROUP BY p.id, p.product_code, p.product_name, p.unit, p.category, p.moving_avg_cost;
