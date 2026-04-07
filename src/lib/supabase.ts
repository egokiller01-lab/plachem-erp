import { createClient } from '@supabase/supabase-js'

// 오타가 수정된 정확한 주소 적용 (mgnqqkibo)
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://djkgbchzlmymgnqqkibo.supabase.co';
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRqa2diY2h6bG15bWducXFraWJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MjE1NTQsImV4cCI6MjA5MDk5NzU1NH0.XSTbWWpJBUYlL6Ht9BghgnrWWBY03jzXhMT7BaaZ8M4';

export const supabase = createClient(supabaseUrl, supabaseAnonKey)
