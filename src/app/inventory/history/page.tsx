'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface Transaction {
  id: string;
  txn_date: string;
  txn_type: string;
  product_code: string;
  qty_in: number;
  qty_out: number;
  ref_table: string;
  ref_id: string;
  remark: string;
  products?: { product_name: string };
}

const txnTypeLabels: Record<string, string> = {
  'PURCHASE': 'Purchase',
  'SALES': 'Sales',
  'PROD_INPUT': 'Production Input',
  'PROD_OUTPUT': 'Production Output',
};

export default function InventoryHistoryPage() {
  const [history, setHistory] = useState<Transaction[]>([]);
  const [loading, setLoading] = useState(true);
  const [startDate, setStartDate] = useState(new Date(new Date().setDate(new Date().getDate() - 30)).toISOString().split('T')[0]);
  const [endDate, setEndDate] = useState(new Date().toISOString().split('T')[0]);
  const [filterType, setFilterType] = useState('all');

  const fetchHistory = async () => {
    setLoading(true);
    let query = supabase
      .from('inventory_transactions')
      .select('*, products(product_name)')
      .gte('txn_date', startDate)
      .lte('txn_date', endDate)
      .order('txn_date', { ascending: false });

    if (filterType !== 'all') {
      query = query.eq('txn_type', filterType);
    }

    const { data } = await query;
    setHistory(data || []);
    setLoading(false);
  };

  useEffect(() => {
    fetchHistory();
  }, [startDate, endDate, filterType]);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Inventory History</h1>
        <button className="btn btn-ghost" onClick={fetchHistory}>Search</button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
            <input 
              type="date" 
              className="form-control" 
              value={startDate} 
              onChange={(e) => setStartDate(e.target.value)} 
            />
            <span>~</span>
            <input 
              type="date" 
              className="form-control" 
              value={endDate} 
              onChange={(e) => setEndDate(e.target.value)} 
            />
          </div>
          <div style={{ display: 'flex', gap: '8px' }}>
            <select 
              className="form-control" 
              style={{ width: 'auto' }}
              value={filterType}
              onChange={(e) => setFilterType(e.target.value)}
            >
              <option value="all">All Transaction Types</option>
              {Object.entries(txnTypeLabels).map(([val, label]) => (
                <option key={val} value={val}>{label}</option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>Date</th>
                <th>Type</th>
                <th>Product Name (Code)</th>
                <th style={{ textAlign: 'right' }}>In (+)</th>
                <th style={{ textAlign: 'right' }}>Out (-)</th>
                <th>Ref</th>
                <th>Remark</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : history.map((item) => (
                <tr key={item.id}>
                  <td>{item.txn_date}</td>
                  <td>
                    <span className={`badge ${['PURCHASE', 'PROD_OUTPUT'].includes(item.txn_type) ? 'badge-success' : 'badge-danger'}`}>
                      {txnTypeLabels[item.txn_type] || item.txn_type}
                    </span>
                  </td>
                  <td>{item.products?.product_name} ({item.product_code})</td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold', color: 'var(--success)' }}>
                    {item.qty_in > 0 ? `+${item.qty_in.toLocaleString()}` : ''}
                  </td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold', color: 'var(--danger)' }}>
                    {item.qty_out > 0 ? `-${item.qty_out.toLocaleString()}` : ''}
                  </td>
                  <td style={{ fontSize: '12px', color: 'var(--text-muted)' }}>
                    {item.ref_table} ({item.ref_id})
                  </td>
                  <td>{item.remark}</td>
                </tr>
              ))}
              {history.length === 0 && !loading && (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>No history data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
