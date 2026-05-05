# 2026-05-05 Profiles RLS Security Remediation

## 문제
- profiles 테이블에 authenticated 전체 SELECT 허용 정책이 존재
- Admin can update profiles 구정책은 profiles self-reference로 recursion 위험

## 삭제된 정책
- Authenticated users can view profiles
- Admin can update profiles

## 최종 유지 정책
- `rls_erp_profiles_select_self`: SELECT, id = auth.uid()
- `rls_erp_profiles_select_admin`: SELECT, public.auth_is_admin()
- `rls_erp_profiles_update_admin`: UPDATE, public.auth_is_admin(), WITH CHECK public.auth_is_admin()

## auth_is_admin 함수 요약
- SECURITY DEFINER
- search_path public
- 현재 auth.uid() 사용자의 profiles.role = admin 여부 확인

## 보안 판단
- staff 전체 profiles 열람 차단
- admin은 전체 조회/수정 가능
- self-read 가능
- recursion 위험 제거

## 주의
- SQL archive 파일은 실행용이 아니라 보존용
- RLS 변경은 반드시 OpenClaw 검수 후 실행

## 다음 보안 작업
- 전체 public schema RLS audit
- 주요 테이블 policy 점검
- anon/authenticated 노출 범위 확인
- service_role 사용 경로 검토
