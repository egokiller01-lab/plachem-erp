'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface StockItem {
  product_code: string;
  product_name: string;
  spec: string;
  unit: string;
  package: string;
  product_type: string;
  stock_qty: number;
}

const productTypeLabels: Record<string, string> = {
  raw_material: 'Raw Material',
  sub_material: 'Sub Material',
  finished_goods: 'Finished Goods',
  trading_goods: 'Trading Goods',
};

export default function InventoryStatusPage() {
  const [stock, setStock] = useState<StockItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [filterType, setFilterType] = useState('all');

  const fetchStock = async () => {
    setLoading(true);
    const { data } = await supabase
      .from('v_product_stock')
      .select('*')
      .order('product_code');
    setStock(data || []);
    setLoading(false);
  };

  useEffect(() => {
    fetchStock();
  }, []);

  const filteredStock = stock.filter(item => {
    const matchesSearch = item.product_name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                          item.product_code.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesType = filterType === 'all' || item.product_type === filterType;
    return matchesSearch && matchesType;
  });

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Inventory Status</h1>
        <button className="btn btn-ghost" onClick={fetchStock}>Refresh</button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <input 
            type="text" 
            placeholder="Search product name or code..." 
            className="form-control"
            style={{ maxWidth: '300px' }}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
          <div style={{ display: 'flex', gap: '8px' }}>
            <select 
              className="form-control" 
              style={{ width: 'auto' }}
              value={filterType}
              onChange={(e) => setFilterType(e.target.value)}
            >
              <option value="all">All Types</option>
              {Object.entries(productTypeLabels).map(([val, label]) => (
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
                <th>Code</th>
                <th>Product Name</th>
                <th>Type</th>
                <th>Spec / Package</th>
                <th style={{ textAlign: 'right' }}>Stock Qty</th>
                <th>Unit</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : filteredStock.map((item) => (
                <tr key={item.product_code}>
                  <td>{item.product_code}</td>
                  <td>{item.product_name}</td>
                  <td>{productTypeLabels[item.product_type] || item.product_type}</td>
                  <td>{item.spec} / {item.package}</td>
                  <td style={{ 
                    textAlign: 'right', 
                    fontWeight: 'bold',
                    color: item.stock_qty <= 0 ? 'var(--danger)' : (item.stock_qty < 10 ? 'var(--warning)' : 'inherit')
                  }}>
                    {item.stock_qty.toLocaleString()}
                  </td>
                  <td>{item.unit}</td>
                </tr>
              ))}
              {filteredStock.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No results found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
