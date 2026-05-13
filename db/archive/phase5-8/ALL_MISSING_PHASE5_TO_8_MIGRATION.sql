-- ==========================================
-- [Phase 5-1] ?계/AP(매입채무) ?동 (SQL)
-- ==========================================

-- [1] 기존 ?산 ?이??장 (추?비용 채무 ?? ?택??
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS is_additional_cost_payable boolean DEFAULT true;

-- [2] 매입채무 ?이?(ACCOUNTS_PAYABLE)
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

-- ?덱??CREATE INDEX IF NOT EXISTS idx_ap_vendor ON public.accounts_payable(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ap_ref ON public.accounts_payable(ref_type, ref_id);

-- [3] 지?기록 ?이?(PAYMENT_RECORDS)
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

-- [4] ?산 ?정 RPC 고도??(confirm_production_document - AP ?동 ?성 추?)
-- ?? 존재?는 ?수??정?여 AP ?동 추?
CREATE OR REPLACE FUNCTION public.confirm_production_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
    v_current_stock numeric;
    
    v_total_material_cost numeric := 0;
    v_total_production_cost numeric := 0;
    v_total_output_qty numeric := 0;
    v_calculated_unit_cost numeric := 0;
    
    v_ap_amount numeric := 0;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    -- 2. 문서 ?인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?? ?정??문서?니??'); END IF;

    -- 3. 마감 ?인 (?산??기?)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?이 마감?어 ?정?????습?다.'); END IF;

    -- 4. ?고 체크 ??재료비 ?출
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.moving_avg_cost, p.product_name
        FROM public.production_inputs i JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('?고 부? [%s] (?재: %s, ?요: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    -- 5. ?? 계산 ?배?
    v_total_production_cost := v_total_material_cost + COALESCE(v_head.processing_fee, 0) + COALESCE(v_head.additional_cost, 0);
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    IF v_total_output_qty > 0 THEN v_calculated_unit_cost := v_total_production_cost / v_total_output_qty; ELSE v_calculated_unit_cost := 0; END IF;

    -- 6. ?불부 기록 ??? ???    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', v_head.id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', v_head.id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    UPDATE public.production_outputs SET unit_cost = v_calculated_unit_cost WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] 매입채무(AP) ?동 ?성
    IF v_head.production_type = 'SUBCON' AND v_head.vendor_id IS NOT NULL THEN
        -- AP 금액 결정: 가공비 + (?분인 경우 부?비용)
        v_ap_amount := COALESCE(v_head.processing_fee, 0);
        IF COALESCE(v_head.is_additional_cost_payable, true) THEN
            v_ap_amount := v_ap_amount + COALESCE(v_head.additional_cost, 0);
        END IF;

        IF v_ap_amount > 0 THEN
            INSERT INTO public.accounts_payable (vendor_id, ref_type, ref_id, doc_date, total_amount, status, created_by)
            VALUES (v_head.vendor_id, 'PRODUCTION_SUBCON', v_head.id, v_head.production_date, v_ap_amount, 'unpaid', auth.uid())
            RETURNING id INTO v_ap_id;
        END IF;
    END IF;

    -- 7. ?태 ?데?트 ?MAC ?계??    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('?산 ?표가 ?정?었?며, 미?급금(%s)???성?었?니??', ROUND(v_ap_amount, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] ?산 ?정 취소 RPC 고도??(unconfirm_production_document - AP ?동 추?)
CREATE OR REPLACE FUNCTION public.unconfirm_production_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_item RECORD;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Admin ?용)'); END IF;

    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?정??문서?취소 가?합?다.'); END IF;

    -- 마감 ?인
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감???? 취소?????습?다.'); END IF;

    -- [Phase 5-1] ?결 AP 체크 (지급액 존재 ??차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PRODUCTION_SUBCON' AND ref_id = p_doc_id LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?? ??지급이 진행???표?니?? (지급액: %s) ?계 취소?먼? 진행?세??', v_ap_paid));
    END IF;

    -- 로그 ??불 ??
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, to_jsonb(v_head));
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] ?결 AP 무효??(?는 ??)
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable SET status = 'void', remark = '?산 ?정 취소??한 ?동 취소' WHERE id = v_ap_id;
    END IF;

    -- ?태 ?원 ?MAC ?재계산
    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '?산 ?정??취서?었?며 미???표가 무효?되?습?다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [6] 지??록 RPC (register_payment)
