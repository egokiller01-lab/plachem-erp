# 일일 보고서 (2026-05-07)

## 1. 주요 작업 내용
- [x] /sales 제품 선택기(`ProductSelector`) 드롭다운 목록 미표시 이슈 해결
- [x] ProductSelector React.memo 적용 및 sales/page.tsx handleProductSelect React.useCallback 적용으로 렌더링 안정화
- [x] sales_items / purchase_items RLS DELETE 정책 분석 및 검토

## 2. RLS 정책 점검 및 결정 사항 (A안 유지)
### 현황
- `sales_items` 및 `purchase_items`는 기존 repo 파일 `schema_update_phase4_b1_items_rls.sql`을 기준으로 `SI_Write_If_Draft`, `PI_Write_If_Draft` 정책이 존재함.
- 해당 정책은 `FOR ALL` 설정으로, 상위 전표가 `draft` 상태일 때 `INSERT/UPDATE/DELETE`를 모두 허용함.

### 결정 사항
- **현행 정책 유지**: 신규 명명 규칙(`si_delete_draft` 등)으로의 교체 과정에서 발생할 수 있는 품목 추가/수정 기능 장애 위험을 방지하기 위해 기존 `FOR ALL` 정책을 유지함.
- **교체 보류**: `si_delete_draft` 등 삭제 전용 정책만 단독 추가하거나 기존 정책을 섣불리 DROP 하지 않음.
- **실DB 상태**: 테스트 환경 계정 미확보로 인해 실제 DB 적용 상태는 아직 교차 검증 전이나, repo SQL 상으로는 안정적으로 정의되어 있음.

### 향후 계획
- 차후 정책 표준화 작업 시, `INSERT/UPDATE/DELETE`를 모두 행위별로 분리하고 신규 명명 규칙을 적용하는 **B안**을 별도 설계하여 일괄 적용함.

## 3. 검증 결과
- `ProductSelector`: 고객 선택 후 드롭다운 클릭 시 목록 10건 정상 표시 및 검색 기능 안정화 확인.
- `Build`: `npm run build` 성공.
