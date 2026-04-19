'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';

export type UserRole = 'staff' | 'manager' | 'admin';

export function useUserRole() {
  const [role, setRole] = useState<UserRole | null>(null);
  const [userId, setUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchRole() {
      const { data: { user } } = await supabase.auth.getUser();
      
      if (!user) {
        setRole(null);
        setUserId(null);
        setLoading(false);
        return;
      }

      setUserId(user.id);

      const { data, error } = await supabase
        .from('profiles')
        .select('role')
        .eq('id', user.id)
        .single();

      if (error) {
        console.error('Error fetching role:', error);
        setRole(null);
      } else {
        setRole(data.role as UserRole);
      }
      setLoading(false);
    }

    fetchRole();
  }, []);

  return { 
    role, 
    userId,
    loading, 
    isAdmin: role === 'admin', 
    isManager: role === 'manager' || role === 'admin' 
  };
}
