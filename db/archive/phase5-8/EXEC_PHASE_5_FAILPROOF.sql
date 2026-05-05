-- ==========================================
-- [Phase 5-1] 회계/AP(매입채무) 연동 (SQL)
-- SQL PARSE BUG COMPLETELY RESOLVED BY REMOVING RECORD ALIASES
-- ==========================================

-- [1] 기존 생산 테이블 확장 (추가비용 채무 여부 선택용)
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS is_additional_cost_payable boolean DEFAULT true;

-- [2] 매입채무 테이블 (ACCOUNTS_PAYABLE)
CREATE TABLE IF NOT EXISTS public.accounts_payable (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    vendor_id bigint NOT NULL REFERENCES public.customers(id),
    ref_type varchar(50) NOT NULL, -- 'PRODUCTION_SUBCON', 'PURCHASE'
    ref_id bigint NOT NULL,
    doc_date date NOT NULL,
    due_date date,
    total_amount numeric NOT NULL DEFAULT 0,
    paid_amount numeric NOT NULL DEFAULT 0,
    status varchar(20) NOT NULL DEFAULT 'unpaid' CHECK (status IN ('unpaid', 'partially_paid', 'paid', 'void')),
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_ap_vendor ON public.accounts_payable(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ap_ref ON public.accounts_payable(ref_type, ref_id);

-- [3] 지급 기록 테이블 (PAYMENT_RECORDS)
CREATE TABLE IF NOT EXISTS public.payment_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    ap_id bigint NOT NULL REFERENCES public.accounts_payable(id) ON DELETE CASCADE,
    payment_date date NOT NULL,
    amount numeric NOT NULL CHECK (amount > 0),
    payment_method varchar(20) NOT NULL DEFAULT 'BANK' CHECK (payment_method IN ('BANK', 'CASH', 'LINK')),
    remark text,
    created_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- [4] 생산 확정 RPC 고도화 (confirm_production_document - AP 자동 생성 추가)
CREATE OR REPLACE FUNCTION public.confirm_production_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_item RECORD;
    v_current_stock numeric;
    
    v_total_material_cost numeric := 0;
    v_total_production_cost numeric := 0;
    v_total_output_qty numeric := 0;
    v_calculated_unit_cost numeric := 0;
    
    v_ap_amount numeric := 0;
    v_ap_id bigint;

    -- Scalar Variables to replace v_head
    v_status varchar;
    v_production_date date;
    v_production_type varchar;
    v_vendor_id bigint;
    v_processing_fee numeric;
    v_additional_cost numeric;
    v_is_additional_cost_payable boolean;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    SELECT status, production_date, production_type, vendor_id, processing_fee, additional_cost, is_additional_cost_payable
    INTO v_status, v_production_date, v_production_type, v_vendor_id, v_processing_fee, v_additional_cost, v_is_additional_cost_payable
    FROM public.production_headers WHERE id = p_doc_id;

    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_production_date, 'YYYY') AND closing_month = to_char(v_production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    FOR v_item IN SELECT i.product_id, i.qty, p.moving_avg_cost, p.product_name FROM public.production_inputs i JOIN public.products p ON i.product_id = p.id WHERE i.production_header_id = p_doc_id LOOP
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN RETURN jsonb_build_object('success', false, 'message', format('재고 부족: [%s]', v_item.product_name)); END IF;
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    v_total_production_cost := v_total_material_cost + COALESCE(v_processing_fee, 0) + COALESCE(v_additional_cost, 0);
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    IF v_total_output_qty > 0 THEN v_calculated_unit_cost := v_total_production_cost / v_total_output_qty; ELSE v_calculated_unit_cost := 0; END IF;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id)
    SELECT v_production_date, 'PROD_INPUT', product_id, 0, qty, 'production_headers', p_doc_id FROM public.production_inputs WHERE production_header_id = p_doc_id;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id)
    SELECT v_production_date, 'PROD_OUTPUT', product_id, qty, 0, 'production_headers', p_doc_id FROM public.production_outputs WHERE production_header_id = p_doc_id;

    UPDATE public.production_outputs SET unit_cost = v_calculated_unit_cost WHERE production_header_id = p_doc_id;

    IF v_production_type = 'SUBCON' AND v_vendor_id IS NOT NULL THEN
        v_ap_amount := COALESCE(v_processing_fee, 0);
        IF COALESCE(v_is_additional_cost_payable, true) THEN v_ap_amount := v_ap_amount + COALESCE(v_additional_cost, 0); END IF;
        IF v_ap_amount > 0 THEN
            INSERT INTO public.accounts_payable (vendor_id, ref_type, ref_id, doc_date, total_amount, status, created_by)
            VALUES (v_vendor_id, 'PRODUCTION_SUBCON', p_doc_id, v_production_date, v_ap_amount, 'unpaid', auth.uid()) RETURNING id INTO v_ap_id;
        END IF;
    END IF;

    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('생산 전표가 확정되었으며, 미지급금(%s)이 생성되었습니다.', ROUND(v_ap_amount, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 생산 확정 취소 RPC 고도화
CREATE OR REPLACE FUNCTION public.unconfirm_production_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_item RECORD;
    v_ap_id bigint;
    v_ap_paid numeric;
    
    v_status varchar;
    v_production_date date;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    SELECT status, production_date INTO v_status, v_production_date FROM public.production_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_production_date, 'YYYY') AND closing_month = to_char(v_production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 취소할 수 없습니다.'); END IF;

    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PRODUCTION_SUBCON' AND ref_id = p_doc_id LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN RETURN jsonb_build_object('success', false, 'message', format('이미 대금 지급이 진행된 전표입니다. (지급액: %s)', v_ap_paid)); END IF;

    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, (SELECT to_jsonb(t) FROM public.production_headers t WHERE id = p_doc_id));
    
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    IF v_ap_id IS NOT NULL THEN UPDATE public.accounts_payable SET status = 'void', remark = '생산 확정 취소로 인한 자동 취소' WHERE id = v_ap_id; END IF;

    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '생산 확정이 취소되었으며 미지급 전표가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [6] 지급 등록 RPC (register_payment)
CREATE OR REPLACE FUNCTION public.register_payment(p_ap_id bigint, p_amount numeric, p_date date, p_method varchar, p_remark text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_ap_status text;
    v_ap_total numeric;
    v_ap_paid numeric;
    v_is_month_closed boolean;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 일자의 월 마감이 완료되어 지급을 등록할 수 없습니다.'); END IF;

    SELECT status, total_amount, paid_amount INTO v_ap_status, v_ap_total, v_ap_paid FROM public.accounts_payable WHERE id = p_ap_id FOR UPDATE;
    IF v_ap_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '매입채무 정보를 찾을 수 없습니다.'); END IF;
    IF v_ap_status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '이미 취소된 전표입니다.'); END IF;
    IF (v_ap_total - v_ap_paid) < p_amount THEN RETURN jsonb_build_object('success', false, 'message', '지급액이 미지급 잔액을 초과할 수 없습니다.'); END IF;

    INSERT INTO public.payment_records (ap_id, payment_date, amount, payment_method, remark, created_by) VALUES (p_ap_id, p_date, p_amount, p_method, p_remark, auth.uid());
    UPDATE public.accounts_payable SET paid_amount = paid_amount + p_amount, status = CASE WHEN (paid_amount + p_amount) >= total_amount THEN 'paid' ELSE 'partially_paid' END, updated_at = now() WHERE id = p_ap_id;
    RETURN jsonb_build_object('success', true, 'message', '지급 처리가 완료되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ==========================================
-- [Phase 5-2] 일반 매입(Purchase) AP 통합 (SQL)
-- ==========================================
ALTER TABLE public.purchase_headers ADD COLUMN IF NOT EXISTS due_date date;

CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;

    v_status varchar;
    v_purchase_date date;
    v_due_date date;
    v_supplier_id bigint;
    v_purchase_no varchar;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    SELECT status, purchase_date, supplier_id, due_date, purchase_no INTO v_status, v_purchase_date, v_supplier_id, v_due_date, v_purchase_no FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_purchase_date, 'YYYY') AND closing_month = to_char(v_purchase_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    SELECT SUM(net_amount + vat_amount) INTO v_total_amount FROM public.purchase_items WHERE purchase_header_id = p_doc_id;

    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_payable (vendor_id, ref_type, ref_id, doc_date, due_date, total_amount, status, remark, created_by)
        VALUES (v_supplier_id, 'PURCHASE', p_doc_id, v_purchase_date, COALESCE(v_due_date, v_purchase_date + INTERVAL '30 days'), v_total_amount, 'unpaid', format('매입전표 자동생성 (%s)', v_purchase_no), auth.uid()) RETURNING id INTO v_ap_id;
    END IF;

    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    RETURN jsonb_build_object('success', true, 'message', format('매입 전표가 확정되었으며, 매입채무(%s)가 생성되었습니다.', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.unconfirm_purchase_document(p_doc_id bigint, p_reason text, p_user_uuid uuid)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_ap_id bigint;
    v_ap_paid numeric;
    
    v_status varchar;
    v_purchase_date date;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    SELECT status, purchase_date INTO v_status, v_purchase_date FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_purchase_date, 'YYYY') AND closing_month = to_char(v_purchase_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void' LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN RETURN jsonb_build_object('success', false, 'message', '이미 지급이 진행된 매입 전표입니다.'); END IF;

    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, (SELECT to_jsonb(t) FROM public.purchase_headers t WHERE id = p_doc_id));

    IF v_ap_id IS NOT NULL THEN UPDATE public.accounts_payable SET status = 'void', remark = format('매입 확정 취소로 인한 자동 무효화 (%s)', p_reason) WHERE id = v_ap_id; END IF;
    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    RETURN jsonb_build_object('success', true, 'message', '매입 확정이 취소되었으며 매입채무가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ==========================================
-- [Phase 5-3] 매출채권(AR) 연동 및 수금 관리 (SQL)
-- ==========================================
ALTER TABLE public.sales_headers ADD COLUMN IF NOT EXISTS due_date date;

CREATE TABLE IF NOT EXISTS public.accounts_receivable (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    customer_id bigint NOT NULL REFERENCES public.customers(id),
    ref_type varchar(50) NOT NULL,
    ref_id bigint NOT NULL,
    doc_date date NOT NULL,
    due_date date,
    total_amount numeric NOT NULL DEFAULT 0,
    received_amount numeric NOT NULL DEFAULT 0,
    status varchar(20) NOT NULL DEFAULT 'unpaid',
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.receipt_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    ar_id bigint NOT NULL REFERENCES public.accounts_receivable(id) ON DELETE CASCADE,
    receipt_date date NOT NULL,
    amount numeric NOT NULL CHECK (amount > 0),
    payment_method varchar(20) NOT NULL,
    remark text,
    created_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_ar_customer ON public.accounts_receivable(customer_id);
CREATE INDEX IF NOT EXISTS idx_ar_ref ON public.accounts_receivable(ref_type, ref_id);
CREATE INDEX IF NOT EXISTS idx_receipt_ar ON public.receipt_records(ar_id);

CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;

    v_status varchar;
    v_sales_date date;
    v_due_date date;
    v_customer_id bigint;
    v_sales_no varchar;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    SELECT status, sales_date, customer_id, due_date, sales_no INTO v_status, v_sales_date, v_customer_id, v_due_date, v_sales_no FROM public.sales_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_sales_date, 'YYYY') AND closing_month = to_char(v_sales_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    SELECT total_amount INTO v_total_amount FROM public.sales_headers WHERE id = p_doc_id;

    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_receivable (customer_id, ref_type, ref_id, doc_date, due_date, total_amount, status, remark, created_by)
        VALUES (v_customer_id, 'SALES', p_doc_id, v_sales_date, COALESCE(v_due_date, v_sales_date + INTERVAL '30 days'), v_total_amount, 'unpaid', format('매출전표 자동생성 (%s)', v_sales_no), auth.uid()) RETURNING id INTO v_ar_id;
    END IF;

    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    RETURN jsonb_build_object('success', true, 'message', format('매출이 확정되었으며, 매출채권(%s)이 생성되었습니다.', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.unconfirm_sales_document(p_doc_id bigint, p_reason text, p_user_uuid uuid)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_is_month_closed boolean;
    v_ar_id bigint;
    v_ar_received numeric;
    
    v_status varchar;
    v_sales_date date;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    SELECT status, sales_date INTO v_status, v_sales_date FROM public.sales_headers WHERE id = p_doc_id;
    IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_sales_date, 'YYYY') AND closing_month = to_char(v_sales_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    SELECT id, received_amount INTO v_ar_id, v_ar_received FROM public.accounts_receivable WHERE ref_type = 'SALES' AND ref_id = p_doc_id AND status != 'void' LIMIT 1;
    IF v_ar_id IS NOT NULL AND COALESCE(v_ar_received, 0) > 0 THEN RETURN jsonb_build_object('success', false, 'message', '이미 수금이 진행된 매출 전표입니다.'); END IF;

    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('SALES', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, (SELECT to_jsonb(t) FROM public.sales_headers t WHERE id = p_doc_id));

    IF v_ar_id IS NOT NULL THEN UPDATE public.accounts_receivable SET status = 'void', updated_at = now(), remark = format('매출 확정 취소로 인한 자동 무효화 (%s)', p_reason) WHERE id = v_ar_id; END IF;
    UPDATE public.sales_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    RETURN jsonb_build_object('success', true, 'message', '매출 확정이 취소되었으며 매출채권이 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.register_receipt(p_ar_id bigint, p_amount numeric, p_date date, p_method varchar(20), p_remark text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_ar_status text;
    v_ar_total numeric;
    v_ar_received numeric;
    v_is_month_closed boolean;
BEGIN
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    SELECT status, total_amount, received_amount INTO v_ar_status, v_ar_total, v_ar_received FROM public.accounts_receivable WHERE id = p_ar_id FOR UPDATE;
    IF v_ar_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '무효화된 채권 정보가 없습니다.'); END IF;
    IF v_ar_status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '무효화된 채권에는 수금할 수 없습니다.'); END IF;
    IF v_ar_status = 'paid' THEN RETURN jsonb_build_object('success', false, 'message', '이미 수금이 완료된 건입니다.'); END IF;

    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 일자의 월 마감이 완료되어 수금을 등록할 수 없습니다.'); END IF;

    INSERT INTO public.receipt_records (ar_id, receipt_date, amount, payment_method, remark, created_by) VALUES (p_ar_id, p_date, p_amount, p_method, p_remark, auth.uid());
    UPDATE public.accounts_receivable SET received_amount = received_amount + p_amount, updated_at = now(), status = CASE WHEN (received_amount + p_amount) >= total_amount THEN 'paid' ELSE 'partially_paid' END WHERE id = p_ar_id;
    RETURN jsonb_build_object('success', true, 'message', '수금이 성공적으로 등록되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION public.register_receipt FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_receipt TO authenticated;

-- ==========================================
-- [Phase 5-4] 거래처 원장(Ledger) 통합 뷰 (SQL)
-- ==========================================
CREATE OR REPLACE VIEW public.v_customer_ledger AS
SELECT id AS source_id, customer_id, doc_date, 'AR_SALES' AS ref_type, ref_id, total_amount AS amount, remark FROM public.accounts_receivable WHERE status != 'void'
UNION ALL
SELECT r.id AS source_id, ar.customer_id, r.receipt_date AS doc_date, 'RECEIPT' AS ref_type, ar.id AS ref_id, -r.amount AS amount, r.remark FROM public.receipt_records r JOIN public.accounts_receivable ar ON r.ar_id = ar.id WHERE ar.status != 'void'
UNION ALL
SELECT id AS source_id, vendor_id AS customer_id, doc_date, 'AP_' || ref_type AS ref_type, ref_id, -total_amount AS amount, remark FROM public.accounts_payable WHERE status != 'void'
UNION ALL
SELECT p.id AS source_id, ap.vendor_id AS customer_id, p.payment_date AS doc_date, 'PAYMENT' AS ref_type, ap.id AS ref_id, p.amount AS amount, p.remark FROM public.payment_records p JOIN public.accounts_payable ap ON p.ap_id = ap.id WHERE ap.status != 'void';

GRANT SELECT ON public.v_customer_ledger TO authenticated;

CREATE OR REPLACE VIEW public.v_accounting_summary AS
SELECT
    COALESCE(SUM(CASE WHEN ref_type LIKE 'AR%' THEN amount ELSE 0 END), 0) + COALESCE(SUM(CASE WHEN ref_type = 'RECEIPT' THEN amount ELSE 0 END), 0) AS total_receivable,
    -(COALESCE(SUM(CASE WHEN ref_type LIKE 'AP%' THEN amount ELSE 0 END), 0) + COALESCE(SUM(CASE WHEN ref_type = 'PAYMENT' THEN amount ELSE 0 END), 0)) AS total_payable
FROM public.v_customer_ledger;

GRANT SELECT ON public.v_accounting_summary TO authenticated;
