-- ==========================================
-- [Phase 6-2] 주간/월간 자금 추세 분석 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_cash_trend_report(
    p_type varchar(10), -- 'weekly', 'monthly'
    p_limit int DEFAULT 6   -- 최근 6개 주 또는 6개 월
)
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
        RETURN jsonb_build_object('success', false, 'message', '조회 권한이 없습니다.');
    END IF;

    -- 2. 기간 기준 설정 (주간: 월요일 시작)
    IF p_type = 'weekly' THEN
        v_current_period_start := date_trunc('week', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 week')::date;
    ELSE
        v_current_period_start := date_trunc('month', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 month')::date;
    END IF;

    -- 3. 통합 추세 데이터 추출 (최근 N개 기간)
    WITH periods AS (
        SELECT 
            CASE 
                WHEN p_type = 'weekly' THEN (date_trunc('week', CURRENT_DATE) - (n || ' week')::interval)::date
                ELSE (date_trunc('month', CURRENT_DATE) - (n || ' month')::interval)::date
            END AS period_start
        FROM generate_series(0, p_limit - 1) n
    ),
    receipts AS (
        SELECT 
            date_trunc(p_type, receipt_date)::date as p_start,
            SUM(amount) as total_receipt
        FROM public.receipt_records
        GROUP BY 1
    ),
    payments AS (
        SELECT 
            date_trunc(p_type, payment_date)::date as p_start,
            SUM(amount) as total_payment
        FROM public.payment_records
        GROUP BY 1
    ),
    ar_new AS (
        SELECT 
            date_trunc(p_type, doc_date)::date as p_start,
            SUM(total_amount) as new_ar
        FROM public.accounts_receivable
        WHERE status != 'void'
        GROUP BY 1
    ),
    ap_new AS (
        SELECT 
            date_trunc(p_type, doc_date)::date as p_start,
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

    -- 4. 요약 데이터 가공 (현재 vs 전기)
    -- 위 CTE 결과를 활용하여 요약 정보 생성
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
