-- ==============================================================================
-- PLACHEM ERP Supabase Security Remediation (Applied 2026-05-06)
-- Target: Revoke excessive anon/authenticated privileges and remove old policies
-- ==============================================================================

-- 1. anon 권한 과다 노출 회수
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- 2. authenticated 위험 구조 권한 회수
REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM authenticated;

-- 3. RLS 활성화
ALTER TABLE public.customer_product_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

-- 4. View 직접 수정 방지
REVOKE INSERT, UPDATE, DELETE ON TABLE public.v_accounting_summary FROM authenticated;

-- 5. 구버전(취약) RLS 정책 제거
DROP POLICY IF EXISTS "PH_Edit_Draft" ON public.purchase_headers;
DROP POLICY IF EXISTS "PH_Insert" ON public.purchase_headers;
DROP POLICY IF EXISTS "PH_Select" ON public.purchase_headers;

DROP POLICY IF EXISTS "SH_Edit_Draft" ON public.sales_headers;
DROP POLICY IF EXISTS "SH_Insert" ON public.sales_headers;
DROP POLICY IF EXISTS "SH_Select" ON public.sales_headers;

-- 6. RPC 권한 함수 보안 패치 (SQL Injection 방어 및 누락 복구)
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
    SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

-- 7. 화면 조회 안정화를 위한 읽기 전용(SELECT) RLS 1차 적용 (9개 테이블)
-- (관리자/개발자가 수동 적용한 정책을 repo 재현성에 맞게 추가)

DROP POLICY IF EXISTS "ap_select_authenticated" ON public.accounts_payable;
CREATE POLICY "ap_select_authenticated" ON public.accounts_payable FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "ar_select_authenticated" ON public.accounts_receivable;
CREATE POLICY "ar_select_authenticated" ON public.accounts_receivable FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "payment_records_select_authenticated" ON public.payment_records;
CREATE POLICY "payment_records_select_authenticated" ON public.payment_records FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "receipt_records_select_authenticated" ON public.receipt_records;
CREATE POLICY "receipt_records_select_authenticated" ON public.receipt_records FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "expense_categories_select_authenticated" ON public.expense_categories;
CREATE POLICY "expense_categories_select_authenticated" ON public.expense_categories FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "expense_records_select_authenticated" ON public.expense_records;
CREATE POLICY "expense_records_select_authenticated" ON public.expense_records FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "credit_exception_requests_select_authenticated" ON public.credit_exception_requests;
CREATE POLICY "credit_exception_requests_select_authenticated" ON public.credit_exception_requests FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "document_history_logs_select_authenticated" ON public.document_history_logs;
CREATE POLICY "document_history_logs_select_authenticated" ON public.document_history_logs FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "customer_product_prices_select_authenticated" ON public.customer_product_prices;
CREATE POLICY "customer_product_prices_select_authenticated" ON public.customer_product_prices FOR SELECT TO authenticated USING (true);

-- 8. 1차 쓰기 권한(INSERT/UPDATE/DELETE) RLS 적용 (수동 적용 내역 repo 재현성)
DROP POLICY IF EXISTS "cpp_insert_mgr" ON public.customer_product_prices;
CREATE POLICY "cpp_insert_mgr" ON public.customer_product_prices FOR INSERT TO authenticated WITH CHECK (public.get_my_role() IN ('manager', 'admin'));

DROP POLICY IF EXISTS "cpp_update_mgr" ON public.customer_product_prices;
CREATE POLICY "cpp_update_mgr" ON public.customer_product_prices FOR UPDATE TO authenticated USING (public.get_my_role() IN ('manager', 'admin')) WITH CHECK (public.get_my_role() IN ('manager', 'admin'));

DROP POLICY IF EXISTS "cpp_delete_mgr" ON public.customer_product_prices;
CREATE POLICY "cpp_delete_mgr" ON public.customer_product_prices FOR DELETE TO authenticated USING (public.get_my_role() IN ('manager', 'admin'));

DROP POLICY IF EXISTS "cer_insert_auth" ON public.credit_exception_requests;
CREATE POLICY "cer_insert_auth" ON public.credit_exception_requests FOR INSERT TO authenticated WITH CHECK (requested_by = auth.uid());
