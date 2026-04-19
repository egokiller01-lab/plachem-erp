'use client';
export const dynamic = 'force-dynamic';

import React, { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

type ViewMode = 'monthly' | 'current';

interface ClosingHeader {
  id: number;
  closing_year: string;
  closing_month: string;
}

interface MonthlyValuationItem {
  closing_id: number;
  closing_year: string;
  closing_month: string;
  product_code: string;
  product_name: string;
  opening_qty: number;
  in_qty: number;
  out_qty: number;
  ending_qty: number;
  ending_mac: number;
  ending_value: number;
}

interface CurrentValuationItem {
  product_code: string;
  product_name: string;
  stock_qty: number;
  moving_avg_cost: number;
  stock_value: number;
}

export default function ValuationReportPage() {
  const [mode, setMode] = useState<ViewMode>('monthly');
  const [searchQuery, setSearchQuery] = useState('');
  
  // Monthly State
  const [closings, setClosings] = useState<ClosingHeader[]>([]);
  const [selectedClosingId, setSelectedClosingId] = useState<number | ''>('');
  const [monthlyData, setMonthlyData] = useState<MonthlyValuationItem[]>([]);
  
  // Current State
  const [currentData, setCurrentData] = useState<CurrentValuationItem[]>([]);
  
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  // 1. Fetch Available Closings
  const fetchClosings = async () => {
    const { data, error } = await supabase
      .from('monthly_closings')
      .select('id, closing_year, closing_month')
      .eq('status', 'closed')
      .order('closing_year', { ascending: false })
      .order('closing_month', { ascending: false });

    if (error) {
      console.error(error);
      return;
    }
    
    setClosings(data || []);
    if (data && data.length > 0) {
      setSelectedClosingId(data[0].id);
    }
  };

  useEffect(() => {
    fetchClosings();
  }, []);

  // 2. Fetch Report Data
  const fetchData = async () => {
    setLoading(true);
    setErrorMsg('');

    if (mode === 'monthly') {
      if (!selectedClosingId) {
        setMonthlyData([]);
        setLoading(false);
        return;
      }
      
      const { data: items, error } = await supabase
        .from('monthly_closing_items')
        .select(`
          opening_qty, in_qty, out_qty, ending_qty, ending_mac, ending_value,
          monthly_closings ( closing_year, closing_month ),
          products ( product_code, product_name )
        `)
        .eq('closing_id', selectedClosingId);

      if (error) {
        setErrorMsg('Failed to load monthly valuation');
        console.error(error);
      } else {
        const mapped: MonthlyValuationItem[] = (items || []).map(item => ({
          closing_id: Number(selectedClosingId),
          closing_year: (item.monthly_closings as any)?.closing_year || '',
          closing_month: (item.monthly_closings as any)?.closing_month || '',
          product_code: (item.products as any)?.product_code || '',
          product_name: (item.products as any)?.product_name || '',
          opening_qty: Number(item.opening_qty) || 0,
          in_qty: Number(item.in_qty) || 0,
          out_qty: Number(item.out_qty) || 0,
          ending_qty: Number(item.ending_qty) || 0,
          ending_mac: Number(item.ending_mac) || 0,
          ending_value: Number(item.ending_value) || 0,
        }));
        setMonthlyData(mapped);
      }
    } else {
      // Current Mode
      const { data: productsData, error: pErr } = await supabase
        .from('products')
        .select('product_code, product_name, moving_avg_cost');
        
      const { data: stockData, error: sErr } = await supabase
        .from('v_product_stock')
        .select('product_code, stock_qty');

      if (pErr || sErr) {
        setErrorMsg('Failed to load current valuation');
      } else {
        const pList = productsData || [];
        const sList = stockData || [];
        
        const mapped: CurrentValuationItem[] = pList.map(p => {
          const qty = sList.find(s => s.product_code === p.product_code)?.stock_qty || 0;
          const mapCost = Number(p.moving_avg_cost) || 0;
          return {
            product_code: p.product_code,
            product_name: p.product_name,
            stock_qty: qty,
            moving_avg_cost: mapCost,
            stock_value: qty * mapCost,
          };
        });
        setCurrentData(mapped);
      }
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchData();
  }, [mode, selectedClosingId]);

  // 3. Filtering & Summaries
  const searchLower = searchQuery.toLowerCase();

  if (mode === 'monthly') {
    const filtered = monthlyData.filter(d => 
      d.product_name.toLowerCase().includes(searchLower) ||
      d.product_code.toLowerCase().includes(searchLower)
    ).sort((a, b) => a.product_code.localeCompare(b.product_code));

    const tsn = filtered.length;
    const tQty = filtered.reduce((acc, curr) => acc + curr.ending_qty, 0);
    const tVal = filtered.reduce((acc, curr) => acc + curr.ending_value, 0);

    return (
      <Shell>
        <div className="flex-between mb-24">
          <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Inventory Valuation Report</h1>
        </div>

        <div className="card mb-24 flex-between" style={{ gap: '16px' }}>
          <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
            <select className="form-control" value={mode} onChange={(e) => setMode(e.target.value as ViewMode)} style={{ width: '200px' }}>
              <option value="monthly">월말 마감 기준 (회계보고용)</option>
              <option value="current">현재 실시간 기준 (운영참고용)</option>
            </select>

            <select 
              className="form-control" 
              value={selectedClosingId} 
              onChange={e => setSelectedClosingId(e.target.value ? Number(e.target.value) : '')}
              style={{ width: '200px' }}
            >
              <option value="">-- 마감 월 선택 --</option>
              {closings.map(c => (
                <option key={c.id} value={c.id}>{c.closing_year}-{c.closing_month}</option>
              ))}
            </select>
          </div>

          <input 
            type="text" 
            placeholder="Search by Product Name or Code..." 
            className="form-control"
            style={{ maxWidth: '300px' }}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        </div>

        {errorMsg && <div className="mb-24" style={{ color: 'red' }}>{errorMsg}</div>}

        <div className="grid-cols-3 mb-24">
          <div className="card" style={{ textAlign: 'center' }}>
            <div style={{ fontSize: '14px', color: '#666' }}>Total Items</div>
            <div style={{ fontSize: '24px', fontWeight: 'bold' }}>{tsn.toLocaleString()}</div>
          </div>
          <div className="card" style={{ textAlign: 'center' }}>
            <div style={{ fontSize: '14px', color: '#666' }}>Total Ending Qty</div>
            <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#2b6cb0' }}>{tQty.toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
          </div>
          <div className="card" style={{ textAlign: 'center' }}>
            <div style={{ fontSize: '14px', color: '#666' }}>Total Inventory Value</div>
            <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#c53030' }}>
              VND {tVal.toLocaleString(undefined, { maximumFractionDigits: 0 })}
            </div>
          </div>
        </div>

        <div className="card">
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Period</th>
                  <th>Code</th>
                  <th>Product Name</th>
                  <th style={{ textAlign: 'right' }}>Opening</th>
                  <th style={{ textAlign: 'right' }}>IN</th>
                  <th style={{ textAlign: 'right' }}>OUT</th>
                  <th style={{ textAlign: 'right', fontWeight: 'bold' }}>Ending Qty</th>
                  <th style={{ textAlign: 'right' }}>Ending MAC</th>
                  <th style={{ textAlign: 'right', fontWeight: 'bold' }}>Ending Value</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <tr><td colSpan={9} style={{ textAlign: 'center' }}>Loading valuation records...</td></tr>
                ) : filtered.length === 0 ? (
                  <tr><td colSpan={9} style={{ textAlign: 'center' }}>No closed valuation data found or matching your search.</td></tr>
                ) : (
                  filtered.map((item, idx) => (
                    <tr key={idx}>
                      <td>{item.closing_year}-{item.closing_month}</td>
                      <td>{item.product_code}</td>
                      <td>{item.product_name}</td>
                      <td style={{ textAlign: 'right' }}>{item.opening_qty.toLocaleString()}</td>
                      <td style={{ textAlign: 'right' }}>{item.in_qty.toLocaleString()}</td>
                      <td style={{ textAlign: 'right' }}>{item.out_qty.toLocaleString()}</td>
                      <td style={{ textAlign: 'right', fontWeight: 'bold', color: '#2b6cb0' }}>{item.ending_qty.toLocaleString()}</td>
                      <td style={{ textAlign: 'right' }}>{item.ending_mac.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                      <td style={{ textAlign: 'right', fontWeight: 'bold', color: '#c53030' }}>{item.ending_value.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      </Shell>
    );
  }

  // mode === 'current'
  const filtered = currentData.filter(d => 
    d.product_name.toLowerCase().includes(searchLower) ||
    d.product_code.toLowerCase().includes(searchLower)
  ).sort((a, b) => a.product_code.localeCompare(b.product_code));

  const tsn = filtered.length;
  const tQty = filtered.reduce((acc, curr) => acc + curr.stock_qty, 0);
  const tVal = filtered.reduce((acc, curr) => acc + curr.stock_value, 0);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Inventory Valuation Report</h1>
      </div>

      <div className="card mb-24 flex-between" style={{ gap: '16px' }}>
        <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
          <select className="form-control" value={mode} onChange={(e) => setMode(e.target.value as ViewMode)} style={{ width: '200px' }}>
            <option value="monthly">월말 마감 기준 (회계보고용)</option>
            <option value="current">현재 실시간 기준 (운영참고용)</option>
          </select>
        </div>

        <input 
          type="text" 
          placeholder="Search by Product Name or Code..." 
          className="form-control"
          style={{ maxWidth: '300px' }}
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />
      </div>

      {errorMsg && <div className="mb-24" style={{ color: 'red' }}>{errorMsg}</div>}

      <div className="grid-cols-3 mb-24">
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total Items</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold' }}>{tsn.toLocaleString()}</div>
        </div>
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total Current Stock</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#2b6cb0' }}>{tQty.toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
        </div>
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total Current Value</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#c53030' }}>
            VND {tVal.toLocaleString(undefined, { maximumFractionDigits: 0 })}
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
                <th style={{ textAlign: 'right' }}>Stock Qty</th>
                <th style={{ textAlign: 'right' }}>Current MAC</th>
                <th style={{ textAlign: 'right', fontWeight: 'bold' }}>Stock Value</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={5} style={{ textAlign: 'center' }}>Loading current stock...</td></tr>
              ) : filtered.length === 0 ? (
                <tr><td colSpan={5} style={{ textAlign: 'center' }}>No products match your search.</td></tr>
              ) : (
                filtered.map((item, idx) => (
                  <tr key={idx}>
                    <td>{item.product_code}</td>
                    <td>{item.product_name}</td>
                    <td style={{ textAlign: 'right', color: '#2b6cb0' }}>{item.stock_qty.toLocaleString()}</td>
                    <td style={{ textAlign: 'right' }}>{item.moving_avg_cost.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', color: '#c53030' }}>{item.stock_value.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
