# PLACHEM ERP - Daily Report (2026-05-12)

## 1. Today's Frontend Fixes
- **문서 번호 빈 값 처리**: `/sales` 및 `/purchase` 전표 저장 시, 문서 번호가 수동으로 입력되지 않은 경우 400 에러를 방지하기 위해 빈 값을 페이로드에서 완전히 생략(`omit`)하도록 수정했습니다.
- **`sales_items` 스키마 불일치(400) 수정**: DB 스키마에 존재하지 않는 컬럼(`product_code`, `price_source`, `created_by`)을 제거하여 저장 시 400 Bad Request 발생을 해결했습니다.
- **`purchase_headers` 외래키 불일치(400) 수정**: `supplier_id` 컬럼 부재로 인한 `PGRST204` 에러를 해결하기 위해, `src/app/purchase/page.tsx` 내의 인터페이스, 상태값(State), 입력 UI, 페이로드 전송 키를 모두 실제 스키마인 `customer_id`로 일괄 변경했습니다.
- **단가 View 필터 오류(400) 수정**: `v_customer_product_current_prices` 뷰 조회 시 필터 조건을 존재하지 않는 `_code` 문자열 대신 외래키 기준인 `customer_id`, `product_id`로 수정했습니다.

## 2. Supabase SQL / RLS Changes (Executed by 김대표님)
- **Auto-numbering Trigger 적용**: 승인된 SQL을 통해 `sales_headers` 및 `purchase_headers`에 채번 시퀀스와 `BEFORE INSERT` 트리거를 도입하여 문서 번호가 빈 값일 때 `[SL/PU]-YYYYMMDD-####` 패턴으로 자동 생성되도록 조치했습니다.
- **전표 및 품목 기본 RLS 복구**: 보안 패치 과정에서 유실된 핵심 RLS 권한을 복구하여 `draft` 상태의 전표 쓰기 권한을 정상화했습니다.
- **Inventory Confirm-Flow 전환 (최종)**: 김대표님이 검토된 SQL을 실행하여 재고 기록 시점을 전표 확정(`confirmed`) 시점으로 이관했습니다.
  - 레거시 트리거(`trg_sales_items_inventory_aiud`, `trg_purchase_items_inventory_aiud`)를 제거하여 Draft 저장 시의 RLS 403 에러를 근본적으로 해결했습니다.

## 3. Verification Results
- **/sales Draft 저장 성공**: 
  - `sales_headers` 및 `sales_items` 모두 `201 Created` 반환.
  - 생성된 Draft ID: `32`.
- **/purchase Draft 저장 성공**: 
  - `purchase_headers` 및 `purchase_items` 모두 `201 Created` 반환.
  - 생성된 Draft ID: `12`, 전표 번호: `PU-20260512-0009`.
- **RLS 이슈 해결**: `inventory_transactions` 테이블의 RLS 403 에러가 Draft 아이템 저장 시 더 이상 발생하지 않음을 확인했습니다.

## 4. Remaining Blockers
1. **Confirm/Unconfirm Flow 검증**: 재고 로직이 이관된 RPC(`confirm_sales_document` 등)의 실제 작동 및 재고 반영 여부에 대한 통합 테스트가 필요합니다. (별도 승인 후 진행 예정)
2. **Review Price View 406 Behavior**: `v_customer_product_current_prices` 조회 시 발생하는 HTTP 406 (Not Acceptable) 응답 이슈에 대한 분석 및 수정이 필요합니다.
