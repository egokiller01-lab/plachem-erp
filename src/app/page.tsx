'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';

export default function Dashboard() {
  const [stats, setStats] = useState({
    totalSales: 0,
    lowStockItems: 0,
    recentPurchases: [] as any[],
    recentSales: [] as any[],
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchDashboardData = async () => {
      setLoading(true);
      
      // Fetch low stock items (stock < 10)
      const { data: stockData } = await supabase
        .from('v_product_stock')
        .select('*')
        .lt('stock_qty', 10)
        .limit(5);

      // Fetch recent sales headers
      const { data: salesHeaders } = await supabase
        .from('sales_headers')
        .select('*, customers(customer_name)')
        .order('sales_date', { ascending: false })
        .limit(5);

      // Fetch recent purchase headers
      const { data: purchaseHeaders } = await supabase
        .from('purchase_headers')
        .select('*, customers(customer_name)')
        .order('purchase_date', { ascending: false })
        .limit(5);

      setStats({
        totalSales: salesHeaders?.length || 0,
        lowStockItems: stockData?.length || 0,
        recentPurchases: purchaseHeaders || [],
        recentSales: salesHeaders || [],
      });
      setLoading(false);
    };

    fetchDashboardData();
  }, []);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>대시보드</h1>
        <div style={{ color: 'var(--text-muted)' }}>
          {new Date().toLocaleDateString('ko-KR', { year: 'numeric', month: 'long', day: 'numeric' })}
        </div>
      </div>

      <div className="grid-cols-2">
        <div className="card">
          <h3 style={{ fontSize: '16px', color: 'var(--text-muted)', marginBottom: '8px' }}>최근 판매 건수</h3>
          <div style={{ fontSize: '32px', fontWeight: 'bold' }}>{stats.totalSales} <span style={{ fontSize: '14px', fontWeight: 'normal' }}>건</span></div>
        </div>
        <div className="card">
          <h3 style={{ fontSize: '16px', color: 'var(--text-muted)', marginBottom: '8px' }}>재고 부족 품목</h3>
          <div style={{ fontSize: '32px', fontWeight: 'bold', color: stats.lowStockItems > 0 ? 'var(--danger)' : 'var(--success)' }}>
            {stats.lowStockItems} <span style={{ fontSize: '14px', fontWeight: 'normal' }}>개</span>
          </div>
        </div>
      </div>

      <div className="grid-cols-2 mt-24">
        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>최근 판매 현황</h3>
            <Link href="/sales" className="btn btn-ghost" style={{ fontSize: '14px' }}>더보기</Link>
          </div>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>날짜</th>
                  <th>거래처</th>
                  <th>번호</th>
                </tr>
              </thead>
              <tbody>
                {stats.recentSales.map((sale) => (
                  <tr key={sale.id}>
                    <td>{sale.sales_date}</td>
                    <td>{sale.customers?.customer_name}</td>
                    <td>{sale.sales_no}</td>
                  </tr>
                ))}
                {stats.recentSales.length === 0 && (
                  <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>데이터가 없습니다.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>최근 구매 현황</h3>
            <Link href="/purchase" className="btn btn-ghost" style={{ fontSize: '14px' }}>더보기</Link>
          </div>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>날짜</th>
                  <th>거래처</th>
                  <th>번호</th>
                </tr>
              </thead>
              <tbody>
                {stats.recentPurchases.map((purchase) => (
                  <tr key={purchase.id}>
                    <td>{purchase.purchase_date}</td>
                    <td>{purchase.customers?.customer_name}</td>
                    <td>{purchase.purchase_no}</td>
                  </tr>
                ))}
                {stats.recentPurchases.length === 0 && (
                  <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>데이터가 없습니다.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Shell>
  );
}
