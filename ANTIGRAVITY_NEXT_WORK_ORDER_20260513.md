# Antigravity Work Order - 2026-05-13

## Purpose
Verify the next ERP launch blocker after draft save stabilization: Sales/Purchase confirm and unconfirm flows.

## Current GitHub baseline
Remote `origin/main` currently includes:
- `4529fc5 fix: stabilize ERP draft entry typecheck baseline`
- `bc6f569 fix: replace BOM BigInt literals for typecheck compatibility`
- `35ad6c7 docs: add 2026-05-12 ERP stabilization log`

OpenClaw server also has local follow-up commits not pushed yet:
- `d52db58 fix: align draft entry permissions and price lookup`
- `9a45a25 docs: add ERP confirm flow verification work order`
- `d13a517 fix: stabilize sales confirm UI and optional lookups`

## Scope
Diagnosis and verification first. Do not modify SQL/RLS. Do not run additional database migrations unless Kim approves explicitly.

## Pre-check
Run:

```powershell
git status --short --branch
git pull --ff-only origin main
npm run build
npx tsc --noEmit
```

If pull/build/typecheck fails, stop and report exact output.

## Test target
Use existing test draft documents if available, or create new clearly marked test drafts:
- Sales test remark: `TEST_confirm_sales_20260513`
- Purchase test remark: `TEST_confirm_purchase_20260513`

## Verification steps

### A. Sales confirm flow
1. Open a draft sales document created for testing.
2. Click `Confirm Now` as manager/admin.
3. Record:
   - alert message
   - network RPC response for `confirm_sales_document`
   - resulting document status
   - whether `/inventory/history` shows a `SALE` transaction referencing the sales item
   - whether AR entry appears in `/accounting/ar` if total amount > 0
4. If credit limit blocks confirmation, record the exact `CREDIT_EXCEEDED` message and do not bypass unless approved.

### B. Sales unconfirm flow
Only if sales confirm succeeded and admin account is available.
1. Click `Unconfirm (Admin)`.
2. Use reason: `TEST_unconfirm_sales_20260513`.
3. Record:
   - alert message
   - RPC response for `unconfirm_sales_document`
   - document status returns to draft
   - related inventory transaction removed/neutralized
   - related AR voided if created

### C. Purchase confirm flow
1. Open a draft purchase document created for testing.
2. Click `Confirm Now` as manager/admin.
3. Record:
   - alert message
   - network RPC response for `confirm_purchase_document`
   - resulting document status
   - whether `/inventory/history` shows a `PURCHASE` transaction referencing the purchase item
   - whether AP entry appears in `/accounting/ap` if total amount > 0

### D. Purchase unconfirm flow
Only if purchase confirm succeeded and admin account is available.
1. Click `Unconfirm (Admin)`.
2. Use reason: `TEST_unconfirm_purchase_20260513`.
3. Record:
   - alert message
   - RPC response for `unconfirm_purchase_document`
   - document status returns to draft
   - related inventory transaction removed/neutralized
   - related AP voided if created

## Important observations to capture
- Any HTTP 406 from `v_customer_product_current_prices` on sales product selection.
- Any RLS 403 on `inventory_transactions`.
- Any missing function / function signature mismatch errors for RPC calls.
- Any schema-cache errors such as missing columns.

## Report format
Return only:

```text
1. git/build/typecheck result
2. Sales confirm result
3. Sales unconfirm result
4. Purchase confirm result
5. Purchase unconfirm result
6. HTTP/RPC errors observed
7. Remaining blocker, one sentence
8. Commit status: no code changed / commit hash if changed
```

## Forbidden
- Do not commit `vertex_key.json`, `.env*`, `scratch/`, `tsconfig.tsbuildinfo`, or screenshots with secrets.
- Do not execute SQL/RLS changes without explicit approval.
- Do not change unrelated modules.
