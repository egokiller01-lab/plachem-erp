'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function CashTrendReportPage() {
  const { isManager, isAdmin } = useUserRole();
  const [reportType, setReportType] = useState<'weekly' | 'monthly'>('monthly');
  const [reportData, setReportData] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const fetchTrendData = async (type: string) => {
    setLoading(true);
    const rpcType = type === 'monthly' ? 'month' : 'week';
    const { data, error } = await supabase.rpc('get_cash_trend_report', { p_type: rpcType, p_limit: 8 });
    if (error) {
      alert('Failed to load trend data: ' + error.message);
    } else if (data && data.success) {
      setReportData(data);
    }
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) {
      fetchTrendData(reportType);
    }
  }, [reportType, isManager, isAdmin]);

  const maxVal = useMemo(() => {
    if (!reportData?.trend) return 0;
    return Math.max(...reportData.trend.map((d: any) => Math.max(d.receipt, d.payment, d.new_ar, d.new_ap)));
  }, [reportData]);

  if (!isManager && !isAdmin) {
    return <Shell><div>준비 중이거나 권한이 없는 페이지입니다.</div></Shell>;
  }

  const renderKPI = (title: string, current: number, prev: number, isGoodIfIncr: boolean = true) => {
    const diff = current - (prev || 0);
    const percent = prev ? (diff / prev) * 100 : 0;
    const isUp = diff > 0;
    const isPositiveChange = isGoodIfIncr ? isUp : !isUp;

    return (
      <div className="card">
        <h3 style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '8px' }}>{title}</h3>
        <div style={{ fontSize: '20px', fontWeight: 'bold', marginBottom: '4px' }}>
          {current.toLocaleString()} <span style={{ fontSize: '12px' }}>원</span>
        </div>
        <div style={{ fontSize: '12px', color: diff === 0 ? 'var(--text-muted)' : (isPositiveChange ? 'var(--primary)' : 'var(--danger)') }}>
          {diff === 0 ? '전기 동일' : `${isUp ? '▲' : '▼'} ${percent.toFixed(1)}% (${diff.toLocaleString()})`}
        </div>
      </div>
    );
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>자금 흐름 추세 분석 (Trend Analysis)</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>
            거시적 관점의 주간/월간 자금 수지 및 채권 변동 추이를 분석합니다.
          </p>
        </div>
        <div style={{ display: 'flex', background: '#F1F5F9', padding: '4px', borderRadius: '8px' }}>
          <button 
            className={`btn btn-sm ${reportType === 'weekly' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setReportType('weekly')}
          >주간</button>
          <button 
            className={`btn btn-sm ${reportType === 'monthly' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setReportType('monthly')}
          >월간</button>
        </div>
      </div>

      {loading && <div>데이터를 분석 중입니다...</div>}

      {reportData && !loading && (
        <>
          <div className="grid-cols-4" style={{ gap: '16px', marginBottom: '24px' }}>
            {renderKPI('기간 총 입금', reportData.summary.current?.receipt || 0, reportData.summary.prev?.receipt || 0)}
            {renderKPI('기간 총 출금', reportData.summary.current?.payment || 0, reportData.summary.prev?.payment || 0, false)}
            {renderKPI('순자금 흐름', reportData.summary.current?.net_flow || 0, reportData.summary.prev?.net_flow || 0)}
            {renderKPI('신규 발생 채권(AR)', reportData.summary.current?.new_ar || 0, reportData.summary.prev?.new_ar || 0)}
          </div>

          <div className="grid-cols-2" style={{ gap: '24px' }}>
            {/* Cash Flow Chart */}
            <div className="card">
              <h3 style={{ fontSize: '16px', fontWeight: 'bold', marginBottom: '24px' }}>자금 유입 vs 유출 추이</h3>
              <div style={{ display: 'flex', alignItems: 'flex-end', gap: '12px', height: '200px', paddingBottom: '20px', borderBottom: '1px solid #E2E8F0' }}>
                {reportData.trend.map((d: any, idx: number) => (
                  <div key={idx} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '4px' }}>
                    <div style={{ display: 'flex', alignItems: 'flex-end', gap: '2px', height: '100%', width: '100%' }}>
                      <div style={{ flex: 1, background: 'var(--primary)', height: `${(d.receipt / (maxVal || 1)) * 100}%`, borderRadius: '2px 2px 0 0' }} title={`수금: ${d.receipt.toLocaleString()}`}></div>
                      <div style={{ flex: 1, background: 'var(--danger)', height: `${(d.payment / (maxVal || 1)) * 100}%`, borderRadius: '2px 2px 0 0' }} title={`지급: ${d.payment.toLocaleString()}`}></div>
                    </div>
                    <div style={{ fontSize: '10px', color: 'var(--text-muted)', whiteSpace: 'nowrap', transform: 'rotate(-45deg)', marginTop: '8px' }}>
                      {d.period_start.substring(5)}
                    </div>
                  </div>
                ))}
              </div>
              <div style={{ display: 'flex', gap: '16px', marginTop: '24px', fontSize: '12px', justifyContent: 'center' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                  <div style={{ width: '12px', height: '12px', background: 'var(--primary)', borderRadius: '2px' }}></div> 수금(Receipt)
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                  <div style={{ width: '12px', height: '12px', background: 'var(--danger)', borderRadius: '2px' }}></div> 지급(Payment)
                </div>
              </div>
            </div>

            {/* AR/AP New Trend Chart */}
            <div className="card">
              <h3 style={{ fontSize: '16px', fontWeight: 'bold', marginBottom: '24px' }}>신규 채권/채무 발생 추이</h3>
              <div style={{ display: 'flex', alignItems: 'flex-end', gap: '12px', height: '200px', paddingBottom: '20px', borderBottom: '1px solid #E2E8F0' }}>
                {reportData.trend.map((d: any, idx: number) => (
                  <div key={idx} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '4px' }}>
                    <div style={{ display: 'flex', alignItems: 'flex-end', gap: '2px', height: '100%', width: '100%' }}>
                      <div style={{ flex: 1, background: '#0369A1', height: `${(d.new_ar / (maxVal || 1)) * 100}%`, opacity: 0.7, borderRadius: '2px 2px 0 0' }} title={`신규AR: ${d.new_ar.toLocaleString()}`}></div>
                      <div style={{ flex: 1, background: '#BE123C', height: `${(d.new_ap / (maxVal || 1)) * 100}%`, opacity: 0.7, borderRadius: '2px 2px 0 0' }} title={`신규AP: ${d.new_ap.toLocaleString()}`}></div>
                    </div>
                    <div style={{ fontSize: '10px', color: 'var(--text-muted)', whiteSpace: 'nowrap', transform: 'rotate(-45deg)', marginTop: '8px' }}>
                      {d.period_start.substring(5)}
                    </div>
                  </div>
                ))}
              </div>
              <div style={{ display: 'flex', gap: '16px', marginTop: '24px', fontSize: '12px', justifyContent: 'center' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                  <div style={{ width: '12px', height: '12px', background: '#0369A1', opacity: 0.7, borderRadius: '2px' }}></div> 신규 매출(AR)
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                  <div style={{ width: '12px', height: '12px', background: '#BE123C', opacity: 0.7, borderRadius: '2px' }}></div> 신규 매입(AP)
                </div>
              </div>
            </div>
          </div>

          <div className="card mt-24">
            <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px' }}>기간별 요약 데이터 (Raw Data)</h3>
            <div className="data-table-container">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>시작일</th>
                    <th style={{ textAlign: 'right' }}>수금</th>
                    <th style={{ textAlign: 'right' }}>지급</th>
                    <th style={{ textAlign: 'right' }}>Net Flow</th>
                    <th style={{ textAlign: 'right' }}>신규 AR</th>
                    <th style={{ textAlign: 'right' }}>신규 AP</th>
                  </tr>
                </thead>
                <tbody>
                  {[...reportData.trend].reverse().map((d: any, idx: number) => (
                    <tr key={idx} style={{ backgroundColor: d.period_start === reportData.summary.current?.period_start ? '#F8FAFC' : 'transparent' }}>
                      <td style={{ fontWeight: d.period_start === reportData.summary.current?.period_start ? 'bold' : 'normal' }}>
                        {d.period_start} {d.period_start === reportData.summary.current?.period_start && '(현재)'}
                      </td>
                      <td style={{ textAlign: 'right' }}>{d.receipt.toLocaleString()}</td>
                      <td style={{ textAlign: 'right' }}>{d.payment.toLocaleString()}</td>
                      <td style={{ textAlign: 'right', color: d.net_flow >= 0 ? 'var(--primary)' : 'var(--danger)', fontWeight: '600' }}>
                        {d.net_flow.toLocaleString()}
                      </td>
                      <td style={{ textAlign: 'right' }}>{d.new_ar.toLocaleString()}</td>
                      <td style={{ textAlign: 'right' }}>{d.new_ap.toLocaleString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </Shell>
  );
}
