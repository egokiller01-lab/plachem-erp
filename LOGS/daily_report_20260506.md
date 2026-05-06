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
- `policy_count=0` 테이블 조회 화면 복구용 SELECT 정책 9개 적용 (`schema_security_patch_20260506.sql`에 기록)
- `/prices`, `/accounting/ap`, `/accounting/ar` 등 조회 테스트 정상화 목적. 이후 단가 관리, 여신 예외 요청, 일반 판관비의 1차 쓰기 정책 일부 적용.

## 남은 과제
- 조회용 SELECT 정책은 1차 적용 완료. 남은 과제는 INSERT/UPDATE/DELETE 쓰기 정책 설계 및 실제 업무 시나리오 테스트.
- RLS 정책 변경에 따른 프론트엔드 화면 동작 및 업무 시나리오 테스트

### 1차 쓰기 RLS 정책 적용 및 테스트 결과
- **`customer_product_prices` (단가 관리)**
  - INSERT/UPDATE 정책(`cpp_insert_mgr`, `cpp_update_mgr`) DB 적용 및 화면 연동 테스트 성공
  - DELETE 정책(`cpp_delete_mgr`) DB 적용 완료 (화면에 삭제 UI가 없어 테스트 보류)
- **`credit_exception_requests` (여신 예외 요청)**
  - INSERT 정책(`cer_insert_auth`) DB 적용 완료, 화면 테스트는 추후 진행
- **`expense_records` (일반 판관비 관리)**
  - `created_by` 컬럼 추가 및 작성자 기반 RLS 정책(`er_insert_auth`, `er_update_draft`) 적용 완료
  - 화면에서 신규 비용 등록 및 수정 테스트 성공 확인
