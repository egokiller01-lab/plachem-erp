-- ==========================================
-- [Phase 5-4] 거래처 원장(Ledger) 통합 뷰 (SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_ledger AS
-- 1. 매출 (Accounts Receivable - AR)
SELECT 
    id AS source_id,
    customer_id,
    doc_date,
    'AR_SALES' AS ref_type,
    ref_id,
    total_amount AS amount, -- 순채권 증가 (+)
    remark
FROM public.accounts_receivable
WHERE status != 'void'

UNION ALL

-- 2. 수금 (Receipt Records)
SELECT 
    r.id AS source_id,
    ar.customer_id,
    r.receipt_date AS doc_date,
    'RECEIPT' AS ref_type,
    ar.id AS ref_id,
    -r.amount AS amount, -- 순채권 감소 (-)
    r.remark
FROM public.receipt_records r
JOIN public.accounts_receivable ar ON r.ar_id = ar.id
WHERE ar.status != 'void'

UNION ALL

-- 3. 매입/외상 (Accounts Payable - AP)
SELECT 
    id AS source_id,
    vendor_id AS customer_id,
    doc_date,
    'AP_' || ref_type AS ref_type,
    ref_id,
    -total_amount AS amount, -- 순채권 감소 (-) (줄 돈 발생)
    remark
FROM public.accounts_payable
WHERE status != 'void'

UNION ALL

-- 4. 지급 (Payment Records)
SELECT 
    p.id AS source_id,
    ap.vendor_id AS customer_id,
    p.payment_date AS doc_date,
    'PAYMENT' AS ref_type,
    ap.id AS ref_id,
    p.amount AS amount, -- 순채권 증가 (+) (줄 돈 소멸)
    p.remark
FROM public.payment_records p
JOIN public.accounts_payable ap ON p.ap_id = ap.id
WHERE ap.status != 'void';

-- 권한 설정
GRANT SELECT ON public.v_customer_ledger TO authenticated;

-- 대시보드용 요약 뷰 (KPI 상단용)
CREATE OR REPLACE VIEW public.v_accounting_summary AS
SELECT
    -- 총 미수금 (AR 잔액)
    COALESCE(SUM(CASE WHEN ref_type LIKE 'AR%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'RECEIPT' THEN amount ELSE 0 END), 0) AS total_receivable,
    
    -- 총 미지급금 (AP 잔액 - 부호 반전하여 양수로 표시)
    -(COALESCE(SUM(CASE WHEN ref_type LIKE 'AP%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'PAYMENT' THEN amount ELSE 0 END), 0)) AS total_payable
FROM public.v_customer_ledger;

GRANT SELECT ON public.v_accounting_summary TO authenticated;
