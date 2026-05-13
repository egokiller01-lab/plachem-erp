-- ==========================================
-- [Phase 6-1] ?일 ?금 보고???이??집계 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_daily_cash_report(p_date date)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_prev_date date := p_date - INTERVAL '1 day';
    
    -- ?일 집계
    v_today_receipt numeric := 0;
    v_today_payment numeric := 0;
    v_today_new_ar numeric := 0;
    v_today_new_ap numeric := 0;
    
    -- ?일 집계
    v_prev_receipt numeric := 0;
    v_prev_payment numeric := 0;
    v_prev_new_ar numeric := 0;
    v_prev_new_ap numeric := 0;
    
    -- ?세 가??이??    v_receipt_details jsonb;
    v_payment_details jsonb;
    v_overdue_ar jsonb;
    v_overdue_ap jsonb;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한???습?다.');
    END IF;

    -- 2. ?일 집계 (Receipts, Payments, New AR/AP)
    SELECT COALESCE(SUM(amount), 0) INTO v_today_receipt FROM public.receipt_records WHERE receipt_date = p_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_today_payment FROM public.payment_records WHERE payment_date = p_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ar FROM public.accounts_receivable WHERE doc_date = p_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ap FROM public.accounts_payable WHERE doc_date = p_date AND status != 'void';

    -- 3. ?일 집계
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_receipt FROM public.receipt_records WHERE receipt_date = v_prev_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_payment FROM public.payment_records WHERE payment_date = v_prev_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ar FROM public.accounts_receivable WHERE doc_date = v_prev_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ap FROM public.accounts_payable WHERE doc_date = v_prev_date AND status != 'void';

    -- 4. ?세 리스??(?일)
    SELECT jsonb_agg(sub) INTO v_receipt_details FROM (
        SELECT r.receipt_date, r.amount, r.payment_method, c.customer_name, r.remark
        FROM public.receipt_records r
        JOIN public.accounts_receivable ar ON r.ar_id = ar.id
        JOIN public.customers c ON ar.customer_id = c.id
        WHERE r.receipt_date = p_date
        ORDER BY r.id DESC
    ) sub;

    SELECT jsonb_agg(sub) INTO v_payment_details FROM (
        SELECT p.payment_date, p.amount, p.payment_method, c.customer_name, p.remark
        FROM public.payment_records p
        JOIN public.accounts_payable ap ON p.ap_id = ap.id
        JOIN public.customers c ON ap.vendor_id = c.id
        WHERE p.payment_date = p_date
        ORDER BY p.id DESC
    ) sub;

    -- 5. ?체 ?약 (?체 기? Top 5)
    SELECT jsonb_agg(sub) INTO v_overdue_ar FROM (
        SELECT c.customer_name, (ar.total_amount - ar.received_amount) as balance, ar.due_date
        FROM public.accounts_receivable ar
        JOIN public.customers c ON ar.customer_id = c.id
        WHERE ar.status NOT IN ('paid', 'void') AND ar.due_date < CURRENT_DATE
        ORDER BY balance DESC LIMIT 5
    ) sub;

    SELECT jsonb_agg(sub) INTO v_overdue_ap FROM (
        SELECT c.customer_name, (ap.total_amount - ap.paid_amount) as balance, ap.due_date
        FROM public.accounts_payable ap
        JOIN public.customers c ON ap.vendor_id = c.id
        WHERE ap.status NOT IN ('paid', 'void') AND ap.due_date < CURRENT_DATE
        ORDER BY balance DESC LIMIT 5
    ) sub;

    -- 6. ?합 메시지 반환
    RETURN jsonb_build_object(
        'success', true,
        'selected_date', p_date,
        'summary', jsonb_build_object(
            'receipt', jsonb_build_object('today', v_today_receipt, 'prev', v_prev_receipt),
            'payment', jsonb_build_object('today', v_today_payment, 'prev', v_prev_payment),
            'net_flow', jsonb_build_object('today', v_today_receipt - v_today_payment, 'prev', v_prev_receipt - v_prev_payment),
            'ar_change', jsonb_build_object('today', v_today_new_ar - v_today_receipt, 'prev', v_prev_new_ar - v_prev_receipt),
            'ap_change', jsonb_build_object('today', v_today_new_ap - v_today_payment, 'prev', v_prev_new_ap - v_prev_payment)
        ),
        'details', jsonb_build_object(
            'receipts', COALESCE(v_receipt_details, '[]'::jsonb),
            'payments', COALESCE(v_payment_details, '[]'::jsonb)
        ),
        'overdue', jsonb_build_object(
            'ar', COALESCE(v_overdue_ar, '[]'::jsonb),
            'ap', COALESCE(v_overdue_ap, '[]'::jsonb)
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_daily_cash_report TO authenticated;
-- ==========================================
-- [Phase 6-2] 주간/?간 ?금 추세 분석 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_cash_trend_report(
    p_type varchar(10), -- 'week'/'weekly', 'month'/'monthly'
    p_limit int DEFAULT 6   -- 최근 6???는 6???)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_result jsonb;
    v_trend_data jsonb;
    v_summary jsonb;
    v_current_period_start date;
    v_prev_period_start date;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한???습?다.');
    END IF;

    -- 2. 기간 기? ?정 (주간: ?요???작)
    IF p_type IN ('week', 'weekly') THEN
        v_current_period_start := date_trunc('week', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 week')::date;
    ELSE
        v_current_period_start := date_trunc('month', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 month')::date;
    END IF;

    -- 3. ?합 추세 ?이??추출 (최근 N?기간)
    WITH periods AS (
        SELECT 
            CASE 
                WHEN p_type IN ('week', 'weekly') THEN (date_trunc('week', CURRENT_DATE) - (n || ' week')::interval)::date
                ELSE (date_trunc('month', CURRENT_DATE) - (n || ' month')::interval)::date
            END AS period_start
        FROM generate_series(0, p_limit - 1) n
    ),
    receipts AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, receipt_date)::date as p_start,
            SUM(amount) as total_receipt
        FROM public.receipt_records
        GROUP BY 1
    ),
    payments AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, payment_date)::date as p_start,
            SUM(amount) as total_payment
        FROM public.payment_records
        GROUP BY 1
    ),
    ar_new AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, doc_date)::date as p_start,
            SUM(total_amount) as new_ar
        FROM public.accounts_receivable
        WHERE status != 'void'
        GROUP BY 1
    ),
    ap_new AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, doc_date)::date as p_start,
            SUM(total_amount) as new_ap
        FROM public.accounts_payable
        WHERE status != 'void'
        GROUP BY 1
    )
    SELECT jsonb_agg(sub) INTO v_trend_data FROM (
        SELECT 
            p.period_start,
            COALESCE(r.total_receipt, 0) as receipt,
            COALESCE(pay.total_payment, 0) as payment,
            COALESCE(an.new_ar, 0) as new_ar,
            COALESCE(pn.new_ap, 0) as new_ap,
            (COALESCE(r.total_receipt, 0) - COALESCE(pay.total_payment, 0)) as net_flow
        FROM periods p
        LEFT JOIN receipts r ON p.period_start = r.p_start
        LEFT JOIN payments pay ON p.period_start = pay.p_start
        LEFT JOIN ar_new an ON p.period_start = an.p_start
        LEFT JOIN ap_new pn ON p.period_start = pn.p_start
        ORDER BY p.period_start ASC
    ) sub;

    -- 4. ?약 ?이??가?(?재 vs ?기)
    -- ??CTE 결과??용?여 ?약 ?보 ?성
    v_summary := jsonb_build_object(
        'current', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_current_period_start),
        'prev', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_prev_period_start)
    );

    RETURN jsonb_build_object(
        'success', true,
        'type', p_type,
        'trend', v_trend_data,
        'summary', v_summary
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_cash_trend_report TO authenticated;
