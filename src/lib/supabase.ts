import { createClient } from '@supabase/supabase-js'

// 디버깅을 위해 주소와 키를 직접 입력합니다. (성공 확인 후 다시 환경변수로 돌릴 예정)
const supabaseUrl = 'https://djkgbchzlmyngnqqkibo.supabase.co';
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRqa2diY2h6bG15bWducXFraWJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MjE1NTQsImV4cCI6MjA5MDk5NzU1NH0.XSTbWWpJBUYlL6Ht9BghgnrWWBY03jzXhMT7BaaZ8M4';

export const supabase = createClient(supabaseUrl, supabaseAnonKey)
