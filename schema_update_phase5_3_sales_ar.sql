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
    v_head RECORD;
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
        WHERE closing_year = to_char(v_head.sales_date, 'YYYY') AND closing_month = to_char(v_head.sales_date, 'MM') AND status = 'closed'
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
            v_head.sales_date, 
            COALESCE(v_head.due_date, v_head.sales_date + INTERVAL '30 days'), 
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
