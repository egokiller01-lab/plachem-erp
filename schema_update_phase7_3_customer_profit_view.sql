-- ==========================================
-- [Phase 7-3] 거래처별 수익성 분석 뷰 (SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_profitability AS
SELECT 
    c.id as customer_id,
    c.customer_name,
    to_char(sh.sales_date, 'YYYY-MM') as yyyymm,
    SUM(si.net_amount) as revenue,
    SUM(si.qty * si.cogs_unit_price) as cogs,
    (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) as gross_profit,
    CASE 
        WHEN SUM(si.net_amount) > 0 THEN (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) / SUM(si.net_amount) * 100 
        ELSE 0 
    END as margin_rate
FROM public.sales_items si
JOIN public.sales_headers sh ON si.sales_header_id = sh.id
JOIN public.customers c ON sh.customer_id = c.id
WHERE sh.status = 'confirmed'
GROUP BY 1, 2, 3;

COMMENT ON VIEW public.v_customer_profitability IS '거래처별 월별 매출, 원가, 총이익 및 총이익률을 분석하는 뷰';

GRANT SELECT ON public.v_customer_profitability TO authenticated;
