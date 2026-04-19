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

-- 누구나 자신의 프로필 정보를 조회할 수 있고, manager나 admin은 모든 유저 목록을 조회할 수 있도록 허용
CREATE POLICY "Users can view own profile or managers can view all" 
ON public.profiles FOR SELECT 
USING (
  auth.uid() = id OR 
  (SELECT role FROM public.profiles WHERE id = auth.uid()) IN ('manager', 'admin')
);

-- Admin 권한을 가진 사람만 Profiles 테이블의 레코드를 수정(권한 부여 등)할 수 있음
CREATE POLICY "Admin can update profiles" 
ON public.profiles FOR UPDATE 
USING ( (SELECT role FROM public.profiles WHERE id = auth.uid()) = 'admin' );

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
