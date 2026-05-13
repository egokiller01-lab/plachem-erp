-- Confirm flow schema patch #2 - 2026-05-13
-- Purpose:
-- 1) unconfirm_* RPCs update AR/AP.updated_at, but live AR/AP tables are missing updated_at.
-- 2) confirm_sales_document inserts inventory_transactions.txn_type='SALE', but live check constraint expects 'SALES'.

alter table public.accounts_receivable
add column if not exists updated_at timestamptz default now();

alter table public.accounts_payable
add column if not exists updated_at timestamptz default now();

CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;
    v_item RECORD;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY')
          AND closing_month = to_char(v_head.sales_date, 'MM')
          AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    v_total_amount := v_head.total_amount;
    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_receivable (
            customer_id, ref_type, ref_id, doc_date, due_date, total_amount, status, remark, created_by
        )
        VALUES (
            v_head.customer_id, 'SALES', v_head.id, v_head.sales_date,
            COALESCE(v_head.due_date, v_head.sales_date + INTERVAL '30 days'),
            v_total_amount, 'unpaid', format('매출전표 자동생성 (%s)', v_head.sales_no), auth.uid()
        )
        RETURNING id INTO v_ar_id;
    END IF;

    FOR v_item IN SELECT * FROM public.sales_items WHERE sales_header_id = p_doc_id LOOP
        INSERT INTO public.inventory_transactions (
            txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark
        )
        VALUES (
            v_head.sales_date, 'SALES', v_item.product_id, 0, v_item.qty,
            'sales_items', v_item.id, format('매출확정 (%s)', v_head.sales_no)
        );
    END LOOP;

    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출이 확정되었으며 재고 및 매출채권이 반영되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Verification
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name in ('accounts_receivable', 'accounts_payable')
  and column_name in ('created_by', 'updated_at')
order by table_name, column_name;
