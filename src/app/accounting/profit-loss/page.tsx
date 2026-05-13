'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function ProfitLossPage() {
  const { isManager, isAdmin } = useUserRole();
  const [selectedMonth, setSelectedMonth] = useState(new Date().toISOString().substring(0, 7)); // YYYY-MM
  const [summaryData, setSummaryData] = useState<any[]>([]);
  const [productProfit, setProductProfit] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState('');

  const fetchData = async () => {
    setLoading(true);
    setErrorMessage('');

    // 1. Fetch Monthly Summaries (for Trend)
    const { data: summary, error: summaryError } = await supabase.from('v_profit_loss_summary').select('*').order('yyyymm', { ascending: true });
    if (summaryError) {
      console.error('Failed to fetch profit/loss summary:', summaryError);
      setErrorMessage(`손익 요약 데이터를 불러오지 못했습니다: ${summaryError.message}`);
    }
    setSummaryData(summary || []);

    // 2. Fetch Product Profitability (Filtered by some logic or total)
    const { data: products, error: productsError } = await supabase.from('v_product_profitability').select('*').order('gross_profit', { ascending: false });
    if (productsError) {
      console.error('Failed to fetch product profitability:', productsError);
      setErrorMessage(prev => [prev, `제품별 수익성 데이터를 불러오지 못했습니다: ${productsError.message}`].filter(Boolean).join('\n'));
    }
    setProductProfit(products || []);
    
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) {
      fetchData();
    }
  }, [isManager, isAdmin]);

  const currentMonthData = useMemo(() => {
    return summaryData.find(d => d.yyyymm === selectedMonth) || {
      revenue: 0, cogs: 0, gross_profit: 0, subcon_cost: 0, operational_gross_profit: 0, sga_cost: 0, operating_income: 0
    };
  }, [summaryData, selectedMonth]);

  if (!isManager && !isAdmin) {
    return <Shell><div>준비 중이거나 권한이 없는 페이지입니다.</div></Shell>;
  }

  // Simple CSS Chart logic
  const maxRevenue = Math.max(...summaryData.map(d => d.revenue), 1);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <div>
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>손익 분석 (Profit & Loss)</h1>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginTop: '4px' }}>
            매출, 원가, 판관비를 통합한 전사 수익 분석 (부가세 제외)
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

      {errorMessage && (
        <div className="alert alert-danger mb-24" style={{ whiteSpace: 'pre-wrap' }}>{errorMessage}</div>
      )}

      <div className="grid-cols-6" style={{ gap: '12px', marginBottom: '32px' }}>
        <div className="card" style={{ borderTop: '4px solid var(--primary)', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>매출액</h3>
          <div style={{ fontSize: '18px', fontWeight: 'bold' }}>{currentMonthData.revenue.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid #64748B', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>매출원가</h3>
          <div style={{ fontSize: '18px', fontWeight: 'bold' }}>{currentMonthData.cogs.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--success)', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>매출총이익</h3>
          <div style={{ fontSize: '18px', fontWeight: 'bold', color: 'var(--success)' }}>{currentMonthData.gross_profit.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid var(--danger)', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>외주생산비</h3>
          <div style={{ fontSize: '18px', fontWeight: 'bold', color: 'var(--danger)' }}>{currentMonthData.subcon_cost.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid #F59E0B', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '8px' }}>일반 판관비</h3>
          <div style={{ fontSize: '18px', fontWeight: 'bold', color: '#F59E0B' }}>{currentMonthData.sga_cost.toLocaleString()}원</div>
        </div>
        <div className="card" style={{ borderTop: '4px solid #7C3AED', backgroundColor: '#F5F3FF', padding: '16px' }}>
          <h3 style={{ fontSize: '12px', color: '#6D28D9', marginBottom: '8px', fontWeight: '600' }}>영업이익*</h3>
          <div style={{ fontSize: '18px', fontWeight: '900', color: '#7C3AED' }}>{currentMonthData.operating_income.toLocaleString()}원</div>
          <div style={{ fontSize: '10px', color: '#8B5CF6', marginTop: '4px' }}>
            이익률: {currentMonthData.revenue > 0 ? ((currentMonthData.operating_income / currentMonthData.revenue) * 100).toFixed(1) : 0}%
          </div>
        </div>
      </div>

      <div className="grid-cols-2" style={{ gap: '24px' }}>
        {/* Trend Section */}
        <div className="card">
          <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '24px' }}>월별 손익 추이</h3>
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: '16px', height: '240px', paddingBottom: '30px', borderBottom: '1px solid #E2E8F0' }}>
            {summaryData.slice(-6).map((d: any, idx: number) => (
              <div key={idx} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '4px', height: '100%' }}>
                <div style={{ display: 'flex', alignItems: 'flex-end', gap: '2px', height: '100%', width: '100%' }}>
                  <div style={{ flex: 1, background: 'var(--primary)', height: `${(d.revenue / maxRevenue) * 100}%`, borderRadius: '2px 2px 0 0' }} title={`매출: ${d.revenue.toLocaleString()}`}></div>
                  <div style={{ flex: 1, background: 'var(--success)', height: `${(d.gross_profit / maxRevenue) * 100}%`, borderRadius: '2px 2px 0 0' }} title={`이익: ${d.gross_profit.toLocaleString()}`}></div>
                </div>
                <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '8px' }}>{d.yyyymm}</div>
              </div>
            ))}
          </div>
          <div style={{ display: 'flex', gap: '16px', marginTop: '20px', fontSize: '12px', justifyContent: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}><div style={{ width: '10px', height: '10px', background: 'var(--primary)' }}></div> 매출</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}><div style={{ width: '10px', height: '10px', background: 'var(--success)' }}></div> 매출총이익</div>
          </div>
        </div>

        {/* Product Profitability Section */}
        <div className="card">
          <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '24px' }}>제품별 수익성 랭킹 (누계)</h3>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>제품명</th>
                  <th style={{ textAlign: 'right' }}>매출액</th>
                  <th style={{ textAlign: 'right' }}>총이익</th>
                  <th style={{ textAlign: 'right' }}>이익률</th>
                </tr>
              </thead>
              <tbody>
                {productProfit.slice(0, 10).map((p: any, idx: number) => (
                  <tr key={idx}>
                    <td style={{ fontSize: '13px' }}>{p.product_name}</td>
                    <td style={{ textAlign: 'right', fontSize: '13px' }}>{p.revenue.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', fontWeight: '600', color: 'var(--success)', fontSize: '13px' }}>{p.gross_profit.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', fontSize: '13px' }}>
                      <span className={`badge ${p.margin_rate > 20 ? 'badge-primary' : 'badge-ghost'}`}>
                        {p.margin_rate.toFixed(1)}%
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div className="mt-24 alert alert-info" style={{ fontSize: '13px' }}>
        💡 <b>영업이익*</b>은 매출총이익에서 외주비 및 시스템에 입력된 일반 판관비를 차감한 수치입니다. (비현금성 비용 등 미입력 비용은 제외됨)
      </div>
    </Shell>
  );
}
