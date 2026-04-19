'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function AgingReportPage() {
  const { isManager, isAdmin } = useUserRole();
  const [type, setType] = useState<'AR' | 'AP'>('AR');
  const [data, setData] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const fetchAgingData = async () => {
    setLoading(true);
    const { data: report, error } = await supabase.rpc('get_aging_report', { p_type: type });
    if (error) alert('데이터 로드 실패: ' + error.message);
    else setData(report || []);
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) fetchAgingData();
  }, [type, isManager, isAdmin]);

  if (!isManager && !isAdmin) return <Shell><div>권한이 없는 페이지입니다. (Manager 이상 권한 필요)</div></Shell>;

  const totals = data.reduce((acc, cur) => ({
    total: acc.total + cur.total_balance,
    normal: acc.normal + cur.bucket_normal,
    pending: acc.pending + cur.bucket_pending,
    b30: acc.b30 + cur.bucket_30,
    b60: acc.b60 + cur.bucket_60,
    b90: acc.b90 + cur.bucket_90,
    bOver90: acc.bOver90 + cur.bucket_over_90,
  }), { total: 0, normal: 0, pending: 0, b30: 0, b60: 0, b90: 0, bOver90: 0 });

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>{type === 'AR' ? '채권' : '채무'} 에이징 분석 (Aging Analysis)</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>지급기한 경과 기간별 잔액 분석 및 리스크 모니터링 (오늘 기준)</p>
        </div>
        <div className="flex-start" style={{ gap: '8px', background: '#F1F5F9', padding: '4px', borderRadius: '8px' }}>
          <button 
            className={`btn btn-sm ${type === 'AR' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setType('AR')}
          >미수금 (AR)</button>
          <button 
            className={`btn btn-sm ${type === 'AP' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setType('AP')}
          >미지급금 (AP)</button>
        </div>
      </div>

      {/* Summary Cards */}
      <div className="grid-cols-4" style={{ gap: '16px', marginBottom: '32px' }}>
        <div className="card" style={{ borderTop: '4px solid #64748B' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>총 잔액</h3>
          <div style={{ fontSize: '20px', fontWeight: 'bold' }}>{totals.total.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--success)' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>정상 (미연체)</h3>
          <div style={{ fontSize: '20px', fontWeight: 'bold', color: 'var(--success)' }}>{totals.normal.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid #F59E0B' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>단기 연체 (30일내)</h3>
          <div style={{ fontSize: '20px', fontWeight: 'bold', color: '#F59E0B' }}>{totals.b30.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--danger)' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>장기 연체 (90일초과)</h3>
          <div style={{ fontSize: '20px', fontWeight: 'bold', color: 'var(--danger)' }}>{totals.bOver90.toLocaleString()}원</div>
        </div>
      </div>

      {/* Visual Bar Section */}
      <div className="card mb-32">
        <h3 style={{ fontSize: '16px', fontWeight: 'bold', marginBottom: '16px' }}>구간별 구성 비중</h3>
        <div style={{ height: '40px', width: '100%', display: 'flex', borderRadius: '8px', overflow: 'hidden' }}>
          <div style={{ flex: totals.normal, background: 'var(--success)', height: '100%' }} title="정상"></div>
          <div style={{ flex: totals.pending, background: '#E2E8F0', height: '100%' }} title="미분류"></div>
          <div style={{ flex: totals.b30, background: '#FDE68A', height: '100%' }} title="1-30일"></div>
          <div style={{ flex: totals.b60, background: '#FBCFE8', height: '100%' }} title="31-60일"></div>
          <div style={{ flex: totals.b90, background: '#FECACA', height: '100%' }} title="61-90일"></div>
          <div style={{ flex: totals.bOver90, background: 'var(--danger)', height: '100%' }} title="90일초과"></div>
        </div>
        <div className="flex-start" style={{ gap: '16px', marginTop: '12px', fontSize: '11px', color: 'var(--text-muted)' }}>
          <div className="flex-start" style={{ gap: '4px' }}><div style={{ width: '8px', height: '8px', background: 'var(--success)' }}></div> 정상</div>
          <div className="flex-start" style={{ gap: '4px' }}><div style={{ width: '8px', height: '8px', background: '#E2E8F0' }}></div> 미분류</div>
          <div className="flex-start" style={{ gap: '4px' }}><div style={{ width: '8px', height: '8px', background: '#FDE68A' }}></div> 30일내</div>
          <div className="flex-start" style={{ gap: '4px' }}><div style={{ width: '8px', height: '8px', background: 'var(--danger)' }}></div> 90일초과</div>
        </div>
      </div>

      {/* Detailed Table */}
      <div className="card">
        <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px' }}>거래처별 상세 에이징 현황</h3>
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>거래처명</th>
                <th style={{ textAlign: 'right' }}>총 잔액</th>
                <th style={{ textAlign: 'right' }}>정상</th>
                <th style={{ textAlign: 'right' }}>미분류</th>
                <th style={{ textAlign: 'right' }}>~30일</th>
                <th style={{ textAlign: 'right' }}>~60일</th>
                <th style={{ textAlign: 'right' }}>~90일</th>
                <th style={{ textAlign: 'right' }}>90일+</th>
              </tr>
            </thead>
            <tbody>
              {data.map(row => (
                <tr key={row.customer_id}>
                  <td style={{ fontWeight: '500' }}>{row.customer_name}</td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold' }}>{row.total_balance.toLocaleString()}</td>
                  <td style={{ textAlign: 'right', color: 'var(--success)' }}>{row.bucket_normal.toLocaleString()}</td>
                  <td style={{ textAlign: 'right', color: '#94A3B8' }}>{row.bucket_pending.toLocaleString()}</td>
                  <td style={{ textAlign: 'right' }}>{row.bucket_30.toLocaleString()}</td>
                  <td style={{ textAlign: 'right' }}>{row.bucket_60.toLocaleString()}</td>
                  <td style={{ textAlign: 'right' }}>{row.bucket_90.toLocaleString()}</td>
                  <td style={{ textAlign: 'right', color: 'var(--danger)', fontWeight: '600' }}>{row.bucket_over_90.toLocaleString()}</td>
                </tr>
              ))}
              {data.length === 0 && <tr><td colSpan={8} style={{ textAlign: 'center', padding: '32px' }}>조회된 데이터가 없습니다.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
