-- Patch: Fix v_profit_loss_summary FULL JOIN condition error
-- Reason: PostgREST query failed with:
--   FULL JOIN is only supported with merge-joinable or hash-joinable join conditions
-- Cause: The previous view used a FULL OUTER JOIN with an OR condition.
-- Apply in Supabase SQL Editor after review.

CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
WITH sales_data AS (
    SELECT
        to_char(sh.sales_date, 'YYYY-MM') AS yyyymm,
        SUM(si.net_amount) AS total_revenue,
        SUM(si.qty * si.cogs_unit_price) AS total_cogs
    FROM public.sales_items si
    JOIN public.sales_headers sh ON si.sales_header_id = sh.id
    WHERE sh.status = 'confirmed'
    GROUP BY 1
),
subcon_data AS (
    SELECT
        to_char(doc_date, 'YYYY-MM') AS yyyymm,
        SUM(total_amount) AS total_subcon_cost
    FROM public.accounts_payable
    WHERE ref_type = 'PRODUCTION_SUBCON' AND status != 'void'
    GROUP BY 1
),
sga_data AS (
    SELECT
        to_char(expense_date, 'YYYY-MM') AS yyyymm,
        SUM(amount) AS total_sga_cost
    FROM public.expense_records
    WHERE status = 'confirmed'
    GROUP BY 1
),
months AS (
    SELECT yyyymm FROM sales_data
    UNION
    SELECT yyyymm FROM subcon_data
    UNION
    SELECT yyyymm FROM sga_data
)
SELECT
    m.yyyymm,
    COALESCE(s.total_revenue, 0) AS revenue,
    COALESCE(s.total_cogs, 0) AS cogs,
    (COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) AS gross_profit,
    COALESCE(b.total_subcon_cost, 0) AS subcon_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0)) AS operational_gross_profit,
    COALESCE(g.total_sga_cost, 0) AS sga_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0) - COALESCE(g.total_sga_cost, 0)) AS operating_income
FROM months m
LEFT JOIN sales_data s ON s.yyyymm = m.yyyymm
LEFT JOIN subcon_data b ON b.yyyymm = m.yyyymm
LEFT JOIN sga_data g ON g.yyyymm = m.yyyymm;

GRANT SELECT ON public.v_profit_loss_summary TO authenticated;
