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
      <div style={{ marginBottom: '48px', padding: '0 12px' }}>
        <div style={{
          display: 'flex',
          alignItems: 'center',
          gap: '12px',
          marginBottom: '4px'
        }}>
          <div style={{
            width: '32px',
            height: '32px',
            borderRadius: '8px',
            background: 'linear-gradient(135deg, #4F46E5, #818CF8)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: 'white',
            fontWeight: 'bold',
            fontSize: '18px'
          }}>
            P
          </div>
          <h2 style={{ 
            fontSize: '22px', 
            fontWeight: '800', 
            background: 'linear-gradient(to right, #ffffff, #94A3B8)',
            WebkitBackgroundClip: 'text',
            WebkitTextFillColor: 'transparent',
            letterSpacing: '-0.02em'
          }}>
            Plachem
          </h2>
        </div>
        <span style={{ fontSize: '13px', color: '#64748B', fontWeight: '500', marginLeft: '44px' }}>ERP System v1.1.0</span>
      </div>

      <nav style={{ flex: 1 }}>
        <ul style={{ listStyle: 'none' }}>
          {menuItems.map((item) => {
            const isActive = pathname === item.path;
            return (
              <li key={item.path} style={{ marginBottom: '6px' }}>
                <Link
                  href={item.path}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    width: '100%',
                    padding: '12px 16px',
                    borderRadius: '12px',
                    fontWeight: isActive ? '600' : '500',
                    fontSize: '15px',
                    color: isActive ? '#FFFFFF' : '#94A3B8',
                    backgroundColor: isActive ? 'var(--primary)' : 'transparent',
                    boxShadow: isActive ? '0 4px 12px rgba(79, 70, 229, 0.4)' : 'none',
                    transition: 'all 0.2s ease',
                  }}
                  onMouseEnter={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.backgroundColor = 'var(--sidebar-active)';
                      e.currentTarget.style.color = '#F8FAFC';
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.backgroundColor = 'transparent';
                      e.currentTarget.style.color = '#94A3B8';
                    }
                  }}
                >
                  {item.name}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      <div style={{ 
        borderTop: '1px solid rgba(255, 255, 255, 0.08)', 
        paddingTop: '24px',
        marginTop: '24px'
      }}>
        <button
          onClick={handleLogout}
          style={{ 
            width: '100%', 
            padding: '12px 16px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'flex-start', 
            color: '#FCA5A5',
            backgroundColor: 'transparent',
            border: 'none',
            borderRadius: '12px',
            fontSize: '15px',
            fontWeight: '500',
            cursor: 'pointer',
            transition: 'all 0.2s ease'
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = 'rgba(239, 68, 68, 0.1)';
            e.currentTarget.style.color = '#EF4444';
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.backgroundColor = 'transparent';
            e.currentTarget.style.color = '#FCA5A5';
          }}
        >
          로그아웃
        </button>
      </div>
    </aside>
  );
}
