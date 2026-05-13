-- Confirm sales stock guard patch - 2026-05-13
-- Purpose: prevent Sales Confirm from creating negative stock by checking aggregated required qty before AR/Inventory writes.

CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;
    v_item RECORD;
    v_stock RECORD;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 전표 확인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.');
    END IF;

    IF v_head.status = 'confirmed' THEN
        RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.');
    END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1
        FROM public.monthly_closings
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY')
          AND closing_month = to_char(v_head.sales_date, 'MM')
          AND status = 'closed'
    ) INTO v_is_month_closed;

    IF v_is_month_closed THEN
        RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.');
    END IF;

    -- 4. 현재고 부족 사전 차단
    -- 같은 전표에 동일 제품이 여러 줄 있을 수 있으므로 product_id별 필요 수량을 합산해서 확인합니다.
    FOR v_stock IN
        SELECT
            si.product_id,
            COALESCE(p.product_code, si.product_id::text) AS product_code,
            COALESCE(p.product_name, si.product_id::text) AS product_name,
            SUM(si.qty) AS required_qty,
            COALESCE(MAX(vps.stock_qty), 0) AS current_stock
        FROM public.sales_items si
        LEFT JOIN public.products p ON p.id = si.product_id
        LEFT JOIN public.v_product_stock vps ON vps.product_id = si.product_id
        WHERE si.sales_header_id = p_doc_id
        GROUP BY si.product_id, p.product_code, p.product_name
    LOOP
        IF COALESCE(v_stock.current_stock, 0) < COALESCE(v_stock.required_qty, 0) THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', format(
                    '재고 부족: [%s] %s (현재: %s, 필요: %s)',
                    v_stock.product_code,
                    v_stock.product_name,
                    COALESCE(v_stock.current_stock, 0),
                    COALESCE(v_stock.required_qty, 0)
                )
            );
        END IF;
    END LOOP;

    -- 5. 매출채권(AR) 자동 생성
    v_total_amount := v_head.total_amount;

    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_receivable (
            customer_id,
            ref_type,
            ref_id,
            doc_date,
            due_date,
            total_amount,
            status,
            remark,
            created_by
        )
        VALUES (
            v_head.customer_id,
            'SALES',
            v_head.id,
            v_head.sales_date,
            COALESCE(v_head.due_date, v_head.sales_date + INTERVAL '30 days'),
            v_total_amount,
            'unpaid',
            format('매출전표 자동생성 (%s)', v_head.sales_no),
            auth.uid()
        )
        RETURNING id INTO v_ar_id;
    END IF;

    -- 6. 수불부(Inventory Transactions) 기록
    FOR v_item IN
        SELECT * FROM public.sales_items WHERE sales_header_id = p_doc_id
    LOOP
        INSERT INTO public.inventory_transactions (
            txn_date,
            txn_type,
            product_id,
            qty_in,
            qty_out,
            ref_table,
            ref_id,
            remark
        )
        VALUES (
            v_head.sales_date,
            'SALES',
            v_item.product_id,
            0,
            v_item.qty,
            'sales_items',
            v_item.id,
            format('매출확정 (%s)', v_head.sales_no)
        );
    END LOOP;

    -- 7. 상태 업데이트
    UPDATE public.sales_headers
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출이 확정되었으며 재고 및 매출채권이 반영되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
