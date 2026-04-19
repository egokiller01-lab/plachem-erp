-- ==========================================
-- [Phase 7-1] 손익 분석(P&L) 통합 데이터 뷰 (SQL)
-- ==========================================

-- 1. 월별 전사 손익 요약 뷰
CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
WITH sales_data AS (
    SELECT 
        to_char(sh.sales_date, 'YYYY-MM') as yyyymm,
        SUM(si.net_amount) as total_revenue,
        SUM(si.qty * si.cogs_unit_price) as total_cogs
    FROM public.sales_items si
    JOIN public.sales_headers sh ON si.sales_header_id = sh.id
    WHERE sh.status = 'confirmed'
    GROUP BY 1
),
subcon_data AS (
    SELECT 
        to_char(doc_date, 'YYYY-MM') as yyyymm,
        SUM(total_amount) as total_subcon_cost
    FROM public.accounts_payable
    WHERE ref_type = 'PRODUCTION_SUBCON' AND status != 'void'
    GROUP BY 1
)
SELECT 
    COALESCE(s.yyyymm, b.yyyymm) as yyyymm,
    COALESCE(s.total_revenue, 0) as revenue,
    COALESCE(s.total_cogs, 0) as cogs,
    (COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) as gross_profit,
    COALESCE(b.total_subcon_cost, 0) as subcon_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0)) as operational_profit
FROM sales_data s
FULL OUTER JOIN subcon_data b ON s.yyyymm = b.yyyymm;

GRANT SELECT ON public.v_profit_loss_summary TO authenticated;

-- 2. 제품별 손익 분석 뷰
CREATE OR REPLACE VIEW public.v_product_profitability AS
SELECT 
    p.id as product_id,
    p.product_name,
    p.product_code,
    SUM(si.qty) as total_qty,
    SUM(si.net_amount) as revenue,
    SUM(si.qty * si.cogs_unit_price) as cogs,
    (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) as gross_profit,
    CASE 
        WHEN SUM(si.net_amount) > 0 THEN (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) / SUM(si.net_amount) * 100 
        ELSE 0 
    END as margin_rate
FROM public.sales_items si
JOIN public.sales_headers sh ON si.sales_header_id = sh.id
JOIN public.products p ON si.product_id = p.id
WHERE sh.status = 'confirmed'
GROUP BY 1, 2, 3;

GRANT SELECT ON public.v_product_profitability TO authenticated;