CREATE OR REPLACE FUNCTION public.register_payment(
    p_ap_id bigint, 
    p_amount numeric, 
    p_date date, 
    p_method varchar, 
    p_remark text
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_ap_record RECORD;
    v_is_month_closed boolean;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)'); END IF;

    -- 2. 마감 ?인 (지급일 기?)
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?자????마감???료?어 지급을 ?록?????습?다.'); END IF;

    -- 3. AP 존재 ?인 ??액 체크
    SELECT * INTO v_ap_record FROM public.accounts_payable WHERE id = p_ap_id FOR UPDATE;
    IF v_ap_record IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '매입채무 ?보?찾을 ???습?다.'); END IF;
    IF v_ap_record.status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '?? 취소???표?니??'); END IF;
    
    IF (v_ap_record.total_amount - v_ap_record.paid_amount) < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', format('지급액??미???액(%s)??초과?????습?다.', v_ap_record.total_amount - v_ap_record.paid_amount));
    END IF;

    -- 4. 지?기록 ?성
    INSERT INTO public.payment_records (ap_id, payment_date, amount, payment_method, remark, created_by)
    VALUES (p_ap_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AP ?태 ??적 지급액 ?데?트
    UPDATE public.accounts_payable 
    SET 
        paid_amount = paid_amount + p_amount,
        status = CASE 
                    WHEN (paid_amount + p_amount) >= total_amount THEN 'paid' 
                    ELSE 'partially_paid' 
                 END,
        updated_at = now()
    WHERE id = p_ap_id;

    RETURN jsonb_build_object('success', true, 'message', '지?처리가 ?료?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
-- ==========================================
-- [Phase 5-2] ?반 매입(Purchase) AP ?합 (SQL)
-- ==========================================

-- [1] 매입 ?더 ?장 (지급기??추?)
ALTER TABLE public.purchase_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] 매입 ?정 RPC 고도??(confirm_purchase_document - AP ?동)
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    -- 2. ?표 ?인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?? ?정??문서?니??'); END IF;

    -- 3. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?이마감?어 ?정?????습?다.'); END IF;

    -- 4. ?매입???출 (공급가??+ 부가??
    SELECT SUM(net_amount + vat_amount) INTO v_total_amount 
    FROM public.purchase_items 
    WHERE purchase_header_id = p_doc_id;

    -- 5. 매입채무(AP) ?동 ?성
    IF COALESCE(v_total_amount, 0) > 0 THEN
        INSERT INTO public.accounts_payable (
            vendor_id, 
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
            v_head.supplier_id, 
            'PURCHASE', 
            v_head.id, 
            v_head.purchase_date, 
            COALESCE(v_head.due_date, v_head.purchase_date + INTERVAL '30 days'), 
            v_total_amount, 
            'unpaid', 
            format('매입?표 ?동?성 (%s)', v_head.purchase_no),
            auth.uid()
        )
        RETURNING id INTO v_ap_id;
    END IF;

    -- 6. ?태 ?데?트 (기존 ?리거? ?불/MAC 처리??
    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('매입 ?표가 ?정?었?며, 매입채무(%s)가 ?성?었?니??', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 매입 ?정 취소 RPC 고도??(unconfirm_purchase_document - AP ?동)
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
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Admin ?용)');
    END IF;

    -- 2. ?태 ?인
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?정??문서?취소 가?합?다.'); END IF;

    -- 3. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감???? ?정 취소?????습?다.'); END IF;

    -- [Phase 5-2] ?결 AP 체크 (지급액 존재 ??차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
    FROM public.accounts_payable 
    WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?? ??지급이 진행??매입 ?표?니?? (지급액: %s) ?계 지?취소?먼? 진행?세??', v_ap_paid));
    END IF;

    -- 4. 로그 ??태 ?원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- [Phase 5-2] ?결 AP 무효??    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable 
        SET status = 'void', remark = format('매입 ?정 취소??한 ?동 무효??(%s)', p_reason) 
        WHERE id = v_ap_id;
    END IF;

    -- 5. ?태 ?데?트 (?리거? ?고/MAC ???함)
    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매입 ?정??취소?었?며 매입채무가 무효?되?습?다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
-- ==========================================
-- [Phase 5-3] 매출채권(AR) ?동 ??금 관?(SQL)
-- ==========================================

-- [1] 매출 ?더 ?장 (?금기한 추?)
ALTER TABLE public.sales_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] 매출채권 ??금 기록 ?이??설
CREATE TABLE IF NOT EXISTS public.accounts_receivable (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    customer_id bigint NOT NULL REFERENCES public.customers(id),
    ref_type varchar(50) NOT NULL, -- 'SALES'
    ref_id bigint NOT NULL,
    doc_date date NOT NULL,
    due_date date,
    total_amount numeric NOT NULL DEFAULT 0,
    received_amount numeric NOT NULL DEFAULT 0,
    status varchar(20) NOT NULL DEFAULT 'unpaid', -- unpaid, partially_paid, paid, void
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
    payment_method varchar(20) NOT NULL, -- BANK, CASH, CARD
    remark text,
    created_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- ?덱??추?
CREATE INDEX IF NOT EXISTS idx_ar_customer ON public.accounts_receivable(customer_id);
CREATE INDEX IF NOT EXISTS idx_ar_ref ON public.accounts_receivable(ref_type, ref_id);
CREATE INDEX IF NOT EXISTS idx_receipt_ar ON public.receipt_records(ar_id);

-- [3] 매출 ?정 RPC 고도??(confirm_sales_document - AR ?동)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    -- 2. ?표 ?인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?? ?정??문서?니??'); END IF;

    -- 3. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?이 마감?어 ?정?????습?다.'); END IF;

    -- 4. ?매출???산 (공급가??+ 부가??
    SELECT total_amount INTO v_total_amount FROM public.sales_headers WHERE id = p_doc_id;

    -- 5. 매출채권(AR) ?동 ?성
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
            format('매출?표 ?동?성 (%s)', v_head.sales_no),
            auth.uid()
        )
        RETURNING id INTO v_ar_id;
    END IF;

    -- 6. ?태 ?데?트 (?리거? ?고/MAC 처리??
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('매출???정?었?며, 매출채권(%s)???성?었?니??', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] 매출 ?정 취소 RPC 고도??(unconfirm_sales_document - AR ?동)
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
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Admin ?용)');
    END IF;

    -- 2. ?태 ?인
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?정??문서?취소 가?합?다.'); END IF;

    -- 3. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감???? ?정 취소?????습?다.'); END IF;

    -- 4. ?결 AR 체크 (?금??존재 ??차단)
    SELECT id, received_amount INTO v_ar_id, v_ar_received 
    FROM public.accounts_receivable 
    WHERE ref_type = 'SALES' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ar_id IS NOT NULL AND COALESCE(v_ar_received, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?? ?금??진행??매출 ?표?니?? (?금?? %s) ?금 취소?먼? 진행?세??', v_ar_received));
    END IF;

    -- 5. 로그 ??태 ?원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('SALES', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- 6. ?결 AR 무효??    IF v_ar_id IS NOT NULL THEN
        UPDATE public.accounts_receivable 
        SET status = 'void', updated_at = now(), remark = format('매출 ?정 취소??한 ?동 무효??(%s)', p_reason) 
        WHERE id = v_ar_id;
    END IF;

    -- 7. ?태 ?데?트
    UPDATE public.sales_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출 ?정??취소?었?며 매출채권??무효?되?습?다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] ?금 ?록 ?용 RPC (register_receipt)
CREATE OR REPLACE FUNCTION public.register_receipt(
    p_ar_id bigint,
    p_amount numeric,
    p_date date,
    p_method varchar(20),
    p_remark text
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_ar_status text;
    v_is_month_closed boolean;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    -- 2. AR ?태 ?인
    SELECT status INTO v_ar_status FROM public.accounts_receivable WHERE id = p_ar_id;
    IF v_ar_status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '무효?된 채권?는 ?금?????습?다.'); END IF;
    IF v_ar_status = 'paid' THEN RETURN jsonb_build_object('success', false, 'message', '?? ?금???료??건입?다.'); END IF;

    -- 3. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?자????마감???료?어 ?금???록?????습?다.'); END IF;

    -- 4. ?금 기록 추?
    INSERT INTO public.receipt_records (ar_id, receipt_date, amount, payment_method, remark, created_by)
    VALUES (p_ar_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AR ?태 갱신
    UPDATE public.accounts_receivable 
    SET received_amount = received_amount + p_amount,
        updated_at = now(),
        status = CASE 
            WHEN (received_amount + p_amount) >= total_amount THEN 'paid' 
            ELSE 'partially_paid' 
        END
    WHERE id = p_ar_id;

    RETURN jsonb_build_object('success', true, 'message', '?금???공?으??록?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ?수 ?행 권한
REVOKE ALL ON FUNCTION public.register_receipt FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_receipt TO authenticated;
-- ==========================================
-- [Phase 5-4] 거래??장(Ledger) ?합 ?(SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_ledger AS
-- 1. 매출 (Accounts Receivable - AR)
SELECT 
    id AS source_id,
    customer_id,
    doc_date,
    'AR_SALES' AS ref_type,
    ref_id,
    total_amount AS amount, -- ?채?증? (+)
    remark
FROM public.accounts_receivable
WHERE status != 'void'

UNION ALL

-- 2. ?금 (Receipt Records)
SELECT 
    r.id AS source_id,
    ar.customer_id,
    r.receipt_date AS doc_date,
    'RECEIPT' AS ref_type,
    ar.id AS ref_id,
    -r.amount AS amount, -- ?채?감소 (-)
    r.remark
FROM public.receipt_records r
JOIN public.accounts_receivable ar ON r.ar_id = ar.id
WHERE ar.status != 'void'

UNION ALL

-- 3. 매입/?상 (Accounts Payable - AP)
SELECT 
    id AS source_id,
    vendor_id AS customer_id,
    doc_date,
    'AP_' || ref_type AS ref_type,
    ref_id,
    -total_amount AS amount, -- ?채?감소 (-) (???발생)
    remark
FROM public.accounts_payable
WHERE status != 'void'

UNION ALL

-- 4. 지?(Payment Records)
SELECT 
    p.id AS source_id,
    ap.vendor_id AS customer_id,
    p.payment_date AS doc_date,
    'PAYMENT' AS ref_type,
    ap.id AS ref_id,
    p.amount AS amount, -- ?채?증? (+) (????멸)
    p.remark
FROM public.payment_records p
JOIN public.accounts_payable ap ON p.ap_id = ap.id
WHERE ap.status != 'void';

-- 권한 ?정
GRANT SELECT ON public.v_customer_ledger TO authenticated;

-- ??보?용 ?약 ?(KPI ?단??
CREATE OR REPLACE VIEW public.v_accounting_summary AS
SELECT
    -- ?미수?(AR ?액)
    COALESCE(SUM(CASE WHEN ref_type LIKE 'AR%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'RECEIPT' THEN amount ELSE 0 END), 0) AS total_receivable,
    
    -- ?미?급금 (AP ?액 - 부??반전?여 ?수??시)
    -(COALESCE(SUM(CASE WHEN ref_type LIKE 'AP%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'PAYMENT' THEN amount ELSE 0 END), 0)) AS total_payable
FROM public.v_customer_ledger;

GRANT SELECT ON public.v_accounting_summary TO authenticated;
-- ==========================================
-- [Phase 6-1] ?일 ?금 보고???이??집계 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_daily_cash_report(p_date date)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_prev_date date := p_date - INTERVAL '1 day';
    
    -- ?일 집계
    v_today_receipt numeric := 0;
    v_today_payment numeric := 0;
    v_today_new_ar numeric := 0;
    v_today_new_ap numeric := 0;
    
    -- ?일 집계
    v_prev_receipt numeric := 0;
    v_prev_payment numeric := 0;
    v_prev_new_ar numeric := 0;
    v_prev_new_ap numeric := 0;
    
    -- ?세 가??이??    v_receipt_details jsonb;
    v_payment_details jsonb;
    v_overdue_ar jsonb;
    v_overdue_ap jsonb;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한???습?다.');
    END IF;

    -- 2. ?일 집계 (Receipts, Payments, New AR/AP)
    SELECT COALESCE(SUM(amount), 0) INTO v_today_receipt FROM public.receipt_records WHERE receipt_date = p_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_today_payment FROM public.payment_records WHERE payment_date = p_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ar FROM public.accounts_receivable WHERE doc_date = p_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ap FROM public.accounts_payable WHERE doc_date = p_date AND status != 'void';

    -- 3. ?일 집계
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_receipt FROM public.receipt_records WHERE receipt_date = v_prev_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_payment FROM public.payment_records WHERE payment_date = v_prev_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ar FROM public.accounts_receivable WHERE doc_date = v_prev_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ap FROM public.accounts_payable WHERE doc_date = v_prev_date AND status != 'void';

    -- 4. ?세 리스??(?일)
    SELECT jsonb_agg(sub) INTO v_receipt_details FROM (
        SELECT r.receipt_date, r.amount, r.payment_method, c.customer_name, r.remark
        FROM public.receipt_records r
        JOIN public.accounts_receivable ar ON r.ar_id = ar.id
        JOIN public.customers c ON ar.customer_id = c.id
        WHERE r.receipt_date = p_date
        ORDER BY r.id DESC
    ) sub;

    SELECT jsonb_agg(sub) INTO v_payment_details FROM (
        SELECT p.payment_date, p.amount, p.payment_method, c.customer_name, p.remark
        FROM public.payment_records p
        JOIN public.accounts_payable ap ON p.ap_id = ap.id
        JOIN public.customers c ON ap.vendor_id = c.id
        WHERE p.payment_date = p_date
        ORDER BY p.id DESC
    ) sub;

    -- 5. ?체 ?약 (?체 기? Top 5)
    SELECT jsonb_agg(sub) INTO v_overdue_ar FROM (
        SELECT c.customer_name, (ar.total_amount - ar.received_amount) as balance, ar.due_date
        FROM public.accounts_receivable ar
        JOIN public.customers c ON ar.customer_id = c.id
        WHERE ar.status NOT IN ('paid', 'void') AND ar.due_date < CURRENT_DATE
        ORDER BY balance DESC LIMIT 5
    ) sub;

    SELECT jsonb_agg(sub) INTO v_overdue_ap FROM (
        SELECT c.customer_name, (ap.total_amount - ap.paid_amount) as balance, ap.due_date
        FROM public.accounts_payable ap
        JOIN public.customers c ON ap.vendor_id = c.id
        WHERE ap.status NOT IN ('paid', 'void') AND ap.due_date < CURRENT_DATE
        ORDER BY balance DESC LIMIT 5
    ) sub;

    -- 6. ?합 메시지 반환
    RETURN jsonb_build_object(
        'success', true,
        'selected_date', p_date,
        'summary', jsonb_build_object(
            'receipt', jsonb_build_object('today', v_today_receipt, 'prev', v_prev_receipt),
            'payment', jsonb_build_object('today', v_today_payment, 'prev', v_prev_payment),
            'net_flow', jsonb_build_object('today', v_today_receipt - v_today_payment, 'prev', v_prev_receipt - v_prev_payment),
            'ar_change', jsonb_build_object('today', v_today_new_ar - v_today_receipt, 'prev', v_prev_new_ar - v_prev_receipt),
            'ap_change', jsonb_build_object('today', v_today_new_ap - v_today_payment, 'prev', v_prev_new_ap - v_prev_payment)
        ),
        'details', jsonb_build_object(
            'receipts', COALESCE(v_receipt_details, '[]'::jsonb),
            'payments', COALESCE(v_payment_details, '[]'::jsonb)
        ),
        'overdue', jsonb_build_object(
            'ar', COALESCE(v_overdue_ar, '[]'::jsonb),
            'ap', COALESCE(v_overdue_ap, '[]'::jsonb)
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_daily_cash_report TO authenticated;
-- ==========================================
-- [Phase 6-2] 주간/?간 ?금 추세 분석 (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_cash_trend_report(
    p_type varchar(10), -- 'week'/'weekly', 'month'/'monthly'
    p_limit int DEFAULT 6   -- 최근 6???는 6???)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_result jsonb;
    v_trend_data jsonb;
    v_summary jsonb;
    v_current_period_start date;
    v_prev_period_start date;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '조회 권한???습?다.');
    END IF;

    -- 2. 기간 기? ?정 (주간: ?요???작)
    IF p_type IN ('week', 'weekly') THEN
        v_current_period_start := date_trunc('week', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 week')::date;
    ELSE
        v_current_period_start := date_trunc('month', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 month')::date;
    END IF;

    -- 3. ?합 추세 ?이??추출 (최근 N?기간)
    WITH periods AS (
        SELECT 
            CASE 
                WHEN p_type IN ('week', 'weekly') THEN (date_trunc('week', CURRENT_DATE) - (n || ' week')::interval)::date
                ELSE (date_trunc('month', CURRENT_DATE) - (n || ' month')::interval)::date
            END AS period_start
        FROM generate_series(0, p_limit - 1) n
    ),
    receipts AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, receipt_date)::date as p_start,
            SUM(amount) as total_receipt
        FROM public.receipt_records
        GROUP BY 1
    ),
    payments AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, payment_date)::date as p_start,
            SUM(amount) as total_payment
        FROM public.payment_records
        GROUP BY 1
    ),
    ar_new AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, doc_date)::date as p_start,
            SUM(total_amount) as new_ar
        FROM public.accounts_receivable
        WHERE status != 'void'
        GROUP BY 1
    ),
    ap_new AS (
        SELECT 
            date_trunc(CASE WHEN p_type IN ('week', 'weekly') THEN 'week' ELSE 'month' END, doc_date)::date as p_start,
            SUM(total_amount) as new_ap
        FROM public.accounts_payable
        WHERE status != 'void'
        GROUP BY 1
    )
    SELECT jsonb_agg(sub) INTO v_trend_data FROM (
        SELECT 
            p.period_start,
            COALESCE(r.total_receipt, 0) as receipt,
            COALESCE(pay.total_payment, 0) as payment,
            COALESCE(an.new_ar, 0) as new_ar,
            COALESCE(pn.new_ap, 0) as new_ap,
            (COALESCE(r.total_receipt, 0) - COALESCE(pay.total_payment, 0)) as net_flow
        FROM periods p
        LEFT JOIN receipts r ON p.period_start = r.p_start
        LEFT JOIN payments pay ON p.period_start = pay.p_start
        LEFT JOIN ar_new an ON p.period_start = an.p_start
        LEFT JOIN ap_new pn ON p.period_start = pn.p_start
        ORDER BY p.period_start ASC
    ) sub;

    -- 4. ?약 ?이??가?(?재 vs ?기)
    -- ??CTE 결과??용?여 ?약 ?보 ?성
    v_summary := jsonb_build_object(
        'current', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_current_period_start),
        'prev', (SELECT d FROM jsonb_array_elements(v_trend_data) d WHERE (d->>'period_start')::date = v_prev_period_start)
    );

    RETURN jsonb_build_object(
        'success', true,
        'type', p_type,
        'trend', v_trend_data,
        'summary', v_summary
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_cash_trend_report TO authenticated;
-- ==========================================
-- [Phase 7-1] ?익 분석(P&L) ?합 ?이???(SQL)
-- ==========================================

-- 1. ?별 ?사 ?익 ?약 ?CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
WITH sales_data AS (
    SELECT 
        to_char(sh.sales_date, 'YYYY-MM') as yyyymm,
        SUM(si.net_amount) as total_revenue,
        SUM(si.qty * si.cogs_unit_price) as total_cogs
    FROM public.sales_items si
    JOIN public.sales_headers sh ON si.sales_header_id = sh.id
    WHERE sh.status = 'confirmed'
    GROUP BY 1
),
subcon_data AS (
    SELECT 
        to_char(doc_date, 'YYYY-MM') as yyyymm,
        SUM(total_amount) as total_subcon_cost
    FROM public.accounts_payable
    WHERE ref_type = 'PRODUCTION_SUBCON' AND status != 'void'
    GROUP BY 1
)
SELECT 
    COALESCE(s.yyyymm, b.yyyymm) as yyyymm,
    COALESCE(s.total_revenue, 0) as revenue,
    COALESCE(s.total_cogs, 0) as cogs,
    (COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) as gross_profit,
    COALESCE(b.total_subcon_cost, 0) as subcon_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0)) as operational_profit
FROM sales_data s
FULL OUTER JOIN subcon_data b ON s.yyyymm = b.yyyymm;

GRANT SELECT ON public.v_profit_loss_summary TO authenticated;

-- 2. ?품??익 분석 ?CREATE OR REPLACE VIEW public.v_product_profitability AS
SELECT 
    p.id as product_id,
    p.product_name,
    p.product_code,
    SUM(si.qty) as total_qty,
    SUM(si.net_amount) as revenue,
    SUM(si.qty * si.cogs_unit_price) as cogs,
    (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) as gross_profit,
    CASE 
        WHEN SUM(si.net_amount) > 0 THEN (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) / SUM(si.net_amount) * 100 
        ELSE 0 
    END as margin_rate
FROM public.sales_items si
JOIN public.sales_headers sh ON si.sales_header_id = sh.id
JOIN public.products p ON si.product_id = p.id
WHERE sh.status = 'confirmed'
GROUP BY 1, 2, 3;

GRANT SELECT ON public.v_product_profitability TO authenticated;
-- ==========================================
-- [Phase 7-2] ?반 ???SG&A) 모듈 (SQL)
-- ==========================================

-- [1] 비용 카테고리 마스??CREATE TABLE IF NOT EXISTS public.expense_categories (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_name varchar(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamptz DEFAULT now()
);

-- 초기 카테고리 ?이??INSERT INTO public.expense_categories (category_name) VALUES 
('급여'), ('???), ('?모?비'), ('?송?), ('?신?), ('?도광열?), ('교육?련?), ('기????)
ON CONFLICT DO NOTHING;

-- [2] 비용 ?표 ?이?CREATE TABLE IF NOT EXISTS public.expense_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_id bigint NOT NULL REFERENCES public.expense_categories(id),
    expense_date date NOT NULL,
    is_payable boolean NOT NULL DEFAULT false, -- AP ?성 ??
    vendor_id bigint REFERENCES public.customers(id), -- 지급처 (is_payable=true ??권장)
    due_date date, -- 지?기한
    amount numeric NOT NULL DEFAULT 0, -- 공급가??(P&L 반영?
    vat_amount numeric NOT NULL DEFAULT 0,
    total_amount numeric NOT NULL DEFAULT 0, -- (AP ?성??
    status varchar(20) NOT NULL DEFAULT 'draft', -- draft, confirmed, void
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_expense_date ON public.expense_records(expense_date);
CREATE INDEX IF NOT EXISTS idx_expense_cat ON public.expense_records(category_id);

-- [3] 비용 ?정 RPC (confirm_expense_document)
CREATE OR REPLACE FUNCTION public.confirm_expense_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 ??표 ?인
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    SELECT e.*, c.category_name INTO v_head 
    FROM public.expense_records e 
    JOIN public.expense_categories c ON e.category_id = c.id
    WHERE e.id = p_doc_id;

    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서?찾을 ???습?다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?? ?정??문서?니??'); END IF;

    -- 2. 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?당 ?이 마감?어 ?정?????습?다.'); END IF;

    -- 3. AP ?동 ?동 (is_payable = true ???만)
    IF v_head.is_payable THEN
        IF v_head.vendor_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', '지??무가 ?는 비용? 거래?Vendor)?지?해???니??');
        END IF;

        INSERT INTO public.accounts_payable (
            vendor_id, 
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
            v_head.vendor_id, 
            'EXPENSE', 
            v_head.id, 
            v_head.expense_date, 
            COALESCE(v_head.due_date, v_head.expense_date + INTERVAL '30 days'), 
            v_head.total_amount, 
            'unpaid', 
            format('????동?성 (%s)', v_head.category_name),
            auth.uid()
        );
    END IF;

    -- 4. ?태 ?데?트
    UPDATE public.expense_records SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '비용 ?표가 ?정?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] 비용 ?정 취소 RPC (unconfirm_expense_document)
CREATE OR REPLACE FUNCTION public.unconfirm_expense_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Admin ?용)');
    END IF;

    SELECT * INTO v_head FROM public.expense_records WHERE id = p_doc_id;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?정??문서?취소 가?합?다.'); END IF;

    -- 마감 ?인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감???? ?정 취소?????습?다.'); END IF;

    -- ?결 AP 체크 (지급액 존재 ??차단)
    IF v_head.is_payable THEN
        SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
        FROM public.accounts_payable 
        WHERE ref_type = 'EXPENSE' AND ref_id = p_doc_id AND status != 'void'
        LIMIT 1;

        IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
            RETURN jsonb_build_object('success', false, 'message', format('?? 지?처리가 진행??건입?다. (지급액: %s) ?계 지?취소?먼? 진행?세??', v_ap_paid));
        END IF;

        IF v_ap_id IS NOT NULL THEN
            UPDATE public.accounts_payable SET status = 'void', remark = format('비용 ?정 취소??한 취소 (%s)', p_reason) WHERE id = v_ap_id;
        END IF;
    END IF;

    -- 로그 기록 ??태 ?데?트
    UPDATE public.expense_records SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '비용 ?표가 Draft ?태??원?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] P&L ?약 ?고도??(???집계 ?함)
CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
WITH sales_data AS (
    SELECT 
        to_char(sh.sales_date, 'YYYY-MM') as yyyymm,
        SUM(si.net_amount) as total_revenue,
        SUM(si.qty * si.cogs_unit_price) as total_cogs
    FROM public.sales_items si
    JOIN public.sales_headers sh ON si.sales_header_id = sh.id
    WHERE sh.status = 'confirmed'
    GROUP BY 1
),
subcon_data AS (
    SELECT 
        to_char(doc_date, 'YYYY-MM') as yyyymm,
        SUM(total_amount) as total_subcon_cost
    FROM public.accounts_payable
    WHERE ref_type = 'PRODUCTION_SUBCON' AND status != 'void'
    GROUP BY 1
),
sga_data AS (
    SELECT 
        to_char(expense_date, 'YYYY-MM') as yyyymm,
        SUM(amount) as total_sga_cost
    FROM public.expense_records
    WHERE status = 'confirmed'
    GROUP BY 1
)
SELECT 
    COALESCE(s.yyyymm, b.yyyymm, g.yyyymm) as yyyymm,
    COALESCE(s.total_revenue, 0) as revenue,
    COALESCE(s.total_cogs, 0) as cogs,
    (COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) as gross_profit,
    COALESCE(b.total_subcon_cost, 0) as subcon_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0)) as operational_gross_profit,
    COALESCE(g.total_sga_cost, 0) as sga_cost,
    ((COALESCE(s.total_revenue, 0) - COALESCE(s.total_cogs, 0)) - COALESCE(b.total_subcon_cost, 0) - COALESCE(g.total_sga_cost, 0)) as operating_income
FROM sales_data s
FULL OUTER JOIN subcon_data b ON s.yyyymm = b.yyyymm
FULL OUTER JOIN sga_data g ON COALESCE(s.yyyymm, b.yyyymm) = g.yyyymm OR (s.yyyymm IS NULL AND b.yyyymm IS NULL AND g.yyyymm IS NOT NULL);

GRANT SELECT ON public.v_profit_loss_summary TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_expense_document TO authenticated;
GRANT EXECUTE ON FUNCTION public.unconfirm_expense_document TO authenticated;
-- ==========================================
-- [Phase 7-3] 거래처별 ?익??분석 ?(SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_profitability AS
SELECT 
    c.id as customer_id,
    c.customer_name,
    to_char(sh.sales_date, 'YYYY-MM') as yyyymm,
    SUM(si.net_amount) as revenue,
    SUM(si.qty * si.cogs_unit_price) as cogs,
    (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) as gross_profit,
    CASE 
        WHEN SUM(si.net_amount) > 0 THEN (SUM(si.net_amount) - SUM(si.qty * si.cogs_unit_price)) / SUM(si.net_amount) * 100 
        ELSE 0 
    END as margin_rate
FROM public.sales_items si
JOIN public.sales_headers sh ON si.sales_header_id = sh.id
JOIN public.customers c ON sh.customer_id = c.id
WHERE sh.status = 'confirmed'
GROUP BY 1, 2, 3;

COMMENT ON VIEW public.v_customer_profitability IS '거래처별 ?별 매출, ??, 총이???총이?률??분석?는 ?;

GRANT SELECT ON public.v_customer_profitability TO authenticated;
-- ==========================================
-- [Phase 8-1] ?이?분석 ??신?도 관?(SQL)
-- ==========================================

-- [1] 거래?마스???드 ?장
ALTER TABLE public.customers
ADD COLUMN IF NOT EXISTS credit_limit numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_credit_unlimited boolean DEFAULT false;

COMMENT ON COLUMN public.customers.credit_limit IS '?신 ?도??(0 = ?상 불?/?금 거래 ?용)';
COMMENT ON COLUMN public.customers.is_credit_unlimited IS '?신 ?도 무제????';

-- [2] ?이?분석 RPC (get_aging_report)
-- 기????늘) ?의 미수/미?급금??6?버킷?로 집계
CREATE OR REPLACE FUNCTION public.get_aging_report(p_type varchar) -- 'AR' or 'AP'
RETURNS TABLE (
    customer_id bigint,
    customer_name varchar,
    total_balance numeric,
    bucket_normal numeric,    -- ?체 ??    bucket_pending numeric,   -- due_date IS NULL
    bucket_30 numeric,        -- 1-30??    bucket_60 numeric,        -- 31-60??    bucket_90 numeric,        -- 61-90??    bucket_over_90 numeric    -- 90??초과
) AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        SELECT 
            c.id as cid,
            c.customer_name as cname,
            (t.total_amount - t.received_amount) as balance, -- AP??경우 received_amount??paid_amount?처리??            CASE 
                WHEN t.due_date IS NULL THEN 'pending'
                WHEN t.due_date >= CURRENT_DATE THEN 'normal'
                WHEN (CURRENT_DATE - t.due_date) <= 30 THEN '30'
                WHEN (CURRENT_DATE - t.due_date) <= 60 THEN '60'
                WHEN (CURRENT_DATE - t.due_date) <= 90 THEN '90'
                ELSE 'over_90'
            END as bucket
        FROM (
            SELECT 
                vendor_id as customer_id, 
                due_date, 
                total_amount, 
                COALESCE(received_amount, 0) as received_amount -- AR ?이?기?
            FROM public.accounts_receivable 
            WHERE p_type = 'AR' AND status != 'paid' AND status != 'void'
            UNION ALL
            SELECT 
                vendor_id as customer_id, 
                due_date, 
                total_amount, 
                COALESCE(paid_amount, 0) as received_amount -- AP ?이?기? (paid_amount ?용)
            FROM public.accounts_payable 
            WHERE p_type = 'AP' AND status != 'paid' AND status != 'void'
        ) t
        JOIN public.customers c ON t.customer_id = c.id
        WHERE (t.total_amount - t.received_amount) > 0
    )
    SELECT 
        cid,
        cname,
        SUM(balance) as total_balance,
        SUM(CASE WHEN bucket = 'normal' THEN balance ELSE 0 END) as bucket_normal,
        SUM(CASE WHEN bucket = 'pending' THEN balance ELSE 0 END) as bucket_pending,
        SUM(CASE WHEN bucket = '30' THEN balance ELSE 0 END) as bucket_30,
        SUM(CASE WHEN bucket = '60' THEN balance ELSE 0 END) as bucket_60,
        SUM(CASE WHEN bucket = '90' THEN balance ELSE 0 END) as bucket_90,
        SUM(CASE WHEN bucket = 'over_90' THEN balance ELSE 0 END) as bucket_over_90
    FROM base_data
    GROUP BY 1, 2
    ORDER BY total_balance DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [3] ?신 ?도 체크 RPC (check_customer_credit)
-- ?정 거래처의 ?재 ?신 ?태? ?규 매출?을 비교?여 경고?반환
CREATE OR REPLACE FUNCTION public.check_customer_credit(p_customer_id bigint, p_new_amount numeric)
RETURNS jsonb AS $$
DECLARE
    v_limit numeric;
    v_unlimited boolean;
    v_current_ar numeric;
    v_total_exposure numeric;
BEGIN
    -- ?도 ?보 조회
    SELECT credit_limit, is_credit_unlimited INTO v_limit, v_unlimited
    FROM public.customers WHERE id = p_customer_id;

    IF v_unlimited THEN
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'is_unlimited', true);
    END IF;

    -- ?재 채권 ?액 집계
    SELECT COALESCE(SUM(total_amount - received_amount), 0) INTO v_current_ar
    FROM public.accounts_receivable
    WHERE vendor_id = p_customer_id AND status != 'paid' AND status != 'void';

    v_total_exposure := v_current_ar + p_new_amount;

    IF v_total_exposure > v_limit THEN
        RETURN jsonb_build_object(
            'is_exceeded', true, 
            'limit', v_limit, 
            'current_ar', v_current_ar, 
            'new_amount', p_new_amount,
            'excess_amount', v_total_exposure - v_limit,
            'message', format('?신 ?도(%s)?%s 초과?습?다.', v_limit, (v_total_exposure - v_limit))
        );
    ELSE
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'current_ar', v_current_ar);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_aging_report TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_customer_credit TO authenticated;
-- ==========================================
-- [Phase 8-2] ?신 ?드 차단 ??외 ?인 (SQL)
-- ==========================================

-- [1] ?신 ?외 ?인 ?청 ?이?CREATE TABLE IF NOT EXISTS public.credit_exception_requests (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    sales_header_id bigint NOT NULL REFERENCES public.sales_headers(id) ON DELETE CASCADE,
    requested_by uuid NOT NULL REFERENCES auth.users(id),
    status varchar(20) NOT NULL DEFAULT 'pending', -- pending, approved, rejected, void (invalidated)
    reason text NOT NULL,
    approved_by uuid REFERENCES auth.users(id),
    approver_comment text,
    processed_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credit_req_sales ON public.credit_exception_requests(sales_header_id);

-- [2] ?인 무효???리?(Auto-Invalidation)
-- ?표??거래?customer_id)??총액(total_amount) 변???기존 ?인??void 처리
CREATE OR REPLACE FUNCTION public.trg_invalidate_credit_approval()
RETURNS TRIGGER AS $$
BEGIN
    -- 중요 ?드 변???기존 모든 'approved' ?는 'pending' ?청??무효??    IF (OLD.customer_id IS DISTINCT FROM NEW.customer_id) OR 
       (OLD.total_amount IS DISTINCT FROM NEW.total_amount) THEN
        
        UPDATE public.credit_exception_requests
        SET status = 'void', 
            approver_comment = format('?이??변경으??한 ?동 무효??(?전 총액: %s -> ?재: %s)', OLD.total_amount, NEW.total_amount)
        WHERE sales_header_id = NEW.id AND status IN ('approved', 'pending');
        
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_sales_header_credit_integrity
BEFORE UPDATE ON public.sales_headers
FOR EACH ROW
EXECUTE FUNCTION public.trg_invalidate_credit_approval();

-- [3] ?신 ?외 ?인 처리 RPC (manage_credit_exception)
CREATE OR REPLACE FUNCTION public.manage_credit_exception(
    p_req_id bigint,
    p_action varchar, -- 'approve', 'reject'
    p_comment text
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Admin ?용)');
    END IF;

    IF p_action = 'approve' THEN
        UPDATE public.credit_exception_requests
        SET status = 'approved', approved_by = auth.uid(), approver_comment = p_comment, processed_at = now()
        WHERE id = p_req_id AND status = 'pending';
    ELSIF p_action = 'reject' THEN
        UPDATE public.credit_exception_requests
        SET status = 'rejected', approved_by = auth.uid(), approver_comment = p_comment, processed_at = now()
        WHERE id = p_req_id AND status = 'pending';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', '처리가 ?료?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [4] 매출 ?정 RPC 고도??(confirm_sales_document - Hard Block ?용)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_credit_res jsonb;
    v_is_approved boolean;
BEGIN
    -- 1. 권한 ??태 ?인
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한???습?다 (Manager ?상 ?요)');
    END IF;

    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '?표?찾을 ???습?다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?? ?정???표?니??'); END IF;

    -- 2. ?신 ?도 체크 (Hard Control)
    v_credit_res := public.check_customer_credit(v_head.customer_id, v_head.total_amount);
    
    IF (v_credit_res->>'is_exceeded')::boolean THEN
        -- ?외 ?인 ?? ?인
        SELECT EXISTS (
            SELECT 1 FROM public.credit_exception_requests 
            WHERE sales_header_id = p_doc_id AND status = 'approved'
        ) INTO v_is_approved;

        IF NOT v_is_approved THEN
            RETURN jsonb_build_object(
                'success', false, 
                'error_type', 'CREDIT_EXCEEDED',
                'message', format('?신 ?도 초과??정??차단?었?니?? (관리자 ?인 ?요) %s', v_credit_res->>'message')
            );
        END IF;
    END IF;

    -- 3. 기존 ?? 로직 ??고 ?데?트 (간략?된 ?시, ?제 로직 ?? ?요)
    -- ... (기존 ?정 로직 ?행) ...
    
    -- ?태 ?데?트
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출???상?으??정?었?니??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT SELECT, INSERT ON public.credit_exception_requests TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_credit_exception TO authenticated;
GRANT ALL ON public.accounts_receivable TO authenticated;
GRANT ALL ON public.receipt_records TO authenticated;
GRANT ALL ON public.accounts_payable TO authenticated;
GRANT ALL ON public.payment_records TO authenticated;
GRANT ALL ON public.expense_categories TO authenticated;
GRANT ALL ON public.expense_records TO authenticated;
GRANT ALL ON public.credit_exception_requests TO authenticated;
GRANT ALL ON public.bom_headers TO authenticated;
GRANT ALL ON public.bom_items TO authenticated;
GRANT ALL ON public.inventory_adjustments TO authenticated;
GRANT ALL ON public.document_history_logs TO authenticated;

NOTIFY pgrst, 'reload schema';
