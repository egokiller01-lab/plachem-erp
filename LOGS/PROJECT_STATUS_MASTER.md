# [MASTER] PLACHEM ERP 프로젝트 상태 및 작업 지침서 (Project Status Master)

**현재 단계**: 운영 전환 준비 (Phase 1~8 개발 완료 및 검증 단계)

이 문서는 새로운 에이전트가 투입될 때 프로젝트의 전체 맥락을 즉시 파악하고, 불필요한 분석 시간 없이 바로 업무에 투입될 수 있도록 돕는 **최상위 지침서**입니다.

---

## 0. 프로젝트 마일스톤 및 Phase 8 완료 현황
- **Phase 1~7**: 기초 인프라, 매입/매출/재고, 월결산, 생산(BOM), 회계연동, 자금보고, 손익분석 완료.
- **Phase 8 (완료)**: **에이징(Aging), 여신한도(Credit Limit), 하드 블로킹(Hard Blocking)**.
  - 고객별 여신 한도 설정 및 실시간 Aging 분석 뷰어 구축.
  - 여신 초과 시 전표 확정이 원천 차단되는 Hard Block 로직 및 관리자 예외 승인 프로세스 완비.
- **현재 상태**: 모든 단계의 개발이 완료되었으며, 현재는 운영기 전환을 위한 UI 고도화 및 정합성 검증 단계임.

## 1. 프로젝트 핵심 정보

### 🎯 목표
- 화학 제품 제조 및 유통을 위한 PLACHEM 전용 ERP 시스템 구축.
- 정확한 재고 흐름(FIFO/이동평균법)과 금융 리스크 관리(여신 한도)가 핵심.

### 🛠 기술 스택
- **Frontend**: Next.js (App Router), Vanilla CSS, TypeScript.
- **Backend/DB**: Supabase (PostgreSQL), Edge Functions (일부).
- **Security**: Supabase RLS (Row Level Security) 기반의 RBAC.

---

## 2. 절대 준수 스타일 및 UI 지침 (Antigravity 전용 규칙)

에이전트는 다음 UI 표준을 임의로 변경할 수 없으며, 모든 신규 화면에 적용해야 합니다.

### 📐 [A] 정보 밀도 (Compact UI) 원칙
실무 ERP 사용성을 위해 여백을 최소화합니다. (`src/styles/globals.css` 참조)
- **카드 패딩**: 16px (상하) 20px (좌우)
- **폼 그룹 간격**: 12px
- **입력창 높이**: 32px (font-size 13px)
- **테이블 셀 패딩**: 6px 12px

### 📦 [B] 제품 표시 (3-line Display) 규칙
모든 제품 선택 및 조회 화면은 반드시 다음 3줄 형식을 유지해야 합니다. (`src/components/ProductDisplay.tsx` 참조)
1. **1열**: [제품코드] 제품명 (Bold)
2. **2열**: 제품 유형 (Raw material, Finished goods 등)
3. **3열**: 규격(Spec) / 포장단위(Package)

---

## 3. 핵심 기술 로직 및 데이터 바인딩

### 🔒 [A] RLS 및 편집 권한 (`canEdit`)
- 모든 트랜잭션 수동 수정은 `status = 'draft'` 상태에서만 허용됩니다.
- `canEdit` 체크 시, 신규 전표(`!editId`)는 항상 작성을 허용하며, 기존 전표는 작성자 본인 또는 관리자/팀장만 수정 가능합니다.
- `profiles` 테이블 RLS는 무한 재귀 방지를 위해 단순화된 상태입니다.

### 🔗 [B] 제품 선택 및 바인딩 (ID-Based)
- **입력 UI**: `ProductSelector` 컴포넌트 사용.
- **바인딩 기준**: 반드시 `product_id` (Number)를 기준으로 매칭해야 데이터 소실이 없습니다.
- **로딩 순서**: 마스터 데이터(`fetchMasters`)를 완전히 완료한 후 전표 데이터(`fetchExistingData`)를 세팅하여 로딩 시 품명 누락을 방지합니다.

---

## 4. 최근 이슈 및 해결 로그 (2026-04-18 ~ 19)

| 일자 | 이슈 제목 | 해결 내용 | 파일 |
| :--- | :--- | :--- | :--- |
| 04.18 | RLS 무한 루프 | profiles 정책을 authenticated 역할 기반으로 단순화하여 시스템 봉쇄 해제 | schema_update_*.sql |
| 04.19 | sales_no 중복 오류 | insert 시 빈 문자열 대신 undefined를 넘겨 DB 트리거가 번호를 자동 생성하게 수정 | sales/page.tsx |
| 04.19 | 제품명 표시 누락 | 비동기 로딩 순서 조정 및 바인딩 기준을 product_code에서 product_id로 변경 | Component & Pages |
| 04.19 | UI 레이아웃 붕괴 | ProductSelector 내부에 Display를 넣지 않고, 셀 내부에 위아래로 분리 배치하여 안정화 | ProductSelector.tsx |
| 04.19 | ReferenceError | ProductDisplay 임포트 누락 일괄 수정 (Sales, Purchase, Production) | Pages |

---

## 6. SQL 및 데이터베이스 상황 (SQL Situation)
- **마이그레이션 관리**: 프로젝트 루트의 `schema_update_phaseX_*.sql` 파일들로 관리됨.
- **주요 파일**:
  - `ALL_MISSING_PHASE5_TO_8_MIGRATION.sql`: Phase 5부터 8까지의 통합 마이그레이션 스크립트.
  - `EXEC_PHASE_8.sql`: 여신 및 하드 블로킹 핵심 로직 실행 스크립트.
- **DB 정합성**: 로컬 구현 스키마와 Supabase Cloud 운영기 간의 동기화가 완료된 상태이며, 최근 RLS 정책 수정 내역이 상시 반영되고 있음.

---

## 7. GitHub 현황 및 소스 관리 (GitHub Status)
- **저장소 주소**: `https://github.com/egokiller01-lab/plachem-erp.git`
- **현재 브랜치**: `main`
- **동기화 상태**: 최신 작업 내역(Phase 8 및 코드 개편)이 반영되어 있으며, 정기적으로 커밋 및 푸시 중.
- **커밋 전략**: 기능별(Phase 단위) 또는 버그 수정 단위로 명확히 기록하여 히스토리 추적성 확보.

---

## 8. 현재 남은 과제 및 내일의 작업 (Next Steps)
1.  **전표 확정(Confirm) 프로세스 최종 검증**: 개편된 UI 구조와 Phase 8(여신 통제) 로직이 충돌 없이 작동하는지 최종 점검.
2.  **재고 트랜잭션 대조**: 전표 확정 후 `inventory_transactions` 테이블에 규격/포장 정보가 누락 없이 기록되는지 검증.
3.  **마스터 관리 화면 컴팩트화**: 고객사, 협력사, 제품 리스트 화면에도 `globals.css` 스타일이 깨지지 않고 잘 적용되었는지 순회 점검.
4.  **GitHub 최종 동기화**: 오늘 작업 시스템 전체(UI 개편 등)를 `main` 브랜치에 최종 푸시.

---
**에이전트 필독**: 작업 시작 전 `src/styles/globals.css`와 `LOGS/` 내의 최신 리포트를 반드시 먼저 읽으십시오.
