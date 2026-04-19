# [PLACHEM ERP] Project Handoff

## 1. 현재 기술 스택 및 환경
- **Frontend**: Next.js 14 (App Router)
- **Styling**: Vanilla CSS (Global Design System)
- **Backend/DB**: Supabase (PostgreSQL)
- **Auth**: Supabase Auth (Implicit Roles in `profiles` table)

## 2. 권한 및 계정 정보 (운영 기준)
- **Admin**: 여신 초과 전표 강제/예외 승인(Phase 8), 전표 취소, 마감 재오픈 등 최상위 제어권장.
- **Manager**: 전표 확정 권한 및 통계 조회 유지.
- **Staff**: 조회 및 Draft 상태 전표 입력/수정 가능.

## 3. 핵심 아키텍처 요약 (Phase 8 완료 기준)
- **MAC & 결산 엔진**: 재고 보정과 월마감 스냅샷 자동화 연계 확립.
- **BOM & 생산 연동(Phase 4)**: 활성 BOM Version 자동 합산 및 SUBCON 외주 판별, 생산 단가 정산 시스템 구동.
- **AP/AR & 자금(Phase 5/6)**: `register_receipt`를 통한 수금 잔액 자동 처리 및 일/월간 자금 흐름 리포트 바인딩 완료.
- **손익/판관비(Phase 7)**: Moving Avg Cost 기준 거래처별 수익성 추출 View 적용.
- **RLS/여신 하드 블록(Phase 8)**: 고객 여신 한도 모니터링(`check_customer_credit`) 및 초과 시 `confirm_sales_document` 내 원천 차단 오류 반환. 단, Admin UI(`credit-approvals`) 승인 시 예외 패스 처리.

## 4. 잔여 과제 및 후속 단계
- 개발 및 DB 적용은 모두 완료.
- **코드 정합화**: 로컬상으로 방대해진 프론트엔드 라우팅 폴더와 기반 데이터 스크립트를 커밋 그룹(A~D)으로 나누어 버전 관리 상에 무결성 있게 안착시키는 작업만이 남아있음 (현재 동기화 대기 중).

---
*Last Updated by AntiGravity - 2026-04-19*
