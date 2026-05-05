-- ==========================================
-- [Phase 7-1] ?ìµ ë¶„ì„(P&L) ?µí•© ?°ì´??ë·?(SQL)
-- ==========================================

-- 1. ?”ë³„ ?„ì‚¬ ?ìµ ?”ì•½ ë·?CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
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

-- 2. ?œí’ˆë³??ìµ ë¶„ì„ ë·?CREATE OR REPLACE VIEW public.v_product_profitability AS
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
-- ==========================================
-- [Phase 7-2] ?¼ë°˜ ?ê?ë¹?SG&A) ëª¨ë“ˆ (SQL)
-- ==========================================

-- [1] ë¹„ìš© ì¹´í…Œê³ ë¦¬ ë§ˆìŠ¤??CREATE TABLE IF NOT EXISTS public.expense_categories (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_name varchar(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamptz DEFAULT now()
);

-- ì´ˆê¸° ì¹´í…Œê³ ë¦¬ ?°ì´??INSERT INTO public.expense_categories (category_name) VALUES 
('ê¸‰ì—¬'), ('?„ë?ë£?), ('?Œëª¨?ˆë¹„'), ('?´ì†¡ë¹?), ('?µì‹ ë¹?), ('?˜ë„ê´‘ì—´ë¹?), ('êµìœ¡?ˆë ¨ë¹?), ('ê¸°í??ê?ë¹?)
ON CONFLICT DO NOTHING;

-- [2] ë¹„ìš© ?„í‘œ ?Œì´ë¸?CREATE TABLE IF NOT EXISTS public.expense_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_id bigint NOT NULL REFERENCES public.expense_categories(id),
    expense_date date NOT NULL,
    is_payable boolean NOT NULL DEFAULT false, -- AP ?ì„± ?¬ë?
    vendor_id bigint REFERENCES public.customers(id), -- ì§€ê¸‰ì²˜ (is_payable=true ??ê¶Œì¥)
    due_date date, -- ì§€ê¸?ê¸°í•œ
    amount numeric NOT NULL DEFAULT 0, -- ê³µê¸‰ê°€??(P&L ë°˜ì˜ë¶?
    vat_amount numeric NOT NULL DEFAULT 0,
    total_amount numeric NOT NULL DEFAULT 0, -- (AP ?ì„±??
    status varchar(20) NOT NULL DEFAULT 'draft', -- draft, confirmed, void
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_expense_date ON public.expense_records(expense_date);
CREATE INDEX IF NOT EXISTS idx_expense_cat ON public.expense_records(category_id);

-- [3] ë¹„ìš© ?•ì • RPC (confirm_expense_document)
CREATE OR REPLACE FUNCTION public.confirm_expense_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
BEGIN
    -- 1. ê¶Œí•œ ë°??„í‘œ ?•ì¸
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    SELECT e.*, c.category_name INTO v_head 
    FROM public.expense_records e 
    JOIN public.expense_categories c ON e.category_id = c.id
    WHERE e.id = p_doc_id;

    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •??ë¬¸ì„œ?…ë‹ˆ??'); END IF;

    -- 2. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?”ì´ ë§ˆê°?˜ì–´ ?•ì •?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 3. AP ?ë™ ?°ë™ (is_payable = true ???Œë§Œ)
    IF v_head.is_payable THEN
        IF v_head.vendor_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', 'ì§€ê¸??˜ë¬´ê°€ ?ˆëŠ” ë¹„ìš©?€ ê±°ë˜ì²?Vendor)ë¥?ì§€?•í•´???©ë‹ˆ??');
        END IF;

        INSERT INTO public.accounts_payable (
            vendor_id, 
            ref_type, 
            ref_id, 
            doc_date, 
            due_date, 
            total_amount, 
            status, 
            remark,
            created_by
        )
        VALUES (
            v_head.vendor_id, 
            'EXPENSE', 
            v_head.id, 
            v_head.expense_date, 
            COALESCE(v_head.due_date, v_head.expense_date + INTERVAL '30 days'), 
            v_head.total_amount, 
            'unpaid', 
            format('?ê?ë¹??ë™?ì„± (%s)', v_head.category_name),
            auth.uid()
        );
    END IF;

    -- 4. ?íƒœ ?…ë°?´íŠ¸
    UPDATE public.expense_records SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë¹„ìš© ?„í‘œê°€ ?•ì •?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] ë¹„ìš© ?•ì • ì·¨ì†Œ RPC (unconfirm_expense_document)
CREATE OR REPLACE FUNCTION public.unconfirm_expense_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)');
    END IF;

    SELECT * INTO v_head FROM public.expense_records WHERE id = p_doc_id;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?•ì •??ë¬¸ì„œë§?ì·¨ì†Œ ê°€?¥í•©?ˆë‹¤.'); END IF;

    -- ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', 'ë§ˆê°???”ì? ?•ì • ì·¨ì†Œ?????†ìŠµ?ˆë‹¤.'); END IF;

    -- ?°ê²° AP ì²´í¬ (ì§€ê¸‰ì•¡ ì¡´ì¬ ??ì°¨ë‹¨)
    IF v_head.is_payable THEN
        SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
        FROM public.accounts_payable 
        WHERE ref_type = 'EXPENSE' AND ref_id = p_doc_id AND status != 'void'
        LIMIT 1;

        IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
            RETURN jsonb_build_object('success', false, 'message', format('?´ë? ì§€ê¸?ì²˜ë¦¬ê°€ ì§„í–‰??ê±´ì…?ˆë‹¤. (ì§€ê¸‰ì•¡: %s) ?Œê³„ ì§€ê¸?ì·¨ì†Œë¥?ë¨¼ì? ì§„í–‰?˜ì„¸??', v_ap_paid));
        END IF;

        IF v_ap_id IS NOT NULL THEN
            UPDATE public.accounts_payable SET status = 'void', remark = format('ë¹„ìš© ?•ì • ì·¨ì†Œë¡??¸í•œ ì·¨ì†Œ (%s)', p_reason) WHERE id = v_ap_id;
        END IF;
    END IF;

    -- ë¡œê·¸ ê¸°ë¡ ë°??íƒœ ?…ë°?´íŠ¸
    UPDATE public.expense_records SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë¹„ìš© ?„í‘œê°€ Draft ?íƒœë¡??˜ì›?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] P&L ?”ì•½ ë·?ê³ ë„??(?ê?ë¹?ì§‘ê³„ ?¬í•¨)
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
),
sga_data AS (
    SELECT 
        to_char(expense_date, 'YYYY-MM') as yyyymm,
        SUM(amount) as total_sga_cost
    FROM public.expense_records
    WHERE status = 'confirmed'
    GROUP BY 1
)
SELECT 
    COALESCE(s.yyyymm, b.yyyymm, g.yyyymm) as yyyymm,
    COALESCE(s.total_revenue, 0) as revenue,
    COALESCE(s.total_cogs, 0) as cogs,
    (COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) as gross_profit,
    COALESCE(b.total_subcon_cost, 0) as subcon_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0)) as operational_gross_profit,
    COALESCE(g.total_sga_cost, 0) as sga_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0) - COALESCE(g.total_sga_cost, 0)) as operating_income
FROM sales_data s
FULL OUTER JOIN subcon_data b ON s.yyyymm = b.yyyymm
FULL OUTER JOIN sga_data g ON COALESCE(s.yyyymm, b.yyyymm) = g.yyyymm OR (s.yyyymm IS NULL AND b.yyyymm IS NULL AND g.yyyymm IS NOT NULL);

GRANT SELECT ON public.v_profit_loss_summary TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_expense_document TO authenticated;
GRANT EXECUTE ON FUNCTION public.unconfirm_expense_document TO authenticated;
-- ==========================================
-- [Phase 7-3] ê±°ë˜ì²˜ë³„ ?˜ìµ??ë¶„ì„ ë·?(SQL)
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

COMMENT ON VIEW public.v_customer_profitability IS 'ê±°ë˜ì²˜ë³„ ?”ë³„ ë§¤ì¶œ, ?ê?, ì´ì´??ë°?ì´ì´?µë¥ ??ë¶„ì„?˜ëŠ” ë·?;

GRANT SELECT ON public.v_customer_profitability TO authenticated;
