'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

interface Closing {
  id: number;
  closing_year: string;
  closing_month: string;
  status: 'draft' | 'closed';
  closed_at?: string;
}

export default function ClosingManagementPage() {
  const { isAdmin, loading: roleLoading } = useUserRole();
  const [closings, setClosings] = useState<Closing[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchClosings = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('monthly_closings')
      .select('*')
      .order('closing_year', { ascending: false })
      .order('closing_month', { ascending: false });
    
    if (error) {
      alert('마감 데이터를 불러오지 못했습니다.');
    } else {
      setClosings(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchClosings();
  }, []);

  const handleReopen = async (closing: Closing) => {
    const reason = prompt(`${closing.closing_year}-${closing.closing_month} 마감을 취소하시겠습니까?\n취소 사유를 입력해주세요 (필수):`);
    if (!reason) return alert('사유를 입력해야 취소가 가능합니다.');

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();
    const { data, error } = await supabase.rpc('reopen_monthly_closing', {
      p_year: closing.closing_year,
      p_month: closing.closing_month,
      p_reason: reason,
      p_user_uuid: userData.user?.id
    });

    if (error) {
      alert('System error: ' + error.message);
    } else if (data?.success) {
      alert(data.message);
      fetchClosings();
    } else {
      alert('Reopen 실패: ' + (data?.message || '권한이 없거나 처리할 수 없는 상태입니다.'));
    }
    setLoading(false);
  };

  if (roleLoading || loading) return <Shell><div>로딩 중...</div></Shell>;
  if (!isAdmin) return <Shell><div>권한이 없습니다. 관리자만 접근 가능합니다.</div></Shell>;

  // 직전 마감 월 판별 로직 (가장 최근의 'closed' 상태인 월)
  const lastClosedId = closings.find(c => c.status === 'closed')?.id;

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Monthly Closing Management</h1>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>Year-Month</th>
                <th>Status</th>
                <th>Closed At</th>
                <th style={{ textAlign: 'center' }}>Action</th>
              </tr>
            </thead>
            <tbody>
              {closings.map((c) => (
                <tr key={c.id}>
                  <td style={{ fontWeight: 'bold' }}>{c.closing_year}-{c.closing_month}</td>
                  <td>
                    <span className={`badge ${c.status === 'closed' ? 'badge-success' : 'badge-warning'}`}>
                      {c.status.toUpperCase()}
                    </span>
                  </td>
                  <td>{c.closed_at ? new Date(c.closed_at).toLocaleString() : '-'}</td>
                  <td style={{ textAlign: 'center' }}>
                    {c.status === 'closed' && c.id === lastClosedId && (
                      <button 
                        className="btn btn-ghost" 
                        style={{ color: 'var(--danger)', border: '1px solid var(--danger)', padding: '4px 12px' }}
                        onClick={() => handleReopen(c)}
                        disabled={loading}
                      >
                        Reopen
                      </button>
                    )}
                    {c.status === 'closed' && c.id !== lastClosedId && (
                      <span style={{ fontSize: '12px', color: 'var(--text-muted)' }}>Locked (Not latest)</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
      
      <div style={{ marginTop: '20px', color: 'var(--text-muted)', fontSize: '14px' }}>
        <p>※ **Reopen**은 가장 최근에 마감된 월에 대해서만 가능합니다.</p>
        <p>※ 마감 취소 시 관련 이력 로그가 생성되며 감사의 근거로 활용됩니다.</p>
      </div>
    </Shell>
  );
}
