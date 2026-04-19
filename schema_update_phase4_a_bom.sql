-- ==========================================
-- [Phase 4-A] BOM(Bill of Materials) Schema & Security
-- ==========================================

-- [1] BOM 헤더 테이블 (BOM_HEADERS)
CREATE TABLE IF NOT EXISTS public.bom_headers (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    product_id bigint NOT NULL REFERENCES public.products(id),
    bom_no varchar(50) NOT NULL,
    version int NOT NULL DEFAULT 1,
    is_active boolean NOT NULL DEFAULT false,
    remark text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by uuid REFERENCES auth.users(id)
);

-- 인덱스: 제품당 하나의 활성(is_active) BOM만 존재하도록 보장
CREATE UNIQUE INDEX IF NOT EXISTS idx_bom_active_per_product 
ON public.bom_headers (product_id) 
WHERE (is_active = true);

-- [2] BOM 아이템 테이블 (BOM_ITEMS)
CREATE TABLE IF NOT EXISTS public.bom_items (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    bom_header_id bigint NOT NULL REFERENCES public.bom_headers(id) ON DELETE CASCADE,
    component_product_id bigint NOT NULL REFERENCES public.products(id),
    standard_qty numeric NOT NULL DEFAULT 0,
    remark text
);

-- [3] 기존 생산 헤더 테이블 확장
ALTER TABLE public.production_headers 
ADD COLUMN IF NOT EXISTS bom_id bigint REFERENCES public.bom_headers(id);

-- [4] RLS 보안 정책 설정

-- RLS 활성화
ALTER TABLE public.bom_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bom_items ENABLE ROW LEVEL SECURITY;

-- (1) 조회 권한: Staff 이상 모든 인증된 사용자 조회 가능
CREATE POLICY "Everyone authenticated can view BOMs" 
ON public.bom_headers FOR SELECT 
USING ( auth.role() = 'authenticated' );

CREATE POLICY "Everyone authenticated can view BOM items" 
ON public.bom_items FOR SELECT 
USING ( auth.role() = 'authenticated' );

-- (2) 관리 권한: Admin, Manager만 등록/수정/삭제 가능
-- bom_headers 관리
CREATE POLICY "Admins and Managers can manage BOM headers" 
ON public.bom_headers FOR ALL
USING (
  (SELECT role FROM public.profiles WHERE id = auth.uid()) IN ('admin', 'manager')
);

-- bom_items 관리 (헤더 권한과 동기화)
CREATE POLICY "Admins and Managers can manage BOM items" 
ON public.bom_items FOR ALL
USING (
  (SELECT role FROM public.profiles WHERE id = auth.uid()) IN ('admin', 'manager')
);

-- [5] 데이터 상시 업데이트 트리거 (updated_at)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER trg_bom_headers_updated_at
BEFORE UPDATE ON public.bom_headers
FOR EACH ROW EXECUTE PROCEDURE public.update_updated_at_column();
