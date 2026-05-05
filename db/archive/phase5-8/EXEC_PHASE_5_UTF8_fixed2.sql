-- ==========================================
-- [Phase 5-1] 회계/AP(매입채무) 연동 (SQL)
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

-- 인덱스
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
-- 이미 존재하는 함수를 수정하여 AP 연동 추가
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
    v_production_date date;
BEGIN
    -- 1. 권한 체크
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. 문서 확인
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    v_production_date := (v_head).production_date;

    -- 3. 마감 확인 (생산일 기준)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_production_date, 'YYYY') AND closing_month = to_char(v_production_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 재고 체크 및 원재료비 산출
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.moving_avg_cost, p.product_name
        FROM public.production_inputs i JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('재고 부족: [%s] (현재: %s, 필요: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    -- 5. 원가 계산 및 배부
    v_total_production_cost := v_total_material_cost + COALESCE(v_head.processing_fee, 0) + COALESCE(v_head.additional_cost, 0);
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    IF v_total_output_qty > 0 THEN v_calculated_unit_cost := v_total_production_cost / v_total_output_qty; ELSE v_calculated_unit_cost := 0; END IF;

    -- 6. 수불부 기록 및 단가 저장
    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', p_doc_id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', p_doc_id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    UPDATE public.production_outputs SET unit_cost = v_calculated_unit_cost WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] 매입채무(AP) 자동 생성
    IF v_head.production_type = 'SUBCON' AND v_head.vendor_id IS NOT NULL THEN
        -- AP 금액 결정: 가공비 + (청구분인 경우 부대비용)
        v_ap_amount := COALESCE(v_head.processing_fee, 0);
        IF COALESCE(v_head.is_additional_cost_payable, true) THEN
            v_ap_amount := v_ap_amount + COALESCE(v_head.additional_cost, 0);
        END IF;

        IF v_ap_amount > 0 THEN
            INSERT INTO public.accounts_payable (vendor_id, ref_type, ref_id, doc_date, total_amount, status, created_by)
            VALUES (v_head.vendor_id, 'PRODUCTION_SUBCON', v_head.id, (v_head).production_date, v_ap_amount, 'unpaid', auth.uid())
            RETURNING id INTO v_ap_id;
        END IF;
    END IF;

    -- 7. 상태 업데이트 및 MAC 재계산
    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('생산 전표가 확정되었으며, 미지급금(%s)이 생성되었습니다.', ROUND(v_ap_amount, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 생산 확정 취소 RPC 고도화 (unconfirm_production_document - AP 연동 추가)
CREATE OR REPLACE FUNCTION public.unconfirm_production_document(p_doc_id bigint, p_reason text)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    
    v_is_month_closed boolean;
    v_item RECORD;
    v_ap_id bigint;
    v_ap_paid numeric;
BEGIN
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)'); END IF;

    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 마감 확인
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char((v_head).production_date, 'YYYY') AND closing_month = to_char((v_head).production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 취소할 수 없습니다.'); END IF;

    -- [Phase 5-1] 연결 AP 체크 (지급액 존재 시 차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PRODUCTION_SUBCON' AND ref_id = p_doc_id LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 대급 지급이 진행된 전표입니다. (지급액: %s) 회계 취소를 먼저 진행하세요.', v_ap_paid));
    END IF;

    -- 로그 및 수불 삭제
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, to_jsonb(v_head));
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] 연결 AP 무효화 (또는 삭제)
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable SET status = 'void', remark = '생산 확정 취소로 인한 자동 취소' WHERE id = v_ap_id;
    END IF;

    -- 상태 환원 및 MAC 재재계산
    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '생산 확정이 취서되었으며 미지급 전표가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [6] 지급 등록 RPC (register_payment)
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
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)'); END IF;

    -- 2. 마감 확인 (지급일 기준)
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 일자의 월 마감이 완료되어 지급을 등록할 수 없습니다.'); END IF;

    -- 3. AP 존재 확인 및 잔액 체크
    SELECT * INTO v_ap_record FROM public.accounts_payable WHERE id = p_ap_id FOR UPDATE;
    IF v_ap_record IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '매입채무 정보를 찾을 수 없습니다.'); END IF;
    IF v_ap_record.status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '이미 취소된 전표입니다.'); END IF;
    
    IF (v_ap_record.total_amount - v_ap_record.paid_amount) < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', format('지급액이 미지급 잔액(%s)을 초과할 수 없습니다.', v_ap_record.total_amount - v_ap_record.paid_amount));
    END IF;

    -- 4. 지급 기록 생성
    INSERT INTO public.payment_records (ap_id, payment_date, amount, payment_method, remark, created_by)
    VALUES (p_ap_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AP 상태 및 누적 지급액 업데이트
    UPDATE public.accounts_payable 
    SET 
        paid_amount = paid_amount + p_amount,
        status = CASE 
                    WHEN (paid_amount + p_amount) >= total_amount THEN 'paid' 
                    ELSE 'partially_paid' 
                 END,
        updated_at = now()
    WHERE id = p_ap_id;

    RETURN jsonb_build_object('success', true, 'message', '지급 처리가 완료되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ==========================================
-- [Phase 5-2] 일반 매입(Purchase) AP 통합 (SQL)
-- ==========================================

-- [1] 매입 헤더 확장 (지급기한 추가)
ALTER TABLE public.purchase_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] 매입 확정 RPC 고도화 (confirm_purchase_document - AP 연동)
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;
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
        WHERE closing_year = to_char((v_head).purchase_date, 'YYYY') AND closing_month = to_char((v_head).purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 총 매입액 산출 (공급가액 + 부가세)
    SELECT SUM(net_amount + vat_amount) INTO v_total_amount 
    FROM public.purchase_items 
    WHERE purchase_header_id = p_doc_id;

    -- 5. 매입채무(AP) 자동 생성
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
            (v_head).purchase_date, 
            COALESCE(v_head.due_date, (v_head).purchase_date + INTERVAL '30 days'), 
            v_total_amount, 
            'unpaid', 
            format('매입전표 자동생성 (%s)', v_head.purchase_no),
            auth.uid()
        )
        RETURNING id INTO v_ap_id;
    END IF;

    -- 6. 상태 업데이트 (기존 트리거가 수불/MAC 처리함)
    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('매입 전표가 확정되었으며, 매입채무(%s)가 생성되었습니다.', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] 매입 확정 취소 RPC 고도화 (unconfirm_purchase_document - AP 연동)
CREATE OR REPLACE FUNCTION public.unconfirm_purchase_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    
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
        WHERE closing_year = to_char((v_head).purchase_date, 'YYYY') AND closing_month = to_char((v_head).purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- [Phase 5-2] 연결 AP 체크 (지급액 존재 시 차단)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
    FROM public.accounts_payable 
    WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 대급 지급이 진행된 매입 전표입니다. (지급액: %s) 회계 지급 취소를 먼저 진행하세요.', v_ap_paid));
    END IF;

    -- 4. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- [Phase 5-2] 연결 AP 무효화
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable 
        SET status = 'void', remark = format('매입 확정 취소로 인한 자동 무효화 (%s)', p_reason) 
        WHERE id = v_ap_id;
    END IF;

    -- 5. 상태 업데이트 (트리거가 재고/MAC 역반영함)
    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매입 확정이 취소되었으며 매입채무가 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ==========================================
-- [Phase 5-3] 매출채권(AR) 연동 및 수금 관리 (SQL)
-- ==========================================

-- [1] 매출 헤더 확장 (수금기한 추가)
ALTER TABLE public.sales_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] 매출채권 및 수금 기록 테이블 신설
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

-- 인덱스 추가
CREATE INDEX IF NOT EXISTS idx_ar_customer ON public.accounts_receivable(customer_id);
CREATE INDEX IF NOT EXISTS idx_ar_ref ON public.accounts_receivable(ref_type, ref_id);
CREATE INDEX IF NOT EXISTS idx_receipt_ar ON public.receipt_records(ar_id);

-- [3] 매출 확정 RPC 고도화 (confirm_sales_document - AR 연동)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;
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
        WHERE closing_year = to_char((v_head).sales_date, 'YYYY') AND closing_month = to_char((v_head).sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 4. 총 매출액 산산 (공급가액 + 부가세)
    SELECT total_amount INTO v_total_amount FROM public.sales_headers WHERE id = p_doc_id;

    -- 5. 매출채권(AR) 자동 생성
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
            (v_head).sales_date, 
            COALESCE(v_head.due_date, (v_head).sales_date + INTERVAL '30 days'), 
            v_total_amount, 
            'unpaid', 
            format('매출전표 자동생성 (%s)', v_head.sales_no),
            auth.uid()
        )
        RETURNING id INTO v_ar_id;
    END IF;

    -- 6. 상태 업데이트 (트리거가 재고/MAC 처리함)
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('매출이 확정되었으며, 매출채권(%s)이 생성되었습니다.', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] 매출 확정 취소 RPC 고도화 (unconfirm_sales_document - AR 연동)
CREATE OR REPLACE FUNCTION public.unconfirm_sales_document(
    p_doc_id bigint,
    p_reason text,
    p_user_uuid uuid
)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    
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
        WHERE closing_year = to_char((v_head).sales_date, 'YYYY') AND closing_month = to_char((v_head).sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- 4. 연결 AR 체크 (수금액 존재 시 차단)
    SELECT id, received_amount INTO v_ar_id, v_ar_received 
    FROM public.accounts_receivable 
    WHERE ref_type = 'SALES' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ar_id IS NOT NULL AND COALESCE(v_ar_received, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('이미 수금이 진행된 매출 전표입니다. (수금액: %s) 수금 취소를 먼저 진행하세요.', v_ar_received));
    END IF;

    -- 5. 로그 및 상태 환원
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('SALES', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- 6. 연결 AR 무효화
    IF v_ar_id IS NOT NULL THEN
        UPDATE public.accounts_receivable 
        SET status = 'void', updated_at = now(), remark = format('매출 확정 취소로 인한 자동 무효화 (%s)', p_reason) 
        WHERE id = v_ar_id;
    END IF;

    -- 7. 상태 업데이트
    UPDATE public.sales_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '매출 확정이 취소되었으며 매출채권이 무효화되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] 수금 등록 전용 RPC (register_receipt)
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
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    -- 2. AR 상태 확인
    SELECT status INTO v_ar_status FROM public.accounts_receivable WHERE id = p_ar_id;
    IF v_ar_status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '무효화된 채권에는 수금할 수 없습니다.'); END IF;
    IF v_ar_status = 'paid' THEN RETURN jsonb_build_object('success', false, 'message', '이미 수금이 완료된 건입니다.'); END IF;

    -- 3. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 일자의 월 마감이 완료되어 수금을 등록할 수 없습니다.'); END IF;

    -- 4. 수금 기록 추가
    INSERT INTO public.receipt_records (ar_id, receipt_date, amount, payment_method, remark, created_by)
    VALUES (p_ar_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AR 상태 갱신
    UPDATE public.accounts_receivable 
    SET received_amount = received_amount + p_amount,
        updated_at = now(),
        status = CASE 
            WHEN (received_amount + p_amount) >= total_amount THEN 'paid' 
            ELSE 'partially_paid' 
        END
    WHERE id = p_ar_id;

    RETURN jsonb_build_object('success', true, 'message', '수금이 성공적으로 등록되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 함수 실행 권한
REVOKE ALL ON FUNCTION public.register_receipt FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_receipt TO authenticated;

-- ==========================================
-- [Phase 5-4] 거래처 원장(Ledger) 통합 뷰 (SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_ledger AS
-- 1. 매출 (Accounts Receivable - AR)
SELECT 
    id AS source_id,
    customer_id,
    doc_date,
    'AR_SALES' AS ref_type,
    ref_id,
    total_amount AS amount, -- 순채권 증가 (+)
    remark
FROM public.accounts_receivable
WHERE status != 'void'

UNION ALL

-- 2. 수금 (Receipt Records)
SELECT 
    r.id AS source_id,
    ar.customer_id,
    r.receipt_date AS doc_date,
    'RECEIPT' AS ref_type,
    ar.id AS ref_id,
    -r.amount AS amount, -- 순채권 감소 (-)
    r.remark
FROM public.receipt_records r
JOIN public.accounts_receivable ar ON r.ar_id = ar.id
WHERE ar.status != 'void'

UNION ALL

-- 3. 매입/외상 (Accounts Payable - AP)
SELECT 
    id AS source_id,
    vendor_id AS customer_id,
    doc_date,
    'AP_' || ref_type AS ref_type,
    ref_id,
    -total_amount AS amount, -- 순채권 감소 (-) (줄 돈 발생)
    remark
FROM public.accounts_payable
WHERE status != 'void'

UNION ALL

-- 4. 지급 (Payment Records)
SELECT 
    p.id AS source_id,
    ap.vendor_id AS customer_id,
    p.payment_date AS doc_date,
    'PAYMENT' AS ref_type,
    ap.id AS ref_id,
    p.amount AS amount, -- 순채권 증가 (+) (줄 돈 소멸)
    p.remark
FROM public.payment_records p
JOIN public.accounts_payable ap ON p.ap_id = ap.id
WHERE ap.status != 'void';

-- 권한 설정
GRANT SELECT ON public.v_customer_ledger TO authenticated;

-- 대시보드용 요약 뷰 (KPI 상단용)
CREATE OR REPLACE VIEW public.v_accounting_summary AS
SELECT
    -- 총 미수금 (AR 잔액)
    COALESCE(SUM(CASE WHEN ref_type LIKE 'AR%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'RECEIPT' THEN amount ELSE 0 END), 0) AS total_receivable,
    
    -- 총 미지급금 (AP 잔액 - 부호 반전하여 양수로 표시)
    -(COALESCE(SUM(CASE WHEN ref_type LIKE 'AP%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'PAYMENT' THEN amount ELSE 0 END), 0)) AS total_payable
FROM public.v_customer_ledger;

GRANT SELECT ON public.v_accounting_summary TO authenticated;
