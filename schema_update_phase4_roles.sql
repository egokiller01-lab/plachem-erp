-- ==========================================
-- [Phase A] Profiles 기반 사용자 계정 권한 동기화
-- ==========================================

-- 1. Profiles 테이블 신설
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  role text NOT NULL DEFAULT 'staff' CHECK (role IN ('staff', 'manager', 'admin')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  PRIMARY KEY (id)
);

-- Profiles 테이블에 대한 RLS 켜기
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- 0. 관리자 권한 확인 함수 생성
CREATE OR REPLACE FUNCTION public.auth_is_admin()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    -- SECURITY DEFINER는 실행 시 RLS를 우회하여 재귀 루프를 방지합니다.
    RETURN EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin'
    );
END;
$function$;

-- 1. 구 정책 삭제
DROP POLICY IF EXISTS "Users can view own profile or managers can view all" ON public.profiles;
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admin can update profiles" ON public.profiles;

-- 2. 정규 정책 삭제 (멱등성)
DROP POLICY IF EXISTS "rls_erp_profiles_select_self" ON public.profiles;
DROP POLICY IF EXISTS "rls_erp_profiles_select_admin" ON public.profiles;
DROP POLICY IF EXISTS "rls_erp_profiles_update_admin" ON public.profiles;

-- 3. 최종 정책 생성
CREATE POLICY "rls_erp_profiles_select_self"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "rls_erp_profiles_select_admin"
  ON public.profiles FOR SELECT
  USING (public.auth_is_admin());

CREATE POLICY "rls_erp_profiles_update_admin"
  ON public.profiles FOR UPDATE
  USING (public.auth_is_admin())
  WITH CHECK (public.auth_is_admin());

-- 2. 새 유저 가입 시 자동 동기화 트리거 함수
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role)
  VALUES (NEW.id, NEW.email, 'staff');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 구버전 트리거 찌꺼기 제거 후 생성
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 3. 이전에 가입해 둔 (auth.users) 기존 사용자들을 강제로 staff로 일괄 편입 (Backfill)
INSERT INTO public.profiles (id, email, role)
SELECT id, email, 'staff'
FROM auth.users
WHERE NOT EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.users.id);
