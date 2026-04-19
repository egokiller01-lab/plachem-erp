-- ==========================================
-- [Phase B1] 전표 품목(Items) RLS 보안 강화
-- ==========================================

-- [1] 매입 품목 (purchase_items) RLS 설정
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "PI_Select_All" ON public.purchase_items;
DROP POLICY IF EXISTS "PI_Write_If_Draft" ON public.purchase_items;

-- 조회: 인증된 모든 사용자 허용
CREATE POLICY "PI_Select_All" ON public.purchase_items 
FOR SELECT TO authenticated 
USING ( true );

-- 추가/수정/삭제: 상위 헤더가 'draft' 상태일 때만 허용
CREATE POLICY "PI_Write_If_Draft" ON public.purchase_items 
FOR ALL TO authenticated 
USING (
  EXISTS (
    SELECT 1 FROM public.purchase_headers 
    WHERE id = purchase_items.purchase_header_id AND status = 'draft'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.purchase_headers 
    WHERE id = purchase_items.purchase_header_id AND status = 'draft'
  )
);


-- [2] 매출 품목 (sales_items) RLS 설정
ALTER TABLE public.sales_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "SI_Select_All" ON public.sales_items;
DROP POLICY IF EXISTS "SI_Write_If_Draft" ON public.sales_items;

-- 조회: 인증된 모든 사용자 허용
CREATE POLICY "SI_Select_All" ON public.sales_items 
FOR SELECT TO authenticated 
USING ( true );

-- 추가/수정/삭제: 상위 헤더가 'draft' 상태일 때만 허용
CREATE POLICY "SI_Write_If_Draft" ON public.sales_items 
FOR ALL TO authenticated 
USING (
  EXISTS (
    SELECT 1 FROM public.sales_headers 
    WHERE id = sales_items.sales_header_id AND status = 'draft'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.sales_headers 
    WHERE id = sales_items.sales_header_id AND status = 'draft'
  )
);

-- [3] 기존 Confirm RPC 영향 검토
-- confirm_purchase_document RPC는 'SECURITY DEFINER'로 작성되어 있어 RLS를 우회합니다.
-- 따라서 헤더 상태를 확정(confirmed)으로 바꾸는 과정에서 RLS 충돌이 발생하지 않습니다.
