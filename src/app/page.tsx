'use client';
/* Force redeploy */
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';
import { useUserRole } from '@/hooks/useUserRole';

export default function Dashboard() {
  const { isManager, isAdmin } = useUserRole();
  const [stats, setStats] = useState({
    totalSales: 0,
    lowStockItems: 0,
    recentPurchases: [] as any[],
    recentSales: [] as any[],
    accounting: { total_receivable: 0, total_payable: 0 },
    overdueAR: [] as any[],
    overdueAP: [] as any[],
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

      // Fetch Accounting Summary (Manager only)
      let accounting = { total_receivable: 0, total_payable: 0 };
      let overdueAR = [];
      let overdueAP = [];

      if (isManager || isAdmin) {
        const { data: accData } = await supabase.from('v_accounting_summary').select('*').single();
        if (accData) accounting = accData;

        const { data: oAR } = await supabase.from('accounts_receivable').select('*, customers(customer_name)').neq('status', 'paid').neq('status', 'void').lt('due_date', new Date().toISOString().split('T')[0]).limit(3);
        const { data: oAP } = await supabase.from('accounts_payable').select('*, customers(customer_name)').neq('status', 'paid').neq('status', 'void').lt('due_date', new Date().toISOString().split('T')[0]).limit(3);
        overdueAR = oAR || [];
        overdueAP = oAP || [];
      }

      setStats({
        totalSales: salesHeaders?.length || 0,
        lowStockItems: stockData?.length || 0,
        recentPurchases: purchaseHeaders || [],
        recentSales: salesHeaders || [],
        accounting,
        overdueAR,
        overdueAP,
      });
      setLoading(false);
    };

    fetchDashboardData();
  }, [isManager, isAdmin]);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Dashboard</h1>
        <div style={{ color: 'var(--text-muted)' }}>
          {new Date().toLocaleDateString('ko-KR', { year: 'numeric', month: 'long', day: 'numeric' })}
        </div>
      </div>

      <div className="grid-cols-4" style={{ gap: '16px' }}>
        <div className="card">
          <h3 style={{ fontSize: '14px', color: 'var(--text-muted)', marginBottom: '8px' }}>Total Sales (Count)</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold' }}>{stats.totalSales} <span style={{ fontSize: '12px', fontWeight: 'normal' }}>txs</span></div>
        </div>
        <div className="card">
          <h3 style={{ fontSize: '14px', color: 'var(--text-muted)', marginBottom: '8px' }}>Low Stock</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: stats.lowStockItems > 0 ? 'var(--danger)' : 'var(--success)' }}>
            {stats.lowStockItems} <span style={{ fontSize: '12px', fontWeight: 'normal' }}>items</span>
          </div>
        </div>
        {(isManager || isAdmin) && (
          <>
            <div className="card">
              <h3 style={{ fontSize: '14px', color: 'var(--text-muted)', marginBottom: '8px' }}>총 미수금 (AR)</h3>
              <div style={{ fontSize: '24px', fontWeight: 'bold', color: 'var(--primary)' }}>
                {stats.accounting.total_receivable.toLocaleString()} <span style={{ fontSize: '12px', fontWeight: 'normal' }}>원</span>
              </div>
            </div>
            <div className="card">
              <h3 style={{ fontSize: '14px', color: 'var(--text-muted)', marginBottom: '8px' }}>총 미지급금 (AP)</h3>
              <div style={{ fontSize: '24px', fontWeight: 'bold', color: 'var(--danger)' }}>
                {stats.accounting.total_payable.toLocaleString()} <span style={{ fontSize: '12px', fontWeight: 'normal' }}>원</span>
              </div>
            </div>
          </>
        )}
      </div>

      {(isManager || isAdmin) && (stats.overdueAR.length > 0 || stats.overdueAP.length > 0) && (
        <div className="card mt-24" style={{ backgroundColor: '#fff5f5', borderColor: '#feb2b2' }}>
          <h3 style={{ fontSize: '16px', fontWeight: 'bold', color: '#c53030', marginBottom: '16px', display: 'flex', alignItems: 'center', gap: '8px' }}>
            ⚠️ 연체 관리 필요 (Overdue Alerts)
          </h3>
          <div className="grid-cols-2" style={{ gap: '20px' }}>
            <div>
              <h4 style={{ fontSize: '13px', color: '#9b2c2c', marginBottom: '8px' }}>미수급 연체 (AR Overdue)</h4>
              {stats.overdueAR.map(item => (
                <div key={item.id} style={{ fontSize: '12px', padding: '6px 0', borderBottom: '1px solid #fed7d7', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{item.customers?.customer_name}</span>
                  <span style={{ fontWeight: 'bold' }}>{(item.total_amount - item.received_amount).toLocaleString()}원</span>
                </div>
              ))}
            </div>
            <div>
              <h4 style={{ fontSize: '13px', color: '#9b2c2c', marginBottom: '8px' }}>지급 연체 (AP Overdue)</h4>
              {stats.overdueAP.map(item => (
                <div key={item.id} style={{ fontSize: '12px', padding: '6px 0', borderBottom: '1px solid #fed7d7', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{item.customers?.customer_name}</span>
                  <span style={{ fontWeight: 'bold' }}>{(item.total_amount - item.paid_amount).toLocaleString()}원</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      <div className="grid-cols-2 mt-24">
        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>Recent Sales</h3>
            <Link href="/sales" className="btn btn-ghost" style={{ fontSize: '14px' }}>View More</Link>
          </div>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Customer</th>
                  <th>Ref No</th>
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
                  <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>No data available.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>Recent Purchases</h3>
            <Link href="/purchase" className="btn btn-ghost" style={{ fontSize: '14px' }}>View More</Link>
          </div>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Supplier</th>
                  <th>Ref No</th>
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
                  <tr><td colSpan={3} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>No data available.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Shell>
  );
}
