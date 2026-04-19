'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function CreditApprovalsPage() {
  const { isAdmin } = useUserRole();
  const [requests, setRequests] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [processLoading, setProcessLoading] = useState<number | null>(null);

  const fetchRequests = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('credit_exception_requests')
      .select(`
        *,
        sales_headers ( sales_no, sales_date, total_amount, customer_id, customers ( customer_name ) )
      `)
      .order('created_at', { ascending: false });
    
    if (error) alert('실패: ' + error.message);
    else setRequests(data || []);
    setLoading(false);
  };

  useEffect(() => {
    if (isAdmin) fetchRequests();
  }, [isAdmin]);

  const handleProcess = async (id: number, action: 'approve' | 'reject') => {
    const comment = prompt(`${action === 'approve' ? '승인' : '반려'} 사유 또는 의견을 입력하세요:`, '');
    if (comment === null) return;

    setProcessLoading(id);
    const { data, error } = await supabase.rpc('manage_credit_exception', { 
      p_req_id: id, 
      p_action: action, 
      p_comment: comment 
    });

    if (error) alert('오류: ' + error.message);
    else {
      alert(data.message);
      fetchRequests();
    }
    setProcessLoading(null);
  };

  if (!isAdmin) return <Shell><div>권한이 없습니다. (Admin 전용)</div></Shell>;

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>여신 예외 승인 관리</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>한도 초과 매출 거래에 대한 예외 승인 요청을 심사합니다.</p>
        </div>
        <button className="btn btn-ghost" onClick={fetchRequests} disabled={loading}>새로고침</button>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>요청일시</th>
                <th>전표번호</th>
                <th>거래처</th>
                <th style={{ textAlign: 'right' }}>전표금액</th>
                <th>요청사유</th>
                <th>상태</th>
                <th>처리의견</th>
                <th style={{ textAlign: 'center' }}>액션</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={8} style={{ textAlign: 'center' }}>불러오는 중...</td></tr>
              ) : requests.map(req => (
                <tr key={req.id}>
                  <td style={{ fontSize: '12px' }}>{new Date(req.created_at).toLocaleString()}</td>
                  <td>{req.sales_headers?.sales_no}</td>
                  <td style={{ fontWeight: '500' }}>{req.sales_headers?.customers?.customer_name}</td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold' }}>{req.sales_headers?.total_amount.toLocaleString()}</td>
                  <td style={{ maxWidth: '200px', fontSize: '13px' }}>{req.reason}</td>
                  <td>
                    <span className={`badge ${
                      req.status === 'approved' ? 'badge-success' : 
                      req.status === 'rejected' ? 'badge-danger' : 
                      req.status === 'void' ? 'badge-ghost' : 'badge-warning'
                    }`}>
                      {req.status.toUpperCase()}
                    </span>
                  </td>
                  <td style={{ fontSize: '12px', color: 'var(--text-muted)' }}>{req.approver_comment || '-'}</td>
                  <td style={{ textAlign: 'center' }}>
                    {req.status === 'pending' && (
                      <div style={{ display: 'flex', gap: '8px', justifyContent: 'center' }}>
                        <button 
                          className="btn btn-sm btn-primary" 
                          disabled={processLoading === req.id}
                          onClick={() => handleProcess(req.id, 'approve')}
                        >승인</button>
                        <button 
                          className="btn btn-sm" 
                          style={{ borderColor: 'var(--danger)', color: 'var(--danger)' }}
                          disabled={processLoading === req.id}
                          onClick={() => handleProcess(req.id, 'reject')}
                        >반려</button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
              {requests.length === 0 && !loading && (
                <tr><td colSpan={8} style={{ textAlign: 'center', padding: '32px' }}>대기 중인 요청이 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
