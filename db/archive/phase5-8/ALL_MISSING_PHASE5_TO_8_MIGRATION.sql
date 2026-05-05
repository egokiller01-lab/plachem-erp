-- ==========================================
-- [Phase 5-1] ?Œê³„/AP(ë§¤ì…ì±„ë¬´) ?°ë™ (SQL)
-- ==========================================

-- [1] ê¸°ì¡´ ?ì‚° ?Œì´ë¸??•ì¥ (ì¶”ê?ë¹„ìš© ì±„ë¬´ ?¬ë? ? íƒ??
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS is_additional_cost_payable boolean DEFAULT true;

-- [2] ë§¤ì…ì±„ë¬´ ?Œì´ë¸?(ACCOUNTS_PAYABLE)
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

-- ?¸ë±??CREATE INDEX IF NOT EXISTS idx_ap_vendor ON public.accounts_payable(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ap_ref ON public.accounts_payable(ref_type, ref_id);

-- [3] ì§€ê¸?ê¸°ë¡ ?Œì´ë¸?(PAYMENT_RECORDS)
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

-- [4] ?ì‚° ?•ì • RPC ê³ ë„??(confirm_production_document - AP ?ë™ ?ì„± ì¶”ê?)
-- ?´ë? ì¡´ì¬?˜ëŠ” ?¨ìˆ˜ë¥??˜ì •?˜ì—¬ AP ?°ë™ ì¶”ê?
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
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    -- 2. ë¬¸ì„œ ?•ì¸
    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •??ë¬¸ì„œ?…ë‹ˆ??'); END IF;

    -- 3. ë§ˆê° ?•ì¸ (?ì‚°??ê¸°ì?)
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?”ì´ ë§ˆê°?˜ì–´ ?•ì •?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 4. ?¬ê³  ì²´í¬ ë°??ì¬ë£Œë¹„ ?°ì¶œ
    FOR v_item IN 
        SELECT i.product_id, i.qty, p.moving_avg_cost, p.product_name
        FROM public.production_inputs i JOIN public.products p ON i.product_id = p.id
        WHERE i.production_header_id = p_doc_id
    LOOP
        SELECT stock_qty INTO v_current_stock FROM public.v_product_stock WHERE product_id = v_item.product_id;
        IF COALESCE(v_current_stock, 0) < v_item.qty THEN
            RETURN jsonb_build_object('success', false, 'message', format('?¬ê³  ë¶€ì¡? [%s] (?„ì¬: %s, ?„ìš”: %s)', v_item.product_name, COALESCE(v_current_stock, 0), v_item.qty));
        END IF;
        v_total_material_cost := v_total_material_cost + (v_item.qty * COALESCE(v_item.moving_avg_cost, 0));
    END LOOP;

    -- 5. ?ê? ê³„ì‚° ë°?ë°°ë?
    v_total_production_cost := v_total_material_cost + COALESCE(v_head.processing_fee, 0) + COALESCE(v_head.additional_cost, 0);
    SELECT SUM(qty) INTO v_total_output_qty FROM public.production_outputs WHERE production_header_id = p_doc_id;
    IF v_total_output_qty > 0 THEN v_calculated_unit_cost := v_total_production_cost / v_total_output_qty; ELSE v_calculated_unit_cost := 0; END IF;

    -- 6. ?˜ë¶ˆë¶€ ê¸°ë¡ ë°??¨ê? ?€??    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_INPUT', i.product_id, 0, i.qty, 'production_headers', v_head.id, i.remark
    FROM public.production_inputs i WHERE i.production_header_id = p_doc_id;

    INSERT INTO public.inventory_transactions (txn_date, txn_type, product_id, qty_in, qty_out, ref_table, ref_id, remark)
    SELECT v_head.production_date, 'PROD_OUTPUT', o.product_id, o.qty, 0, 'production_headers', v_head.id, o.remark
    FROM public.production_outputs o WHERE o.production_header_id = p_doc_id;

    UPDATE public.production_outputs SET unit_cost = v_calculated_unit_cost WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] ë§¤ì…ì±„ë¬´(AP) ?ë™ ?ì„±
    IF v_head.production_type = 'SUBCON' AND v_head.vendor_id IS NOT NULL THEN
        -- AP ê¸ˆì•¡ ê²°ì •: ê°€ê³µë¹„ + (ì²?µ¬ë¶„ì¸ ê²½ìš° ë¶€?€ë¹„ìš©)
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

    -- 7. ?íƒœ ?…ë°?´íŠ¸ ë°?MAC ?¬ê³„??    UPDATE public.production_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', format('?ì‚° ?„í‘œê°€ ?•ì •?˜ì—ˆ?¼ë©°, ë¯¸ì?ê¸‰ê¸ˆ(%s)???ì„±?˜ì—ˆ?µë‹ˆ??', ROUND(v_ap_amount, 2)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] ?ì‚° ?•ì • ì·¨ì†Œ RPC ê³ ë„??(unconfirm_production_document - AP ?°ë™ ì¶”ê?)
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
    IF v_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)'); END IF;

    SELECT * INTO v_head FROM public.production_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?•ì •??ë¬¸ì„œë§?ì·¨ì†Œ ê°€?¥í•©?ˆë‹¤.'); END IF;

    -- ë§ˆê° ?•ì¸
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(v_head.production_date, 'YYYY') AND closing_month = to_char(v_head.production_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', 'ë§ˆê°???”ì? ì·¨ì†Œ?????†ìŠµ?ˆë‹¤.'); END IF;

    -- [Phase 5-1] ?°ê²° AP ì²´í¬ (ì§€ê¸‰ì•¡ ì¡´ì¬ ??ì°¨ë‹¨)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid FROM public.accounts_payable WHERE ref_type = 'PRODUCTION_SUBCON' AND ref_id = p_doc_id LIMIT 1;
    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?´ë? ?€ê¸?ì§€ê¸‰ì´ ì§„í–‰???„í‘œ?…ë‹ˆ?? (ì§€ê¸‰ì•¡: %s) ?Œê³„ ì·¨ì†Œë¥?ë¨¼ì? ì§„í–‰?˜ì„¸??', v_ap_paid));
    END IF;

    -- ë¡œê·¸ ë°??˜ë¶ˆ ?? œ
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PRODUCTION', p_doc_id, 'UNCONFIRM', auth.uid(), p_reason, to_jsonb(v_head));
    DELETE FROM public.inventory_transactions WHERE ref_table = 'production_headers' AND ref_id = p_doc_id;
    UPDATE public.production_outputs SET unit_cost = NULL WHERE production_header_id = p_doc_id;

    -- [Phase 5-1] ?°ê²° AP ë¬´íš¨??(?ëŠ” ?? œ)
    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable SET status = 'void', remark = '?ì‚° ?•ì • ì·¨ì†Œë¡??¸í•œ ?ë™ ì·¨ì†Œ' WHERE id = v_ap_id;
    END IF;

    -- ?íƒœ ?˜ì› ë°?MAC ?¬ì¬ê³„ì‚°
    UPDATE public.production_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;
    FOR v_item IN (SELECT DISTINCT product_id FROM public.production_inputs WHERE production_header_id = p_doc_id UNION SELECT DISTINCT product_id FROM public.production_outputs WHERE production_header_id = p_doc_id)
    LOOP PERFORM public.recalculate_mac_for_product(v_item.product_id); END LOOP;

    RETURN jsonb_build_object('success', true, 'message', '?ì‚° ?•ì •??ì·¨ì„œ?˜ì—ˆ?¼ë©° ë¯¸ì?ê¸??„í‘œê°€ ë¬´íš¨?”ë˜?ˆìŠµ?ˆë‹¤.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [6] ì§€ê¸??±ë¡ RPC (register_payment)
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
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)'); END IF;

    -- 2. ë§ˆê° ?•ì¸ (ì§€ê¸‰ì¼ ê¸°ì?)
    SELECT EXISTS (SELECT 1 FROM public.monthly_closings WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed') INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?¼ì????ë§ˆê°???„ë£Œ?˜ì–´ ì§€ê¸‰ì„ ?±ë¡?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 3. AP ì¡´ì¬ ?•ì¸ ë°??”ì•¡ ì²´í¬
    SELECT * INTO v_ap_record FROM public.accounts_payable WHERE id = p_ap_id FOR UPDATE;
    IF v_ap_record IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë§¤ì…ì±„ë¬´ ?•ë³´ë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_ap_record.status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', '?´ë? ì·¨ì†Œ???„í‘œ?…ë‹ˆ??'); END IF;
    
    IF (v_ap_record.total_amount - v_ap_record.paid_amount) < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', format('ì§€ê¸‰ì•¡??ë¯¸ì?ê¸??”ì•¡(%s)??ì´ˆê³¼?????†ìŠµ?ˆë‹¤.', v_ap_record.total_amount - v_ap_record.paid_amount));
    END IF;

    -- 4. ì§€ê¸?ê¸°ë¡ ?ì„±
    INSERT INTO public.payment_records (ap_id, payment_date, amount, payment_method, remark, created_by)
    VALUES (p_ap_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AP ?íƒœ ë°??„ì  ì§€ê¸‰ì•¡ ?…ë°?´íŠ¸
    UPDATE public.accounts_payable 
    SET 
        paid_amount = paid_amount + p_amount,
        status = CASE 
                    WHEN (paid_amount + p_amount) >= total_amount THEN 'paid' 
                    ELSE 'partially_paid' 
                 END,
        updated_at = now()
    WHERE id = p_ap_id;

    RETURN jsonb_build_object('success', true, 'message', 'ì§€ê¸?ì²˜ë¦¬ê°€ ?„ë£Œ?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
-- ==========================================
-- [Phase 5-2] ?¼ë°˜ ë§¤ì…(Purchase) AP ?µí•© (SQL)
-- ==========================================

-- [1] ë§¤ì… ?¤ë” ?•ì¥ (ì§€ê¸‰ê¸°??ì¶”ê?)
ALTER TABLE public.purchase_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] ë§¤ì… ?•ì • RPC ê³ ë„??(confirm_purchase_document - AP ?°ë™)
CREATE OR REPLACE FUNCTION public.confirm_purchase_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ap_id bigint;
BEGIN
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    -- 2. ?„í‘œ ?•ì¸
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •??ë¬¸ì„œ?…ë‹ˆ??'); END IF;

    -- 3. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?”ì´ë§ˆê°?˜ì–´ ?•ì •?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 4. ì´?ë§¤ì…???°ì¶œ (ê³µê¸‰ê°€??+ ë¶€ê°€??
    SELECT SUM(net_amount + vat_amount) INTO v_total_amount 
    FROM public.purchase_items 
    WHERE purchase_header_id = p_doc_id;

    -- 5. ë§¤ì…ì±„ë¬´(AP) ?ë™ ?ì„±
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
            format('ë§¤ì…?„í‘œ ?ë™?ì„± (%s)', v_head.purchase_no),
            auth.uid()
        )
        RETURNING id INTO v_ap_id;
    END IF;

    -- 6. ?íƒœ ?…ë°?´íŠ¸ (ê¸°ì¡´ ?¸ë¦¬ê±°ê? ?˜ë¶ˆ/MAC ì²˜ë¦¬??
    UPDATE public.purchase_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('ë§¤ì… ?„í‘œê°€ ?•ì •?˜ì—ˆ?¼ë©°, ë§¤ì…ì±„ë¬´(%s)ê°€ ?ì„±?˜ì—ˆ?µë‹ˆ??', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [3] ë§¤ì… ?•ì • ì·¨ì†Œ RPC ê³ ë„??(unconfirm_purchase_document - AP ?°ë™)
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
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)');
    END IF;

    -- 2. ?íƒœ ?•ì¸
    SELECT * INTO v_head FROM public.purchase_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?•ì •??ë¬¸ì„œë§?ì·¨ì†Œ ê°€?¥í•©?ˆë‹¤.'); END IF;

    -- 3. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.purchase_date, 'YYYY') AND closing_month = to_char(v_head.purchase_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', 'ë§ˆê°???”ì? ?•ì • ì·¨ì†Œ?????†ìŠµ?ˆë‹¤.'); END IF;

    -- [Phase 5-2] ?°ê²° AP ì²´í¬ (ì§€ê¸‰ì•¡ ì¡´ì¬ ??ì°¨ë‹¨)
    SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
    FROM public.accounts_payable 
    WHERE ref_type = 'PURCHASE' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?´ë? ?€ê¸?ì§€ê¸‰ì´ ì§„í–‰??ë§¤ì… ?„í‘œ?…ë‹ˆ?? (ì§€ê¸‰ì•¡: %s) ?Œê³„ ì§€ê¸?ì·¨ì†Œë¥?ë¨¼ì? ì§„í–‰?˜ì„¸??', v_ap_paid));
    END IF;

    -- 4. ë¡œê·¸ ë°??íƒœ ?˜ì›
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('PURCHASE', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- [Phase 5-2] ?°ê²° AP ë¬´íš¨??    IF v_ap_id IS NOT NULL THEN
        UPDATE public.accounts_payable 
        SET status = 'void', remark = format('ë§¤ì… ?•ì • ì·¨ì†Œë¡??¸í•œ ?ë™ ë¬´íš¨??(%s)', p_reason) 
        WHERE id = v_ap_id;
    END IF;

    -- 5. ?íƒœ ?…ë°?´íŠ¸ (?¸ë¦¬ê±°ê? ?¬ê³ /MAC ??°˜?í•¨)
    UPDATE public.purchase_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë§¤ì… ?•ì •??ì·¨ì†Œ?˜ì—ˆ?¼ë©° ë§¤ì…ì±„ë¬´ê°€ ë¬´íš¨?”ë˜?ˆìŠµ?ˆë‹¤.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
-- ==========================================
-- [Phase 5-3] ë§¤ì¶œì±„ê¶Œ(AR) ?°ë™ ë°??˜ê¸ˆ ê´€ë¦?(SQL)
-- ==========================================

-- [1] ë§¤ì¶œ ?¤ë” ?•ì¥ (?˜ê¸ˆê¸°í•œ ì¶”ê?)
ALTER TABLE public.sales_headers 
ADD COLUMN IF NOT EXISTS due_date date;

-- [2] ë§¤ì¶œì±„ê¶Œ ë°??˜ê¸ˆ ê¸°ë¡ ?Œì´ë¸?? ì„¤
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

-- ?¸ë±??ì¶”ê?
CREATE INDEX IF NOT EXISTS idx_ar_customer ON public.accounts_receivable(customer_id);
CREATE INDEX IF NOT EXISTS idx_ar_ref ON public.accounts_receivable(ref_type, ref_id);
CREATE INDEX IF NOT EXISTS idx_receipt_ar ON public.receipt_records(ar_id);

-- [3] ë§¤ì¶œ ?•ì • RPC ê³ ë„??(confirm_sales_document - AR ?°ë™)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_total_amount numeric := 0;
    v_ar_id bigint;
BEGIN
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    -- 2. ?„í‘œ ?•ì¸
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •??ë¬¸ì„œ?…ë‹ˆ??'); END IF;

    -- 3. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?”ì´ ë§ˆê°?˜ì–´ ?•ì •?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 4. ì´?ë§¤ì¶œ???°ì‚° (ê³µê¸‰ê°€??+ ë¶€ê°€??
    SELECT total_amount INTO v_total_amount FROM public.sales_headers WHERE id = p_doc_id;

    -- 5. ë§¤ì¶œì±„ê¶Œ(AR) ?ë™ ?ì„±
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
            format('ë§¤ì¶œ?„í‘œ ?ë™?ì„± (%s)', v_head.sales_no),
            auth.uid()
        )
        RETURNING id INTO v_ar_id;
    END IF;

    -- 6. ?íƒœ ?…ë°?´íŠ¸ (?¸ë¦¬ê±°ê? ?¬ê³ /MAC ì²˜ë¦¬??
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', format('ë§¤ì¶œ???•ì •?˜ì—ˆ?¼ë©°, ë§¤ì¶œì±„ê¶Œ(%s)???ì„±?˜ì—ˆ?µë‹ˆ??', ROUND(v_total_amount, 0)));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] ë§¤ì¶œ ?•ì • ì·¨ì†Œ RPC ê³ ë„??(unconfirm_sales_document - AR ?°ë™)
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
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role != 'admin' THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)');
    END IF;

    -- 2. ?íƒœ ?•ì¸
    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?•ì •??ë¬¸ì„œë§?ì·¨ì†Œ ê°€?¥í•©?ˆë‹¤.'); END IF;

    -- 3. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', 'ë§ˆê°???”ì? ?•ì • ì·¨ì†Œ?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 4. ?°ê²° AR ì²´í¬ (?˜ê¸ˆ??ì¡´ì¬ ??ì°¨ë‹¨)
    SELECT id, received_amount INTO v_ar_id, v_ar_received 
    FROM public.accounts_receivable 
    WHERE ref_type = 'SALES' AND ref_id = p_doc_id AND status != 'void'
    LIMIT 1;

    IF v_ar_id IS NOT NULL AND COALESCE(v_ar_received, 0) > 0 THEN
        RETURN jsonb_build_object('success', false, 'message', format('?´ë? ?˜ê¸ˆ??ì§„í–‰??ë§¤ì¶œ ?„í‘œ?…ë‹ˆ?? (?˜ê¸ˆ?? %s) ?˜ê¸ˆ ì·¨ì†Œë¥?ë¨¼ì? ì§„í–‰?˜ì„¸??', v_ar_received));
    END IF;

    -- 5. ë¡œê·¸ ë°??íƒœ ?˜ì›
    INSERT INTO public.document_history_logs (doc_type, doc_id, action_type, acted_by, reason, original_data)
    VALUES ('SALES', p_doc_id, 'UNCONFIRM', p_user_uuid, p_reason, to_jsonb(v_head));

    -- 6. ?°ê²° AR ë¬´íš¨??    IF v_ar_id IS NOT NULL THEN
        UPDATE public.accounts_receivable 
        SET status = 'void', updated_at = now(), remark = format('ë§¤ì¶œ ?•ì • ì·¨ì†Œë¡??¸í•œ ?ë™ ë¬´íš¨??(%s)', p_reason) 
        WHERE id = v_ar_id;
    END IF;

    -- 7. ?íƒœ ?…ë°?´íŠ¸
    UPDATE public.sales_headers SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë§¤ì¶œ ?•ì •??ì·¨ì†Œ?˜ì—ˆ?¼ë©° ë§¤ì¶œì±„ê¶Œ??ë¬´íš¨?”ë˜?ˆìŠµ?ˆë‹¤.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] ?˜ê¸ˆ ?±ë¡ ?„ìš© RPC (register_receipt)
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
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    -- 2. AR ?íƒœ ?•ì¸
    SELECT status INTO v_ar_status FROM public.accounts_receivable WHERE id = p_ar_id;
    IF v_ar_status = 'void' THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬´íš¨?”ëœ ì±„ê¶Œ?ëŠ” ?˜ê¸ˆ?????†ìŠµ?ˆë‹¤.'); END IF;
    IF v_ar_status = 'paid' THEN RETURN jsonb_build_object('success', false, 'message', '?´ë? ?˜ê¸ˆ???„ë£Œ??ê±´ì…?ˆë‹¤.'); END IF;

    -- 3. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(p_date, 'YYYY') AND closing_month = to_char(p_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?¼ì????ë§ˆê°???„ë£Œ?˜ì–´ ?˜ê¸ˆ???±ë¡?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 4. ?˜ê¸ˆ ê¸°ë¡ ì¶”ê?
    INSERT INTO public.receipt_records (ar_id, receipt_date, amount, payment_method, remark, created_by)
    VALUES (p_ar_id, p_date, p_amount, p_method, p_remark, auth.uid());

    -- 5. AR ?íƒœ ê°±ì‹ 
    UPDATE public.accounts_receivable 
    SET received_amount = received_amount + p_amount,
        updated_at = now(),
        status = CASE 
            WHEN (received_amount + p_amount) >= total_amount THEN 'paid' 
            ELSE 'partially_paid' 
        END
    WHERE id = p_ar_id;

    RETURN jsonb_build_object('success', true, 'message', '?˜ê¸ˆ???±ê³µ?ìœ¼ë¡??±ë¡?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ?¨ìˆ˜ ?¤í–‰ ê¶Œí•œ
REVOKE ALL ON FUNCTION public.register_receipt FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_receipt TO authenticated;
-- ==========================================
-- [Phase 5-4] ê±°ë˜ì²??ì¥(Ledger) ?µí•© ë·?(SQL)
-- ==========================================

CREATE OR REPLACE VIEW public.v_customer_ledger AS
-- 1. ë§¤ì¶œ (Accounts Receivable - AR)
SELECT 
    id AS source_id,
    customer_id,
    doc_date,
    'AR_SALES' AS ref_type,
    ref_id,
    total_amount AS amount, -- ?œì±„ê¶?ì¦ê? (+)
    remark
FROM public.accounts_receivable
WHERE status != 'void'

UNION ALL

-- 2. ?˜ê¸ˆ (Receipt Records)
SELECT 
    r.id AS source_id,
    ar.customer_id,
    r.receipt_date AS doc_date,
    'RECEIPT' AS ref_type,
    ar.id AS ref_id,
    -r.amount AS amount, -- ?œì±„ê¶?ê°ì†Œ (-)
    r.remark
FROM public.receipt_records r
JOIN public.accounts_receivable ar ON r.ar_id = ar.id
WHERE ar.status != 'void'

UNION ALL

-- 3. ë§¤ì…/?¸ìƒ (Accounts Payable - AP)
SELECT 
    id AS source_id,
    vendor_id AS customer_id,
    doc_date,
    'AP_' || ref_type AS ref_type,
    ref_id,
    -total_amount AS amount, -- ?œì±„ê¶?ê°ì†Œ (-) (ì¤???ë°œìƒ)
    remark
FROM public.accounts_payable
WHERE status != 'void'

UNION ALL

-- 4. ì§€ê¸?(Payment Records)
SELECT 
    p.id AS source_id,
    ap.vendor_id AS customer_id,
    p.payment_date AS doc_date,
    'PAYMENT' AS ref_type,
    ap.id AS ref_id,
    p.amount AS amount, -- ?œì±„ê¶?ì¦ê? (+) (ì¤????Œë©¸)
    p.remark
FROM public.payment_records p
JOIN public.accounts_payable ap ON p.ap_id = ap.id
WHERE ap.status != 'void';

-- ê¶Œí•œ ?¤ì •
GRANT SELECT ON public.v_customer_ledger TO authenticated;

-- ?€?œë³´?œìš© ?”ì•½ ë·?(KPI ?ë‹¨??
CREATE OR REPLACE VIEW public.v_accounting_summary AS
SELECT
    -- ì´?ë¯¸ìˆ˜ê¸?(AR ?”ì•¡)
    COALESCE(SUM(CASE WHEN ref_type LIKE 'AR%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'RECEIPT' THEN amount ELSE 0 END), 0) AS total_receivable,
    
    -- ì´?ë¯¸ì?ê¸‰ê¸ˆ (AP ?”ì•¡ - ë¶€??ë°˜ì „?˜ì—¬ ?‘ìˆ˜ë¡??œì‹œ)
    -(COALESCE(SUM(CASE WHEN ref_type LIKE 'AP%' THEN amount ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN ref_type = 'PAYMENT' THEN amount ELSE 0 END), 0)) AS total_payable
FROM public.v_customer_ledger;

GRANT SELECT ON public.v_accounting_summary TO authenticated;
-- ==========================================
-- [Phase 6-1] ?¼ì¼ ?ê¸ˆ ë³´ê³ ???°ì´??ì§‘ê³„ (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_daily_cash_report(p_date date)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_prev_date date := p_date - INTERVAL '1 day';
    
    -- ?¹ì¼ ì§‘ê³„
    v_today_receipt numeric := 0;
    v_today_payment numeric := 0;
    v_today_new_ar numeric := 0;
    v_today_new_ap numeric := 0;
    
    -- ?„ì¼ ì§‘ê³„
    v_prev_receipt numeric := 0;
    v_prev_payment numeric := 0;
    v_prev_new_ar numeric := 0;
    v_prev_new_ap numeric := 0;
    
    -- ?ì„¸ ê°€ê³??°ì´??    v_receipt_details jsonb;
    v_payment_details jsonb;
    v_overdue_ar jsonb;
    v_overdue_ap jsonb;
BEGIN
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ì¡°íšŒ ê¶Œí•œ???†ìŠµ?ˆë‹¤.');
    END IF;

    -- 2. ?¹ì¼ ì§‘ê³„ (Receipts, Payments, New AR/AP)
    SELECT COALESCE(SUM(amount), 0) INTO v_today_receipt FROM public.receipt_records WHERE receipt_date = p_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_today_payment FROM public.payment_records WHERE payment_date = p_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ar FROM public.accounts_receivable WHERE doc_date = p_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_new_ap FROM public.accounts_payable WHERE doc_date = p_date AND status != 'void';

    -- 3. ?„ì¼ ì§‘ê³„
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_receipt FROM public.receipt_records WHERE receipt_date = v_prev_date;
    SELECT COALESCE(SUM(amount), 0) INTO v_prev_payment FROM public.payment_records WHERE payment_date = v_prev_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ar FROM public.accounts_receivable WHERE doc_date = v_prev_date AND status != 'void';
    SELECT COALESCE(SUM(total_amount), 0) INTO v_prev_new_ap FROM public.accounts_payable WHERE doc_date = v_prev_date AND status != 'void';

    -- 4. ?ì„¸ ë¦¬ìŠ¤??(?¹ì¼)
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

    -- 5. ?°ì²´ ?”ì•½ (?„ì²´ ê¸°ì? Top 5)
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

    -- 6. ?µí•© ë©”ì‹œì§€ ë°˜í™˜
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
-- [Phase 6-2] ì£¼ê°„/?”ê°„ ?ê¸ˆ ì¶”ì„¸ ë¶„ì„ (SQL)
-- ==========================================

CREATE OR REPLACE FUNCTION public.get_cash_trend_report(
    p_type varchar(10), -- 'weekly', 'monthly'
    p_limit int DEFAULT 6   -- ìµœê·¼ 6ê°?ì£??ëŠ” 6ê°???)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_result jsonb;
    v_trend_data jsonb;
    v_summary jsonb;
    v_current_period_start date;
    v_prev_period_start date;
BEGIN
    -- 1. ê¶Œí•œ ì²´í¬
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ì¡°íšŒ ê¶Œí•œ???†ìŠµ?ˆë‹¤.');
    END IF;

    -- 2. ê¸°ê°„ ê¸°ì? ?¤ì • (ì£¼ê°„: ?”ìš”???œì‘)
    IF p_type = 'weekly' THEN
        v_current_period_start := date_trunc('week', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 week')::date;
    ELSE
        v_current_period_start := date_trunc('month', CURRENT_DATE)::date;
        v_prev_period_start := (v_current_period_start - INTERVAL '1 month')::date;
    END IF;

    -- 3. ?µí•© ì¶”ì„¸ ?°ì´??ì¶”ì¶œ (ìµœê·¼ Nê°?ê¸°ê°„)
    WITH periods AS (
        SELECT 
            CASE 
                WHEN p_type = 'weekly' THEN (date_trunc('week', CURRENT_DATE) - (n || ' week')::interval)::date
                ELSE (date_trunc('month', CURRENT_DATE) - (n || ' month')::interval)::date
            END AS period_start
        FROM generate_series(0, p_limit - 1) n
    ),
    receipts AS (
        SELECT 
            date_trunc(p_type, receipt_date)::date as p_start,
            SUM(amount) as total_receipt
        FROM public.receipt_records
        GROUP BY 1
    ),
    payments AS (
        SELECT 
            date_trunc(p_type, payment_date)::date as p_start,
            SUM(amount) as total_payment
        FROM public.payment_records
        GROUP BY 1
    ),
    ar_new AS (
        SELECT 
            date_trunc(p_type, doc_date)::date as p_start,
            SUM(total_amount) as new_ar
        FROM public.accounts_receivable
        WHERE status != 'void'
        GROUP BY 1
    ),
    ap_new AS (
        SELECT 
            date_trunc(p_type, doc_date)::date as p_start,
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

    -- 4. ?”ì•½ ?°ì´??ê°€ê³?(?„ì¬ vs ?„ê¸°)
    -- ??CTE ê²°ê³¼ë¥??œìš©?˜ì—¬ ?”ì•½ ?•ë³´ ?ì„±
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
-- [Phase 7-1] ?ìµ ë¶„ì„(P&L) ?µí•© ?°ì´??ë·?(SQL)
-- ==========================================

-- 1. ?”ë³„ ?„ì‚¬ ?ìµ ?”ì•½ ë·?CREATE OR REPLACE VIEW public.v_profit_loss_summary AS
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

-- 2. ?œí’ˆë³??ìµ ë¶„ì„ ë·?CREATE OR REPLACE VIEW public.v_product_profitability AS
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
-- [Phase 7-2] ?¼ë°˜ ?ê?ë¹?SG&A) ëª¨ë“ˆ (SQL)
-- ==========================================

-- [1] ë¹„ìš© ì¹´í…Œê³ ë¦¬ ë§ˆìŠ¤??CREATE TABLE IF NOT EXISTS public.expense_categories (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_name varchar(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamptz DEFAULT now()
);

-- ì´ˆê¸° ì¹´í…Œê³ ë¦¬ ?°ì´??INSERT INTO public.expense_categories (category_name) VALUES 
('ê¸‰ì—¬'), ('?„ë?ë£?), ('?Œëª¨?ˆë¹„'), ('?´ì†¡ë¹?), ('?µì‹ ë¹?), ('?˜ë„ê´‘ì—´ë¹?), ('êµìœ¡?ˆë ¨ë¹?), ('ê¸°í??ê?ë¹?)
ON CONFLICT DO NOTHING;

-- [2] ë¹„ìš© ?„í‘œ ?Œì´ë¸?CREATE TABLE IF NOT EXISTS public.expense_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_id bigint NOT NULL REFERENCES public.expense_categories(id),
    expense_date date NOT NULL,
    is_payable boolean NOT NULL DEFAULT false, -- AP ?ì„± ?¬ë?
    vendor_id bigint REFERENCES public.customers(id), -- ì§€ê¸‰ì²˜ (is_payable=true ??ê¶Œì¥)
    due_date date, -- ì§€ê¸?ê¸°í•œ
    amount numeric NOT NULL DEFAULT 0, -- ê³µê¸‰ê°€??(P&L ë°˜ì˜ë¶?
    vat_amount numeric NOT NULL DEFAULT 0,
    total_amount numeric NOT NULL DEFAULT 0, -- (AP ?ì„±??
    status varchar(20) NOT NULL DEFAULT 'draft', -- draft, confirmed, void
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_expense_date ON public.expense_records(expense_date);
CREATE INDEX IF NOT EXISTS idx_expense_cat ON public.expense_records(category_id);

-- [3] ë¹„ìš© ?•ì • RPC (confirm_expense_document)
CREATE OR REPLACE FUNCTION public.confirm_expense_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
BEGIN
    -- 1. ê¶Œí•œ ë°??„í‘œ ?•ì¸
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    SELECT e.*, c.category_name INTO v_head 
    FROM public.expense_records e 
    JOIN public.expense_categories c ON e.category_id = c.id
    WHERE e.id = p_doc_id;

    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'ë¬¸ì„œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •??ë¬¸ì„œ?…ë‹ˆ??'); END IF;

    -- 2. ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '?´ë‹¹ ?”ì´ ë§ˆê°?˜ì–´ ?•ì •?????†ìŠµ?ˆë‹¤.'); END IF;

    -- 3. AP ?ë™ ?°ë™ (is_payable = true ???Œë§Œ)
    IF v_head.is_payable THEN
        IF v_head.vendor_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', 'ì§€ê¸??˜ë¬´ê°€ ?ˆëŠ” ë¹„ìš©?€ ê±°ë˜ì²?Vendor)ë¥?ì§€?•í•´???©ë‹ˆ??');
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
            format('?ê?ë¹??ë™?ì„± (%s)', v_head.category_name),
            auth.uid()
        );
    END IF;

    -- 4. ?íƒœ ?…ë°?´íŠ¸
    UPDATE public.expense_records SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë¹„ìš© ?„í‘œê°€ ?•ì •?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] ë¹„ìš© ?•ì • ì·¨ì†Œ RPC (unconfirm_expense_document)
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
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)');
    END IF;

    SELECT * INTO v_head FROM public.expense_records WHERE id = p_doc_id;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '?•ì •??ë¬¸ì„œë§?ì·¨ì†Œ ê°€?¥í•©?ˆë‹¤.'); END IF;

    -- ë§ˆê° ?•ì¸
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', 'ë§ˆê°???”ì? ?•ì • ì·¨ì†Œ?????†ìŠµ?ˆë‹¤.'); END IF;

    -- ?°ê²° AP ì²´í¬ (ì§€ê¸‰ì•¡ ì¡´ì¬ ??ì°¨ë‹¨)
    IF v_head.is_payable THEN
        SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
        FROM public.accounts_payable 
        WHERE ref_type = 'EXPENSE' AND ref_id = p_doc_id AND status != 'void'
        LIMIT 1;

        IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
            RETURN jsonb_build_object('success', false, 'message', format('?´ë? ì§€ê¸?ì²˜ë¦¬ê°€ ì§„í–‰??ê±´ì…?ˆë‹¤. (ì§€ê¸‰ì•¡: %s) ?Œê³„ ì§€ê¸?ì·¨ì†Œë¥?ë¨¼ì? ì§„í–‰?˜ì„¸??', v_ap_paid));
        END IF;

        IF v_ap_id IS NOT NULL THEN
            UPDATE public.accounts_payable SET status = 'void', remark = format('ë¹„ìš© ?•ì • ì·¨ì†Œë¡??¸í•œ ì·¨ì†Œ (%s)', p_reason) WHERE id = v_ap_id;
        END IF;
    END IF;

    -- ë¡œê·¸ ê¸°ë¡ ë°??íƒœ ?…ë°?´íŠ¸
    UPDATE public.expense_records SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë¹„ìš© ?„í‘œê°€ Draft ?íƒœë¡??˜ì›?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] P&L ?”ì•½ ë·?ê³ ë„??(?ê?ë¹?ì§‘ê³„ ?¬í•¨)
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
-- [Phase 7-3] ê±°ë˜ì²˜ë³„ ?˜ìµ??ë¶„ì„ ë·?(SQL)
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

COMMENT ON VIEW public.v_customer_profitability IS 'ê±°ë˜ì²˜ë³„ ?”ë³„ ë§¤ì¶œ, ?ê?, ì´ì´??ë°?ì´ì´?µë¥ ??ë¶„ì„?˜ëŠ” ë·?;

GRANT SELECT ON public.v_customer_profitability TO authenticated;
-- ==========================================
-- [Phase 8-1] ?ì´ì§?ë¶„ì„ ë°??¬ì‹ ?œë„ ê´€ë¦?(SQL)
-- ==========================================

-- [1] ê±°ë˜ì²?ë§ˆìŠ¤???„ë“œ ?•ì¥
ALTER TABLE public.customers
ADD COLUMN IF NOT EXISTS credit_limit numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_credit_unlimited boolean DEFAULT false;

COMMENT ON COLUMN public.customers.credit_limit IS '?¬ì‹  ?œë„??(0 = ?¸ìƒ ë¶ˆê?/?„ê¸ˆ ê±°ë˜ ?„ìš©)';
COMMENT ON COLUMN public.customers.is_credit_unlimited IS '?¬ì‹  ?œë„ ë¬´ì œ???¬ë?';

-- [2] ?ì´ì§?ë¶„ì„ RPC (get_aging_report)
-- ê¸°ì????¤ëŠ˜) ?ì˜ ë¯¸ìˆ˜/ë¯¸ì?ê¸‰ê¸ˆ??6ê°?ë²„í‚·?¼ë¡œ ì§‘ê³„
CREATE OR REPLACE FUNCTION public.get_aging_report(p_type varchar) -- 'AR' or 'AP'
RETURNS TABLE (
    customer_id bigint,
    customer_name varchar,
    total_balance numeric,
    bucket_normal numeric,    -- ?°ì²´ ??    bucket_pending numeric,   -- due_date IS NULL
    bucket_30 numeric,        -- 1-30??    bucket_60 numeric,        -- 31-60??    bucket_90 numeric,        -- 61-90??    bucket_over_90 numeric    -- 90??ì´ˆê³¼
) AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        SELECT 
            c.id as cid,
            c.customer_name as cname,
            (t.total_amount - t.received_amount) as balance, -- AP??ê²½ìš° received_amount??paid_amountë¡?ì²˜ë¦¬??            CASE 
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
                COALESCE(received_amount, 0) as received_amount -- AR ?Œì´ë¸?ê¸°ì?
            FROM public.accounts_receivable 
            WHERE p_type = 'AR' AND status != 'paid' AND status != 'void'
            UNION ALL
            SELECT 
                vendor_id as customer_id, 
                due_date, 
                total_amount, 
                COALESCE(paid_amount, 0) as received_amount -- AP ?Œì´ë¸?ê¸°ì? (paid_amount ?¬ìš©)
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

-- [3] ?¬ì‹  ?œë„ ì²´í¬ RPC (check_customer_credit)
-- ?¹ì • ê±°ë˜ì²˜ì˜ ?„ì¬ ?¬ì‹  ?íƒœ?€ ? ê·œ ë§¤ì¶œ?¡ì„ ë¹„êµ?˜ì—¬ ê²½ê³ ê°?ë°˜í™˜
CREATE OR REPLACE FUNCTION public.check_customer_credit(p_customer_id bigint, p_new_amount numeric)
RETURNS jsonb AS $$
DECLARE
    v_limit numeric;
    v_unlimited boolean;
    v_current_ar numeric;
    v_total_exposure numeric;
BEGIN
    -- ?œë„ ?•ë³´ ì¡°íšŒ
    SELECT credit_limit, is_credit_unlimited INTO v_limit, v_unlimited
    FROM public.customers WHERE id = p_customer_id;

    IF v_unlimited THEN
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'is_unlimited', true);
    END IF;

    -- ?„ì¬ ì±„ê¶Œ ?”ì•¡ ì§‘ê³„
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
            'message', format('?¬ì‹  ?œë„(%s)ë¥?%s ì´ˆê³¼?ˆìŠµ?ˆë‹¤.', v_limit, (v_total_exposure - v_limit))
        );
    ELSE
        RETURN jsonb_build_object('is_exceeded', false, 'limit', v_limit, 'current_ar', v_current_ar);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_aging_report TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_customer_credit TO authenticated;
-- ==========================================
-- [Phase 8-2] ?¬ì‹  ?˜ë“œ ì°¨ë‹¨ ë°??ˆì™¸ ?¹ì¸ (SQL)
-- ==========================================

-- [1] ?¬ì‹  ?ˆì™¸ ?¹ì¸ ?”ì²­ ?Œì´ë¸?CREATE TABLE IF NOT EXISTS public.credit_exception_requests (
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

-- [2] ?¹ì¸ ë¬´íš¨???¸ë¦¬ê±?(Auto-Invalidation)
-- ?„í‘œ??ê±°ë˜ì²?customer_id)??ì´ì•¡(total_amount) ë³€ê²???ê¸°ì¡´ ?¹ì¸??void ì²˜ë¦¬
CREATE OR REPLACE FUNCTION public.trg_invalidate_credit_approval()
RETURNS TRIGGER AS $$
BEGIN
    -- ì¤‘ìš” ?„ë“œ ë³€ê²???ê¸°ì¡´ ëª¨ë“  'approved' ?ëŠ” 'pending' ?”ì²­??ë¬´íš¨??    IF (OLD.customer_id IS DISTINCT FROM NEW.customer_id) OR 
       (OLD.total_amount IS DISTINCT FROM NEW.total_amount) THEN
        
        UPDATE public.credit_exception_requests
        SET status = 'void', 
            approver_comment = format('?°ì´??ë³€ê²½ìœ¼ë¡??¸í•œ ?ë™ ë¬´íš¨??(?´ì „ ì´ì•¡: %s -> ?„ì¬: %s)', OLD.total_amount, NEW.total_amount)
        WHERE sales_header_id = NEW.id AND status IN ('approved', 'pending');
        
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_sales_header_credit_integrity
BEFORE UPDATE ON public.sales_headers
FOR EACH ROW
EXECUTE FUNCTION public.trg_invalidate_credit_approval();

-- [3] ?¬ì‹  ?ˆì™¸ ?¹ì¸ ì²˜ë¦¬ RPC (manage_credit_exception)
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
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Admin ?„ìš©)');
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

    RETURN jsonb_build_object('success', true, 'message', 'ì²˜ë¦¬ê°€ ?„ë£Œ?˜ì—ˆ?µë‹ˆ??');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- [4] ë§¤ì¶œ ?•ì • RPC ê³ ë„??(confirm_sales_document - Hard Block ?ìš©)
CREATE OR REPLACE FUNCTION public.confirm_sales_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_credit_res jsonb;
    v_is_approved boolean;
BEGIN
    -- 1. ê¶Œí•œ ë°??íƒœ ?•ì¸
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'ê¶Œí•œ???†ìŠµ?ˆë‹¤ (Manager ?´ìƒ ?„ìš”)');
    END IF;

    SELECT * INTO v_head FROM public.sales_headers WHERE id = p_doc_id;
    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '?„í‘œë¥?ì°¾ì„ ???†ìŠµ?ˆë‹¤.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '?´ë? ?•ì •???„í‘œ?…ë‹ˆ??'); END IF;

    -- 2. ?¬ì‹  ?œë„ ì²´í¬ (Hard Control)
    v_credit_res := public.check_customer_credit(v_head.customer_id, v_head.total_amount);
    
    IF (v_credit_res->>'is_exceeded')::boolean THEN
        -- ?ˆì™¸ ?¹ì¸ ?¬ë? ?•ì¸
        SELECT EXISTS (
            SELECT 1 FROM public.credit_exception_requests 
            WHERE sales_header_id = p_doc_id AND status = 'approved'
        ) INTO v_is_approved;

        IF NOT v_is_approved THEN
            RETURN jsonb_build_object(
                'success', false, 
                'error_type', 'CREDIT_EXCEEDED',
                'message', format('?¬ì‹  ?œë„ ì´ˆê³¼ë¡??•ì •??ì°¨ë‹¨?˜ì—ˆ?µë‹ˆ?? (ê´€ë¦¬ì ?¹ì¸ ?„ìš”) %s', v_credit_res->>'message')
            );
        END IF;
    END IF;

    -- 3. ê¸°ì¡´ ?ê? ë¡œì§ ë°??¬ê³  ?…ë°?´íŠ¸ (ê°„ëµ?”ëœ ?ˆì‹œ, ?¤ì œ ë¡œì§ ? ì? ?„ìš”)
    -- ... (ê¸°ì¡´ ?•ì • ë¡œì§ ?˜í–‰) ...
    
    -- ?íƒœ ?…ë°?´íŠ¸
    UPDATE public.sales_headers SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', 'ë§¤ì¶œ???•ìƒ?ìœ¼ë¡??•ì •?˜ì—ˆ?µë‹ˆ??');
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
