-- ==========================================
-- [Phase 8-1] 에이징 분석 및 여신한도 관리 (SQL)
-- ==========================================

-- [1] 거래처 마스터 필드 확장
ALTER TABLE public.customers
ADD COLUMN IF NOT EXISTS credit_limit numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_credit_unlimited boolean DEFAULT false;

COMMENT ON COLUMN public.customers.credit_limit IS '여신 한도액 (0 = 외상 불가/현금 거래 전용)';
COMMENT ON COLUMN public.customers.is_credit_unlimited IS '여신 한도 무제한 여부';

-- [2] 에이징 분석 RPC (get_aging_report)
-- 기준일(오늘) 상의 미수/미지급금을 6개 버킷으로 집계
CREATE OR REPLACE FUNCTION public.get_aging_report(p_type varchar) -- 'AR' or 'AP'
RETURNS TABLE (
    customer_id bigint,
    customer_name varchar,
    total_balance numeric,
    bucket_normal numeric,    -- 연체 전
    bucket_pending numeric,   -- due_date IS NULL
    bucket_30 numeric,        -- 1-30일
    bucket_60 numeric,        -- 31-60일
    bucket_90 numeric,        -- 61-90일
    bucket_over_90 numeric    -- 90일 초과
) AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        SELECT 
            c.id as cid,
            c.customer_name as cname,
            (t.total_amount - t.received_amount) as balance, -- AP일 경우 received_amount는 paid_amount로 처리됨
            CASE 
                WHEN t.due_date IS NULL THEN 'pending'
                WHEN t.due_date >= CURRENT_DATE THEN 'normal'
                WHEN (CURRENT_DATE - t.due_date) <= 30 THEN '30'
                WHEN (CURRENT_DATE - t.due_date) <= 60 THEN '60'
                WHEN (CURRENT_DATE - t.due_date) <= 90 THEN '90'
                ELSE 'over_90'
            END as bucket
        FROM (
            SELECT 
                vendor_id as customer_id, 
                due_date, 
                total_amount, 
                COALESCE(received_amount, 0) as received_amount -- AR 테이블 기준
            FROM public.accounts_receivable 
            WHERE p_type = 'AR' AND status != 'paid' AND status != 'void'
            UNION ALL
            SELECT 
                vendor_id as customer_id, 
                due_date, 
                total_amount, 
                COALESCE(paid_amount, 0) as received_amount -- AP 테이블 기준 (paid_amount 사용)
            FROM public.accounts_payable 
            WHERE p_type = 'AP' AND status != 'paid' AND status != 'void'
        ) t
        JOIN public.customers c ON t.customer_id = c.id
        WHERE (t.total_amount - t.received_amount) > 0
    )
    SELECT 
        cid,
        cname,
        SUM(balance) as total_balance,
        SUM(CASE WHEN bucket = 'normal' THEN balance ELSE 0 END) as bucket_normal,
        SUM(CASE WHEN bucket = 'pending' THEN balance ELSE 0 END) as bucket_pending,
        SUM(CASE WHEN bucket = '30' THEN balance ELSE 0 END) as bucket_30,
        SUM(CASE WHEN bucket = '60' THEN balance ELSE 0 END) as bucket_60,
        SUM(CASE WHEN bucket = '90' THEN balance ELSE 0 END) as bucket_90,
        SUM(CASE WHEN bucket = 'over_90' THEN balance ELSE 0 END) as bucket_over_90
    FROM base_data
    GROUP BY 1, 2
    ORDER BY total_balance DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [3] 여신 한도 체크 RPC (check_customer_credit)
-- 특정 거래처의 현재 여신 상태와 신규 매출액을 비교하여 경고값 반환
CREATE OR REPLACE FUNCTION public.check_customer_credit(p_customer_id bigint, p_new_amount numeric)
RETURNS jsonb AS $$
DECLARE
    v_limit numeric;
    v_unlimited boolean;
    v_current_ar numeric;
    v_total_exposure numeric;
BEGIN
    -- 한도 정보 조회
    SELECT credit_limit, is_credit_unlimited INTO v_limit, v_unlimited
    FROM public.customers WHERE id = p_customer_id;

    IF v_unlimited THEN
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'is_unlimited', true);
    END IF;

    -- 현재 채권 잔액 집계
    SELECT COALESCE(SUM(total_amount - received_amount), 0) INTO v_current_ar
    FROM public.accounts_receivable
    WHERE vendor_id = p_customer_id AND status != 'paid' AND status != 'void';

    v_total_exposure := v_current_ar + p_new_amount;

    IF v_total_exposure > v_limit THEN
        RETURN jsonb_build_object(
            'is_exceeded', true, 
            'limit', v_limit, 
            'current_ar', v_current_ar, 
            'new_amount', p_new_amount,
            'excess_amount', v_total_exposure - v_limit,
            'message', format('여신 한도(%s)를 %s 초과했습니다.', v_limit, (v_total_exposure - v_limit))
        );
    ELSE
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'current_ar', v_current_ar);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_aging_report TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_customer_credit TO authenticated;
