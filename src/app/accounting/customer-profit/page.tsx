'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function CustomerProfitabilityPage() {
  const { isManager, isAdmin } = useUserRole();
  const [selectedMonth, setSelectedMonth] = useState(new Date().toISOString().substring(0, 7)); // YYYY-MM
  const [reportData, setReportData] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');

  const fetchData = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('v_customer_profitability')
      .select('*')
      .eq('yyyymm', selectedMonth);
    
    if (error) {
      alert('Failed to load profitability data: ' + error.message);
    } else {
      setReportData(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) {
      fetchData();
    }
  }, [selectedMonth, isManager, isAdmin]);

  const filteredData = useMemo(() => {
    return reportData
      .filter(d => d.customer_name.toLowerCase().includes(searchTerm.toLowerCase()))
      .sort((a, b) => b.gross_profit - a.gross_profit);
  }, [reportData, searchTerm]);

  const top5 = useMemo(() => {
    return [...reportData].sort((a, b) => b.gross_profit - a.gross_profit).slice(0, 5);
  }, [reportData]);

  const totalGrossProfit = useMemo(() => {
    return reportData.reduce((acc, cur) => acc + cur.gross_profit, 0);
  }, [reportData]);

  if (!isManager && !isAdmin) {
    return <Shell><div>준비 중이거나 권한이 없는 페이지입니다.</div></Shell>;
  }

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>거래처별 수익성 분석 (Customer Profitability)</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>
            고객사별 매출액 대비 원가 구조와 실질적인 거래처별 총이익률을 분석합니다.
          </p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <span style={{ fontWeight: '600' }}>분석 월:</span>
          <input 
            type="month" 
            className="form-control" 
            style={{ width: '180px' }}
            value={selectedMonth}
            onChange={(e) => setSelectedMonth(e.target.value)}
          />
        </div>
      </div>

      <div className="grid-cols-3" style={{ gap: '24px', marginBottom: '32px' }}>
        <div className="card" style={{ borderTop: '4px solid var(--primary)' }}>
          <h3 style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '8px' }}>선택 월 총 매출액</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold' }}>
            {reportData.reduce((acc, cur) => acc + cur.revenue, 0).toLocaleString()} <span style={{ fontSize: '14px' }}>원</span>
          </div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--success)' }}>
          <h3 style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '8px' }}>선택 월 총 이익액</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: 'var(--success)' }}>
            {totalGrossProfit.toLocaleString()} <span style={{ fontSize: '14px' }}>원</span>
          </div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--warning)' }}>
          <h3 style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '8px' }}>평균 총이익률</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold' }}>
            {(reportData.length > 0 ? (totalGrossProfit / reportData.reduce((acc, cur) => acc + cur.revenue, 1)) * 100 : 0).toFixed(1)} %
          </div>
        </div>
      </div>

      <div className="grid-cols-3" style={{ gap: '24px' }}>
        {/* Pareto Chart Section */}
        <div className="card col-span-1">
          <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '24px' }}>이익 기여도 상위 5개사</h3>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
            {top5.map((c, idx) => (
              <div key={idx}>
                <div className="flex-between mb-8" style={{ fontSize: '13px' }}>
                  <span>{c.customer_name}</span>
                  <span style={{ fontWeight: '600' }}>{((c.gross_profit / (totalGrossProfit || 1)) * 100).toFixed(1)}%</span>
                </div>
                <div style={{ height: '8px', background: '#F1F5F9', borderRadius: '4px', overflow: 'hidden' }}>
                  <div style={{ height: '100%', background: 'var(--primary)', width: `${(c.gross_profit / (top5[0].gross_profit || 1)) * 100}%` }}></div>
                </div>
              </div>
            ))}
            {top5.length === 0 && <p style={{ color: 'var(--text-muted)', textAlign: 'center' }}>데이터가 없습니다.</p>}
          </div>
        </div>

        {/* Detailed Table Section */}
        <div className="card col-span-2">
          <div className="flex-between mb-16">
            <h3 style={{ fontSize: '18px', fontWeight: 'bold' }}>거래처별 수익성 상세</h3>
            <input 
              type="text" 
              className="form-control" 
              style={{ width: '200px' }} 
              placeholder="거래처명 검색..." 
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
            />
          </div>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>거래처명</th>
                  <th style={{ textAlign: 'right' }}>매출액</th>
                  <th style={{ textAlign: 'right' }}>매출원가</th>
                  <th style={{ textAlign: 'right' }}>거래처 총이익</th>
                  <th style={{ textAlign: 'right' }}>거래처별 총이익률</th>
                </tr>
              </thead>
              <tbody>
                {filteredData.map((d, idx) => (
                  <tr key={idx}>
                    <td style={{ fontWeight: '500' }}>{d.customer_name}</td>
                    <td style={{ textAlign: 'right' }}>{d.revenue.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', color: 'var(--text-muted)' }}>{d.cogs.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', fontWeight: '600', color: 'var(--success)' }}>{d.gross_profit.toLocaleString()}</td>
                    <td style={{ textAlign: 'right' }}>
                      <span className={`badge ${d.margin_rate > 20 ? 'badge-primary' : 'badge-ghost'}`}>
                        {d.margin_rate.toFixed(1)}%
                      </span>
                    </td>
                  </tr>
                ))}
                {filteredData.length === 0 && (
                  <tr>
                    <td colSpan={5} style={{ textAlign: 'center', padding: '32px' }}>조회된 데이터가 없습니다.</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Shell>
  );
}
