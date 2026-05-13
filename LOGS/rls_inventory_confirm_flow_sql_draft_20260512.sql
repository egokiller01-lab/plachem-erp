-- ==========================================
-- [Phase 9] 수불부(Inventory) 확정 시점 이관 및 RLS 안정화 (Draft)
-- 파일명: LOGS/rls_inventory_confirm_flow_sql_draft_20260512.sql
-- ==========================================

-- [1] 기존 아이템 레벨 레거시 트리거 제거 (403 에러의 근본 원인)
-- 이 트리거들이 Draft 상태에서도 수불부를 INSERT 하려 하여 RLS에 걸리고 있었습니다.
-- 확정된 실운영 트리거 명칭을 대상으로 DROP 합니다.
DROP TRIGGER IF EXISTS trg_sales_items_inventory_aiud ON public.sales_items;
DROP TRIGGER IF EXISTS trg_purchase_items_inventory_aiud ON public.purchase_items;

-- [2] 매출 확정 RPC 고도화 (AR + Inventory 통합)
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
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 전표 확인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 매출채권(AR) 자동 생성
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

    -- 5. 수불부(Inventory Transactions) 기록 (확정 시점에만 발생)
    -- Draft 저장 시 403 에러를 방지하기 위해 트리거 대신 RPC 내부에서 처리합니다.
    FOR v_item IN SELECT * FROM public.sales_items WHERE sales_header_id = p_doc_id LOOP
        INSERT INTO public.inventory_transactions (
            txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark
        )
        VALUES (
            v_head.sales_date, 'SALE', v_item.product_id, 0, v_item.qty, 
            'sales_items', v_item.id, format('매출확정 (%s)', v_head.sales_no)
        );
    END LOOP;

    -- 6. 상태 업데이트
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출이 확정되었으며 재고 및 매출채권이 반영되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 매입 확정 RPC 고도화 (AP + Inventory 통합 + customer_id 보정)
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;
    v_item RECORD;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 전표 확인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 매입채무(AP) 자동 생성 (v_head.supplier_id 대신 v_head.customer_id 사용)
    SELECT SUM(net_amount + vat_amount) INTO v_total_amount FROM public.purchase_items WHERE purchase_header_id = p_doc_id;
    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_payable (
            vendor_id, ref_type, ref_id, doc_date, due_date, total_amount, status, remark, created_by
        )
        VALUES (
            v_head.customer_id, 'PURCHASE', v_head.id, v_head.purchase_date, 
            COALESCE(v_head.due_date, v_head.purchase_date + INTERVAL '30 days'), 
            v_total_amount, 'unpaid', format('매입전표 자동생성 (%s)', v_head.purchase_no), auth.uid()
        )
        RETURNING id INTO v_ap_id;
    END IF;

    -- 5. 수불부(Inventory Transactions) 기록
    FOR v_item IN SELECT * FROM public.purchase_items WHERE purchase_header_id = p_doc_id LOOP
        INSERT INTO public.inventory_transactions (
            txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark
        )
        VALUES (
            v_head.purchase_date, 'PURCHASE', v_item.product_id, v_item.qty, 0, 
            'purchase_items', v_item.id, format('매입확정 (%s)', v_head.purchase_no)
        );
    END LOOP;

    -- 6. 상태 업데이트
    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매입이 확정되었으며 재고 및 매입채무가 반영되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] 매출 확정 취소 RPC (Inventory 트랜잭션 연동 삭제)
CREATE OR REPLACE FUNCTION public.unconfirm_sales_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ar_id bigint;
    v_ar_received numeric;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- 2. 상태 확인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- 4. 연결 AR 체크
    SELECT id, received_amount INTO v_ar_id, v_ar_received FROM public.accounts_receivable WHERE ref_type = 'SALES' AND ref_id = p_doc_id AND status != 'void' LIMIT 1;
    IF v_ar_id IS NOT NULL AND COALESCE(v_ar_received, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 수금이 진행된 매출 전표입니다. (수금액: %s) 수금 취소를 먼저 진행하세요.', v_ar_received));
    END IF;

    -- 5. 수불부(Inventory) 내역 삭제 (취소 시 재고 환원)
    DELETE FROM public.inventory_transactions 
    WHERE ref_table = 'sales_items' 
      AND ref_id IN (SELECT id FROM public.sales_items WHERE sales_header_id = p_doc_id);

    -- 6. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('SALES', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    IF v_ar_id IS NOT NULL THEN
        UPDATE public.accounts_receivable SET status = 'void', updated_at = now(), remark = format('매출 확정 취소로 인한 자동 무효화 (%s)', p_reason) WHERE id = v_ar_id;
    END IF;

    UPDATE public.sales_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출 확정이 취소되었으며 재고 및 매출채권이 환원되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 매입 확정 취소 RPC (Inventory 트랜잭션 연동 삭제)
CREATE OR REPLACE FUNCTION public.unconfirm_purchase_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    -- 2. 상태 확인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- 4. 연결 AP 체크
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void' LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 대급 지급이 진행된 매입 전표입니다. (지급액: %s) 지급 취소를 먼저 진행하세요.', v_ap_paid));
    END IF;

    -- 5. 수불부(Inventory) 내역 삭제 (취소 시 재고 환원)
    DELETE FROM public.inventory_transactions 
    WHERE ref_table = 'purchase_items' 
      AND ref_id IN (SELECT id FROM public.purchase_items WHERE purchase_header_id = p_doc_id);

    -- 6. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable SET status = 'void', updated_at = now(), remark = format('매입 확정 취소로 인한 자동 무효화 (%s)', p_reason) WHERE id = v_ap_id;
    END IF;

    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매입 확정이 취소되었으며 재고 및 매입채무가 환원되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
