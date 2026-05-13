-- Confirm flow schema patch - 2026-05-13
-- Purpose: align AR/AP tables with confirm_sales_document / confirm_purchase_document RPC inserts.

alter table public.accounts_receivable
add column if not exists created_by uuid references auth.users(id);

alter table public.accounts_payable
add column if not exists created_by uuid references auth.users(id);

-- Verification
select column_name, data_type, udt_name
from information_schema.columns
where table_schema = 'public'
  and table_name in ('accounts_receivable', 'accounts_payable')
  and column_name = 'created_by'
order by table_name, column_name;
