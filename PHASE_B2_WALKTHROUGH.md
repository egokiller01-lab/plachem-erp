# [PLACHEM ERP] Phase B2 완료 보고서 (Walkthrough)

본 문서는 PLACHEM ERP의 데이터 정합성 유지와 유연한 운영을 위한 **Phase B2: 마감/확정 취소 및 조정 전표 엔진** 구현 결과를 정리한 문서입니다.

---

## 1. 개요 및 목적 (Executive Summary)

과거 데이터의 수정이 불가능한 ERP의 폐쇄성 문제를 해결하면서도, 데이터 무결성을 훼손하지 않는 두 가지 경로를 구축하였습니다.
1.  **Reopen & Unconfirm**: 직전 월에 한해 장부를 열고(Reopen) 특정 전표를 취소(Unconfirm)하여 재확정하는 방식.
2.  **Adjustment (보정)**: 과거의 오류를 현재 열려 있는 달에서 수량/원가 보정 전표를 통해 해결하는 방식.

---

## 2. 구현 범위 (Implementation Scope)

### DB 및 서버 로직 (Backend/RPC)
- **`inventory_adjustments`**: 재고/원가 차액 보정 정보를 저장하는 신규 테이블.
- **`document_history_logs`**: 취소 사유와 원본 데이터 스냅샷(JSONB)을 보관하는 감사 추적용 테이블.
- **RPC 통합**: 
  - `recalculate_mac_for_product`: 조정 전표를 포함한 실시간 MAC 재계산.
  - `execute_monthly_closing`: 조정 전표를 수불 내역에 포함하여 기말 자산 정산.

### UI 및 권한 제어 (Frontend/Access Control)
- **Admin 전용 버튼**: 전표 상세 페이지 및 월마감 관리 페이지에 **[Unconfirm]**, **[Reopen]** 버튼 연동.
- **조정 전표 화면**: [Inventory Adjustment](file:///d:/plachem/src/app/inventory/adjustment/page.tsx) 관리자 전용 입력 화면 구축.
- **차단 규칙**:
  - `Staff/Manager`: 취소 및 조정 기능 접근 불가.
  - **Sealed 월 차단**: 이미 마감 완료된 과거 월의 전표는 `Admin`이라도 직접 수정 불가.

---

## 3. 상태 흐름 및 운영 프로세스 (Workflow)

### 문서 상태 전이 (Status Flow)
- **전표**: `Draft` ↔ `Confirmed` (Unconfirm 시 Draft로 환원)
- **월마감**: `Draft` ↔ `Closed` (Reopen 시 Draft로 환원)
- **조정**: 입력 즉시 자산 반영 (취소 불가, 필요 시 역보정 전표 발행)

### 실무 운영 시나리오
1.  **직전 월 오류 발견**: `Monthly Closing` 화면에서 **Reopen** (Admin) 
2.  **전표 수정**: 해당 전표 상세에서 **Unconfirm** (Admin) → 사유 입력 → `Draft` 상태에서 수정 → **Confirm**
3.  **데이터 보정**: 마감 취소가 어려운 과거 데이터는 `Adjustment` 화면에서 **STOCK/COST** 보정 전표 발행
4.  **최종 확인**: 월마감 **Execute**를 통해 보정분이 반영된 기말 재고/금액 확정

---

## 4. 로그 및 감사 추적 (Audit Trail)

모든 취소 액션은 **`document_history_logs`**에 기록됩니다.
- **저장 정보**: 실행자(UUID), 시각, 취소 사유(Reason), 원본 데이터(Original JSON).
- **운영상 의미**: 상시 점검 가능한 감사 추적성 확보.

---

## 5. 통합 테스트 결과 요약

| 테스트 항목 | 검증 내용 | 결과 |
| :--- | :--- | :---: |
| **Unconfirm** | 확정 취소 시 재고 및 MAC 역반영 | **Pass** |
| **Reopen** | 직전 월 외의 마감 취소 시도 차단 | **Pass** |
| **Adjustment** | 보정분 입력 시 실시간 MAC 변동 및 마감 연동 | **Pass** |
| **Security** | Staff/Manager 계정의 관리 버튼 비노출 | **Pass** |

---

## 6. 운영 주의사항 (Critical Notes)

> [!CAUTION]
> **음수 재고 관리**
> 조정 전표로 인해 특정 시점의 재고가 음수가 될 경우 월마감 검증 시 에러가 발생합니다.

> [!IMPORTANT]
> **소급 제한 원칙**
> Adjustment는 과거 달의 숫자를 직접 바꾸지 않고 "현재" 장부에서 정합성을 맞춥니다.

---

계속 작업이 필요한 후속 과제로는 로그 조회 UI 추가 등이 있습니다.
