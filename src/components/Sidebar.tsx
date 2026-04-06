'use client';

import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';

const menuItems = [
  { name: '대시보드', path: '/' },
  { name: '거래처 관리', path: '/customers' },
  { name: '제품 관리', path: '/products' },
  { name: '단가 관리', path: '/prices' },
  { name: '구매 입고', path: '/purchase' },
  { name: '판매 출고', path: '/sales' },
  { name: '생산 관리', path: '/production' },
  { name: '재고 현황', path: '/inventory' },
  { name: '재고 이력', path: '/inventory/history' },
];

export default function Sidebar() {
  const pathname = usePathname();
  const useRouterHook = useRouter();

  const handleLogout = async () => {
    await supabase.auth.signOut();
    useRouterHook.push('/login');
  };

  return (
    <aside className="sidebar">
      <div style={{ marginBottom: '40px', padding: '0 8px' }}>
        <h2 style={{ fontSize: '20px', fontWeight: 'bold', color: 'white' }}>Plachem ERP</h2>
        <span style={{ fontSize: '12px', opacity: 0.7 }}>v1.0.0</span>
      </div>

      <nav style={{ flex: 1 }}>
        <ul style={{ listStyle: 'none' }}>
          {menuItems.map((item) => (
            <li key={item.path} style={{ marginBottom: '4px' }}>
              <Link
                href={item.path}
                className="btn btn-ghost"
                style={{
                  width: '100%',
                  justifyContent: 'flex-start',
                  backgroundColor: pathname === item.path ? 'rgba(255, 255, 255, 0.1)' : 'transparent',
                  color: pathname === item.path ? 'white' : '#94a3b8',
                }}
              >
                {item.name}
              </Link>
            </li>
          ))}
        </ul>
      </nav>

      <div style={{ borderTop: '1px solid rgba(255, 255, 255, 0.1)', paddingTop: '16px' }}>
        <button
          onClick={handleLogout}
          className="btn btn-ghost"
          style={{ width: '100%', justifyContent: 'flex-start', color: '#ef4444' }}
        >
          로그아웃
        </button>
      </div>
    </aside>
  );
}
