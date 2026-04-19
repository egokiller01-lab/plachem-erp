'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function DailyCashReportPage() {
  const { isManager, isAdmin } = useUserRole();
  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().split('T')[0]);
  const [reportData, setReportData] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const fetchReport = async (date: string) => {
    setLoading(true);
    const { data, error } = await supabase.rpc('get_daily_cash_report', { p_date: date });
    if (error) {
      alert('Failed to load report: ' + error.message);
    } else if (data && data.success) {
      setReportData(data);
    } else {
      alert('Report data error: ' + (data?.message || 'Unknown error'));
    }
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) {
      fetchReport(selectedDate);
    }
  }, [selectedDate, isManager, isAdmin]);

  if (!isManager && !isAdmin) {
    return <Shell><div>준비 중이거나 권한이 없는 페이지입니다.</div></Shell>;
  }

  const renderComparison = (today: number, prev: number) => {
    const diff = today - prev;
    if (diff === 0) return <span style={{ fontSize: '12px', color: 'var(--text-muted)' }}>(전일 동일)</span>;
    return (
      <span style={{ fontSize: '12px', color: diff > 0 ? 'var(--primary)' : 'var(--danger)' }}>
        ({diff > 0 ? '+' : ''}{diff.toLocaleString()} {diff > 0 ? '↑' : '↓'})
      </span>
    );
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>일일 자금 보고서 (Daily Activity)</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>
            * 본 보고서는 ERP 내 전표 활동(입출금 및 채권/채무 변동)을 기반으로 합니다. (은행 실잔액 아님)
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <span style={{ fontWeight: '600' }}>보고서 일자:</span>
          <input 
            type="date" 
            className="form-control" 
            style={{ width: '180px' }}
            value={selectedDate}
            onChange={(e) => setSelectedDate(e.target.value)}
          />
        </div>
      </div>

      {loading && <div>보고서를 집계 중입니다...</div>}

      {reportData && !loading && (
        <>
          <div className="grid-cols-5" style={{ gap: '16px' }}>
            {[
              { label: '오늘 입금', key: 'receipt', color: 'var(--primary)' },
              { label: '오늘 출금', key: 'payment', color: 'var(--danger)' },
              { label: '순자금 흐름', key: 'net_flow', color: 'var(--success)' },
              { label: '미수금 순증감', key: 'ar_change', color: '#0369A1' },
              { label: '미지급금 순증감', key: 'ap_change', color: '#BE123C' },
            ].map(item => (
              <div key={item.key} className="card" style={{ borderTop: `4px solid ${item.color}` }}>
                <h3 style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '8px' }}>{item.label}</h3>
                <div style={{ fontSize: '20px', fontWeight: 'bold', marginBottom: '4px' }}>
                  {reportData.summary[item.key].today.toLocaleString()} <span style={{ fontSize: '12px' }}>원</span>
                </div>
                {renderComparison(reportData.summary[item.key].today, reportData.summary[item.key].prev)}
              </div>
            ))}
          </div>

          <div className="grid-cols-2 mt-24" style={{ gap: '24px' }}>
            <div className="card">
              <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px', color: 'var(--primary)' }}>오늘의 입금 상세</h3>
              <div className="data-table-container">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>거래처</th>
                      <th style={{ textAlign: 'right' }}>금액</th>
                      <th>수단</th>
                    </tr>
                  </thead>
                  <tbody>
                    {reportData.details.receipts.map((r: any, idx: number) => (
                      <tr key={idx}>
                        <td>{r.customer_name}</td>
                        <td style={{ textAlign: 'right', fontWeight: 'bold' }}>{r.amount.toLocaleString()}</td>
                        <td><span className="badge badge-secondary">{r.payment_method}</span></td>
                      </tr>
                    ))}
                    {reportData.details.receipts.length === 0 && (
                      <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>입금 내역이 없습니다.</td></tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>

            <div className="card">
              <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px', color: 'var(--danger)' }}>오늘의 출금 상세</h3>
              <div className="data-table-container">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>거래처</th>
                      <th style={{ textAlign: 'right' }}>금액</th>
                      <th>수단</th>
                    </tr>
                  </thead>
                  <tbody>
                    {reportData.details.payments.map((p: any, idx: number) => (
                      <tr key={idx}>
                        <td>{p.customer_name}</td>
                        <td style={{ textAlign: 'right', fontWeight: 'bold' }}>{p.amount.toLocaleString()}</td>
                        <td><span className="badge badge-ghost">{p.payment_method}</span></td>
                      </tr>
                    ))}
                    {reportData.details.payments.length === 0 && (
                      <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>출금 내역이 없습니다.</td></tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div className="card mt-24" style={{ backgroundColor: '#fff5f5' }}>
            <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px', color: '#c53030' }}>⚠️ 연체 관리 브리핑 (Overdue Top 5)</h3>
            <div className="grid-cols-2" style={{ gap: '20px' }}>
              <div>
                <h4 style={{ fontSize: '14px', fontWeight: '600', marginBottom: '12px' }}>미수금 주요 연체 (AR)</h4>
                {reportData.overdue.ar.map((item: any, idx: number) => (
                  <div key={idx} style={{ padding: '10px 0', borderBottom: '1px solid #fed7d7', display: 'flex', justifyContent: 'space-between', fontSize: '13px' }}>
                    <span>{item.customer_name}</span>
                    <span style={{ fontWeight: 'bold' }}>{item.balance.toLocaleString()}원 <br/>
                      <span style={{ fontSize: '11px', color: '#9b2c2c', fontWeight: 'normal' }}>기한: {item.due_date}</span>
                    </span>
                  </div>
                ))}
              </div>
              <div>
                <h4 style={{ fontSize: '14px', fontWeight: '600', marginBottom: '12px' }}>지급 주요 연체 (AP)</h4>
                {reportData.overdue.ap.map((item: any, idx: number) => (
                  <div key={idx} style={{ padding: '10px 0', borderBottom: '1px solid #fed7d7', display: 'flex', justifyContent: 'space-between', fontSize: '13px' }}>
                    <span>{item.customer_name}</span>
                    <span style={{ fontWeight: 'bold' }}>{item.balance.toLocaleString()}원 <br/>
                      <span style={{ fontSize: '11px', color: '#9b2c2c', fontWeight: 'normal' }}>기한: {item.due_date}</span>
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </>
      )}
    </Shell>
  );
}
