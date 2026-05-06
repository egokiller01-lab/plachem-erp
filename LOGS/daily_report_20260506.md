# 2026-05-06 PLACHEM ERP Security Remediation Daily Report

## 주요 작업 내역
- Supabase 보안 감사(Audit) 결과 반영
- `anon` 권한 과다 노출 발견 및 조치
- `anon` 그룹의 전체 table/sequence 권한 회수 (REVOKE)
- `authenticated` 그룹의 위험 구조 권한(TRUNCATE, TRIGGER, REFERENCES) 회수
- `customers` 및 `customer_product_prices` 테이블 RLS(Row Level Security) 활성화
- `sales_headers`, `purchase_headers`의 구버전 약한 보안 정책(Policies) 제거
- 화면 테스트 중 `public.get_my_role()` 누락 오류 발견
- Supabase SQL Editor에서 `get_my_role()` 복구 실행
- `search_path` 포함 `SECURITY DEFINER` 함수로 보안 강화
- 오류 해소 확인
- repo 재현성을 위해 `schema_security_patch_20260506.sql`에 반영


## 남은 과제
- `policy_count=0`인 테이블(예: `customer_product_prices`) 정책(Policy) 설계 및 적용
- RLS 정책 변경에 따른 프론트엔드 화면 동작 및 업무 시나리오 테스트

### [후보] customer_product_prices 신규 RLS 정책안
*(※ 아래 정책들은 아직 실행 또는 SQL 파일에 반영되지 않은 초안입니다.)*

- **SELECT (모든 로그인 사용자 조회 허용)**
```sql
CREATE POLICY "cpp_select_authenticated"
ON public.customer_product_prices
FOR SELECT TO authenticated
USING (true);
```

- **INSERT (관리자 전용)**
```sql
CREATE POLICY "cpp_insert_admin"
ON public.customer_product_prices
FOR INSERT TO authenticated
WITH CHECK (public.auth_is_admin());
```

- **UPDATE (관리자 전용)**
```sql
CREATE POLICY "cpp_update_admin"
ON public.customer_product_prices
FOR UPDATE TO authenticated
USING (public.auth_is_admin())
WITH CHECK (public.auth_is_admin());
```

- **DELETE (관리자 전용)**
```sql
CREATE POLICY "cpp_delete_admin"
ON public.customer_product_prices
FOR DELETE TO authenticated
USING (public.auth_is_admin());
```
