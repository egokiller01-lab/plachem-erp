-- ==========================================
-- [Phase 7-2] 일반 판관비(SG&A) 모듈 (SQL)
-- ==========================================

-- [1] 비용 카테고리 마스터
CREATE TABLE IF NOT EXISTS public.expense_categories (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_name varchar(100) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamptz DEFAULT now()
);

-- 초기 카테고리 데이터
INSERT INTO public.expense_categories (category_name) VALUES 
('급여'), ('임대료'), ('소모품비'), ('운송비'), ('통신비'), ('수도광열비'), ('교육훈련비'), ('기타판관비')
ON CONFLICT DO NOTHING;

-- [2] 비용 전표 테이블
CREATE TABLE IF NOT EXISTS public.expense_records (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_id bigint NOT NULL REFERENCES public.expense_categories(id),
    expense_date date NOT NULL,
    is_payable boolean NOT NULL DEFAULT false, -- AP 생성 여부
    vendor_id bigint REFERENCES public.customers(id), -- 지급처 (is_payable=true 시 권장)
    due_date date, -- 지급 기한
    amount numeric NOT NULL DEFAULT 0, -- 공급가액 (P&L 반영분)
    vat_amount numeric NOT NULL DEFAULT 0,
    total_amount numeric NOT NULL DEFAULT 0, -- (AP 생성액)
    status varchar(20) NOT NULL DEFAULT 'draft', -- draft, confirmed, void
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_expense_date ON public.expense_records(expense_date);
CREATE INDEX IF NOT EXISTS idx_expense_cat ON public.expense_records(category_id);

-- [3] 비용 확정 RPC (confirm_expense_document)
CREATE OR REPLACE FUNCTION public.confirm_expense_document(p_doc_id bigint)
RETURNS jsonb AS $$
DECLARE
    v_role text;
    v_head RECORD;
    v_is_month_closed boolean;
    v_ap_id bigint;
BEGIN
    -- 1. 권한 및 전표 확인
    v_role := public.get_my_role();
    IF v_role NOT IN ('manager', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Manager 이상 필요)');
    END IF;

    SELECT e.*, c.category_name INTO v_head 
    FROM public.expense_records e 
    JOIN public.expense_categories c ON e.category_id = c.id
    WHERE e.id = p_doc_id;

    IF v_head IS NULL THEN RETURN jsonb_build_object('success', false, 'message', '문서를 찾을 수 없습니다.'); END IF;
    IF v_head.status = 'confirmed' THEN RETURN jsonb_build_object('success', true, 'message', '이미 확정된 문서입니다.'); END IF;

    -- 2. 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '해당 월이 마감되어 확정할 수 없습니다.'); END IF;

    -- 3. AP 자동 연동 (is_payable = true 일 때만)
    IF v_head.is_payable THEN
        IF v_head.vendor_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', '지급 의무가 있는 비용은 거래처(Vendor)를 지정해야 합니다.');
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
            format('판관비 자동생성 (%s)', v_head.category_name),
            auth.uid()
        );
    END IF;

    -- 4. 상태 업데이트
    UPDATE public.expense_records SET status = 'confirmed', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '비용 전표가 확정되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [4] 비용 확정 취소 RPC (unconfirm_expense_document)
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
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다 (Admin 전용)');
    END IF;

    SELECT * INTO v_head FROM public.expense_records WHERE id = p_doc_id;
    IF v_head.status != 'confirmed' THEN RETURN jsonb_build_object('success', false, 'message', '확정된 문서만 취소 가능합니다.'); END IF;

    -- 마감 확인
    SELECT EXISTS (
        SELECT 1 FROM public.monthly_closings 
        WHERE closing_year = to_char(v_head.expense_date, 'YYYY') AND closing_month = to_char(v_head.expense_date, 'MM') AND status = 'closed'
    ) INTO v_is_month_closed;
    IF v_is_month_closed THEN RETURN jsonb_build_object('success', false, 'message', '마감된 월은 확정 취소할 수 없습니다.'); END IF;

    -- 연결 AP 체크 (지급액 존재 시 차단)
    IF v_head.is_payable THEN
        SELECT id, paid_amount INTO v_ap_id, v_ap_paid 
        FROM public.accounts_payable 
        WHERE ref_type = 'EXPENSE' AND ref_id = p_doc_id AND status != 'void'
        LIMIT 1;

        IF v_ap_id IS NOT NULL AND COALESCE(v_ap_paid, 0) > 0 THEN
            RETURN jsonb_build_object('success', false, 'message', format('이미 지급 처리가 진행된 건입니다. (지급액: %s) 회계 지급 취소를 먼저 진행하세요.', v_ap_paid));
        END IF;

        IF v_ap_id IS NOT NULL THEN
            UPDATE public.accounts_payable SET status = 'void', remark = format('비용 확정 취소로 인한 취소 (%s)', p_reason) WHERE id = v_ap_id;
        END IF;
    END IF;

    -- 로그 기록 및 상태 업데이트
    UPDATE public.expense_records SET status = 'draft', updated_at = now() WHERE id = p_doc_id;

    RETURN jsonb_build_object('success', true, 'message', '비용 전표가 Draft 상태로 환원되었습니다.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- [5] P&L 요약 뷰 고도화 (판관비 집계 포함)
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
