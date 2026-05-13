-- Patch: Fix get_cash_trend_report period parameter normalization
-- Reason: date_trunc() accepts 'week'/'month', but UI previously sent 'weekly'/'monthly'.
-- This function accepts both forms and normalizes internally.

CREATE OR REPLACE FUNCTION public.get_cash_trend_report(
    p_type varchar(10), -- 'week'/'weekly', 'month'/'monthly'
    p_limit int DEFAULT 6
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_result jsonb;
    v_trend_data jsonb;
    v_summary jsonb;
    v_period text;
    v_current_period_start date;
    v_prev_period_start date;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한이 없습니다.');
    END IF;

    v_period := CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END;

    IF v_period = 'week' THEN
        v_current_period_start := date_trunc('week', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 week')::date;
    ELSE
        v_current_period_start := date_trunc('month', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 month')::date;
    END IF;

    WITH periods AS (
        SELECT
            CASE
                WHEN v_period = 'week' THEN (date_trunc('week', CURRENT_DATE) - (n || ' week')::interval)::date
                ELSE (date_trunc('month', CURRENT_DATE) - (n || ' month')::interval)::date
            END AS period_start
        FROM generate_series(0, p_limit - 1) n
    ),
    receipts AS (
        SELECT date_trunc(v_period, receipt_date)::date AS p_start, SUM(amount) AS total_receipt
        FROM public.receipt_records
        GROUP BY 1
    ),
    payments AS (
        SELECT date_trunc(v_period, payment_date)::date AS p_start, SUM(amount) AS total_payment
        FROM public.payment_records
        GROUP BY 1
    ),
    ar_new AS (
        SELECT date_trunc(v_period, doc_date)::date AS p_start, SUM(total_amount) AS new_ar
        FROM public.accounts_receivable
        WHERE status != 'void'
        GROUP BY 1
    ),
    ap_new AS (
        SELECT date_trunc(v_period, doc_date)::date AS p_start, SUM(total_amount) AS new_ap
        FROM public.accounts_payable
        WHERE status != 'void'
        GROUP BY 1
    )
    SELECT jsonb_agg(sub) INTO v_trend_data FROM (
        SELECT
            p.period_start,
            COALESCE(r.total_receipt, 0) AS receipt,
            COALESCE(pay.total_payment, 0) AS payment,
            COALESCE(an.new_ar, 0) AS new_ar,
            COALESCE(pn.new_ap, 0) AS new_ap,
            (COALESCE(r.total_receipt, 0) - COALESCE(pay.total_payment, 0)) AS net_flow
        FROM periods p
        LEFT JOIN receipts r ON p.period_start = r.p_start
        LEFT JOIN payments pay ON p.period_start = pay.p_start
        LEFT JOIN ar_new an ON p.period_start = an.p_start
        LEFT JOIN ap_new pn ON p.period_start = pn.p_start
        ORDER BY p.period_start ASC
    ) sub;

    v_summary := jsonb_build_object(
        'current', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_current_period_start),
        'prev', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_prev_period_start)
    );

    RETURN jsonb_build_object(
        'success', true,
        'type', v_period,
        'trend', v_trend_data,
        'summary', v_summary
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_cash_trend_report TO authenticated;
