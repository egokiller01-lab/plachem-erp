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
