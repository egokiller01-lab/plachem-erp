-- ==========================================
-- [Phase 6-1] 일일 자금 보고서 데이터 집계 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_daily_cash_report(p_date date)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_prev_date date := p_date - INTERVAL '1 day';
    
    -- 당일 집계
    v_today_receipt numeric := 0;
    v_today_payment numeric := 0;
    v_today_new_ar numeric := 0;
    v_today_new_ap numeric := 0;
    
    -- 전일 집계
    v_prev_receipt numeric := 0;
    v_prev_payment numeric := 0;
    v_prev_new_ar numeric := 0;
    v_prev_new_ap numeric := 0;
    
    -- 상세 가공 데이터
    v_receipt_details jsonb;
    v_payment_details jsonb;
    v_overdue_ar jsonb;
    v_overdue_ap jsonb;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한이 없습니다.');
    END IF;

    -- 2. 당일 집계 (Receipts, Payments, New AR/AP)
    SELECT COALESCE(SUM(amount), 0) INTO v_today_receipt FROM public.receipt_records WHERE receipt_date = p_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_today_payment FROM public.payment_records WHERE payment_date = p_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ar FROM public.accounts_receivable WHERE doc_date = p_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ap FROM public.accounts_payable WHERE doc_date = p_date AND status != 'void';

    -- 3. 전일 집계
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_receipt FROM public.receipt_records WHERE receipt_date = v_prev_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_payment FROM public.payment_records WHERE payment_date = v_prev_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ar FROM public.accounts_receivable WHERE doc_date = v_prev_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ap FROM public.accounts_payable WHERE doc_date = v_prev_date AND status != 'void';

    -- 4. 상세 리스트 (당일)
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

    -- 5. 연체 요약 (전체 기준 Top 5)
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

    -- 6. 통합 메시지 반환
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
