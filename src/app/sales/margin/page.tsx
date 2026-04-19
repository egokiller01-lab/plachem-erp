'use client';
export const dynamic = 'force-dynamic';

import React, { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface MarginItem {
  id: string; // surrogate key line-item
  sales_no: string;
  sales_date: string;
  customer_code: string;
  customer_name: string;
  product_code: string;
  product_name: string;
  qty: number;
  revenue: number;    // sales_items.amount
  cogs: number;       // sales_items.cogs_amount
  margin: number;     // revenue - cogs
  margin_pct: number; // (margin / revenue) * 100
  is_cogs_missing: boolean;
}

type GroupByMode = 'item' | 'document' | 'product' | 'customer' | 'month';

export default function GrossMarginAnalysisPage() {
  const [data, setData] = useState<MarginItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');
  
  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [startDate, setStartDate] = useState('');
  const [endDate, setEndDate] = useState('');
  const [groupBy, setGroupBy] = useState<GroupByMode>('item');

  const fetchData = async () => {
    setLoading(true);
    setErrorMsg('');

    let query = supabase
      .from('sales_items')
      .select(`
        id, qty, amount, cogs_amount,
        products ( product_code, product_name ),
        sales_headers!inner ( sales_no, sales_date, status, customers ( id, name ) )
      `)
      .eq('sales_headers.status', 'confirmed')
      .order('sales_headers(sales_date)', { ascending: false });

    if (startDate) {
      query = query.gte('sales_headers.sales_date', startDate);
    }
    if (endDate) {
      query = query.lte('sales_headers.sales_date', endDate);
    }

    const { data: items, error } = await query;

    if (error) {
      console.error(error);
      setErrorMsg('Failed to load gross margin data.');
    } else {
      const mapped: MarginItem[] = (items || []).map((item: any) => {
        const rev = Number(item.amount) || 0;
        const cogsAmount = Number(item.cogs_amount) || 0;
        const isMissing = cogsAmount === 0 && rev > 0;
        const margin = rev - cogsAmount;
        const marginPct = rev > 0 ? (margin / rev) * 100 : 0;
        // Mock customer code using ID temporarily, as customer_code might not exist in the basic schema,
        // but we'll adapt to customer name primarily for UI display.
        const custName = item.sales_headers?.customers?.name || '';
        const custCode = `C${item.sales_headers?.customers?.id || '?'}`;

        return {
          id: item.id,
          sales_no: item.sales_headers?.sales_no || '',
          sales_date: item.sales_headers?.sales_date || '',
          customer_code: custCode,
          customer_name: custName,
          product_code: item.products?.product_code || '',
          product_name: item.products?.product_name || '',
          qty: Number(item.qty) || 0,
          revenue: rev,
          cogs: cogsAmount,
          margin: margin,
          margin_pct: marginPct,
          is_cogs_missing: isMissing
        };
      });
      // Sort by sales_date (desc), sales_no (desc)
      mapped.sort((a, b) => {
        if (a.sales_date !== b.sales_date) return a.sales_date < b.sales_date ? 1 : -1;
        return a.sales_no < b.sales_no ? 1 : -1;
      });
      setData(mapped);
    }
    
    setLoading(false);
  };

  useEffect(() => {
    const now = new Date();
    const firstDay = new Date(now.getFullYear(), now.getMonth(), 1);
    const lastDay = new Date(now.getFullYear(), now.getMonth() + 1, 0);
    // local string correction avoiding timezone offset issues
    const yyyy = firstDay.getFullYear();
    const mm = String(firstDay.getMonth() + 1).padStart(2, '0');
    const l_dd = String(lastDay.getDate()).padStart(2, '0');

    setStartDate(`${yyyy}-${mm}-01`);
    setEndDate(`${yyyy}-${mm}-${l_dd}`);
  }, []);

  useEffect(() => {
    if (startDate && endDate) {
      fetchData();
    }
  }, [startDate, endDate]);

  const searchLower = searchQuery.toLowerCase();
  const searchFiltered = data.filter(d => 
    d.sales_no.toLowerCase().includes(searchLower) ||
    d.customer_name.toLowerCase().includes(searchLower) ||
    d.product_name.toLowerCase().includes(searchLower) ||
    d.product_code.toLowerCase().includes(searchLower)
  );

  // GROUPING LOGIC
  let groupedData = searchFiltered;
  if (groupBy !== 'item') {
    const map = new Map<string, any>();
    searchFiltered.forEach(d => {
      let key = '';
      let label = '';
      if (groupBy === 'document') {
        key = d.sales_no; label = `${d.sales_date} | ${d.sales_no} | ${d.customer_name}`;
      } else if (groupBy === 'product') {
        key = d.product_code; label = `[${d.product_code}] ${d.product_name}`;
      } else if (groupBy === 'customer') {
        key = d.customer_name; label = `[${d.customer_code}] ${d.customer_name}`;
      } else if (groupBy === 'month') {
        key = d.sales_date.substring(0, 7); label = key;
      }

      if (!map.has(key)) {
        map.set(key, { key, label, qty: 0, revenue: 0, cogs: 0, missing_cogs_flag: false });
      }
      const agg = map.get(key);
      agg.qty += d.qty;
      agg.revenue += d.revenue;
      agg.cogs += d.cogs;
      if (d.is_cogs_missing) agg.missing_cogs_flag = true;
    });

    groupedData = Array.from(map.values()).map(agg => {
      const m = agg.revenue - agg.cogs;
      return {
        id: agg.key,
        sales_date: groupBy === 'month' ? agg.key : '-',
        sales_no: groupBy === 'document' ? agg.key : '-',
        customer_name: groupBy === 'customer' ? agg.key : '-',
        product_code: groupBy === 'product' ? agg.key : '-',
        product_name: agg.label, // use as general label column for UI fallback
        qty: agg.qty,
        revenue: agg.revenue,
        cogs: agg.cogs,
        margin: m,
        margin_pct: agg.revenue > 0 ? (m / agg.revenue) * 100 : 0,
        is_cogs_missing: agg.missing_cogs_flag
      } as MarginItem;
    });
    // Sort logic for grouped
    if (groupBy === 'month') groupedData.sort((a,b) => b.product_name.localeCompare(a.product_name));
    else groupedData.sort((a,b) => a.product_name.localeCompare(b.product_name));
  }

  const tRevenue = searchFiltered.reduce((acc, curr) => acc + curr.revenue, 0);
  const tCogs = searchFiltered.reduce((acc, curr) => acc + curr.cogs, 0);
  const tMargin = tRevenue - tCogs;
  const tMarginPct = tRevenue > 0 ? (tMargin / tRevenue) * 100 : 0;

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Gross Margin Analysis</h1>
      </div>

      <div className="card mb-24" style={{ display: 'flex', flexWrap: 'wrap', gap: '16px', alignItems: 'center' }}>
        <div>
          <label className="form-label" style={{ fontSize: '12px', marginBottom: '4px' }}>Start Date</label>
          <input type="date" className="form-control" value={startDate} onChange={e => setStartDate(e.target.value)} />
        </div>
        <div>
          <label className="form-label" style={{ fontSize: '12px', marginBottom: '4px' }}>End Date</label>
          <input type="date" className="form-control" value={endDate} onChange={e => setEndDate(e.target.value)} />
        </div>
        <div>
          <label className="form-label" style={{ fontSize: '12px', marginBottom: '4px' }}>Group By</label>
          <select className="form-control" value={groupBy} onChange={e => setGroupBy(e.target.value as GroupByMode)}>
            <option value="item">Line Items (문서 상세별)</option>
            <option value="document">Document (문서 단위별)</option>
            <option value="product">Product (제품별)</option>
            <option value="customer">Customer (고객별)</option>
            <option value="month">Month (월별)</option>
          </select>
        </div>
        <div style={{ marginTop: '22px' }}>
          <button className="btn btn-primary" onClick={fetchData}>Refresh</button>
        </div>
        <div style={{ marginTop: '22px', marginLeft: 'auto' }}>
          <input 
            type="text" 
            placeholder="Search invoice, customer, product..." 
            className="form-control"
            style={{ minWidth: '250px' }}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        </div>
      </div>

      {errorMsg && <div className="mb-24" style={{ color: 'red' }}>{errorMsg}</div>}

      <div className="grid-cols-4 mb-24">
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total Sales Amount</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#2b6cb0' }}>
            VND {tRevenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}
          </div>
        </div>
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total COGS</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#c53030' }}>
            VND {tCogs.toLocaleString(undefined, { maximumFractionDigits: 0 })}
          </div>
        </div>
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Total Gross Profit</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: tMargin >= 0 ? '#2f855a' : '#c53030' }}>
            VND {tMargin.toLocaleString(undefined, { maximumFractionDigits: 0 })}
          </div>
        </div>
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#666' }}>Avg Margin Rate</div>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: tMarginPct >= 0 ? '#2f855a' : '#c53030' }}>
            {tMarginPct.toLocaleString(undefined, { maximumFractionDigits: 2 })} %
          </div>
        </div>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              {groupBy === 'item' ? (
                <tr>
                  <th>Date</th>
                  <th>Sales No</th>
                  <th>Customer</th>
                  <th>Product</th>
                  <th style={{ textAlign: 'right' }}>Qty</th>
                  <th style={{ textAlign: 'right' }}>Revenue</th>
                  <th style={{ textAlign: 'right' }}>COGS</th>
                  <th style={{ textAlign: 'right' }}>Margin</th>
                  <th style={{ textAlign: 'right' }}>Margin %</th>
                </tr>
              ) : (
                <tr>
                  <th>Group Name ({groupBy.toUpperCase()})</th>
                  <th style={{ textAlign: 'right' }}>Total Qty</th>
                  <th style={{ textAlign: 'right' }}>Total Revenue</th>
                  <th style={{ textAlign: 'right' }}>Total COGS</th>
                  <th style={{ textAlign: 'right' }}>Total Margin</th>
                  <th style={{ textAlign: 'right' }}>Avg Margin %</th>
                </tr>
              )}
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={9} style={{ textAlign: 'center' }}>Loading margin analysis...</td></tr>
              ) : groupedData.length === 0 ? (
                <tr><td colSpan={9} style={{ textAlign: 'center' }}>No confirmed sales data found matching criteria.</td></tr>
              ) : groupBy === 'item' ? (
                groupedData.map((item) => (
                  <tr key={item.id} style={{ backgroundColor: item.is_cogs_missing ? '#fff5f5' : 'transparent' }}>
                    <td>{item.sales_date}</td>
                    <td>{item.sales_no}</td>
                    <td>{item.customer_name}</td>
                    <td>[{item.product_code}] {item.product_name}</td>
                    <td style={{ textAlign: 'right' }}>{item.qty.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', color: '#2b6cb0' }}>{item.revenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    <td style={{ textAlign: 'right', color: item.is_cogs_missing ? 'red' : '#c53030' }}>
                      {item.is_cogs_missing && <span style={{ marginRight: '8px', fontSize: '11px', color: 'red', fontWeight:'bold' }}>[N/A]</span>}
                      {item.cogs.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                    </td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', color: item.margin >= 0 ? '#2f855a' : '#c53030' }}>
                      {item.margin.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                    </td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', color: item.margin_pct >= 0 ? '#2f855a' : '#c53030' }}>
                      {item.margin_pct.toLocaleString(undefined, { maximumFractionDigits: 1 })}%
                    </td>
                  </tr>
                ))
              ) : (
                groupedData.map((agg) => (
                  <tr key={agg.id} style={{ backgroundColor: agg.is_cogs_missing ? '#fff5f5' : 'transparent' }}>
                    <td>{agg.product_name} {agg.is_cogs_missing && <span style={{ marginLeft: '8px', fontSize: '12px', color: 'red', fontWeight:'bold' }}>*Missing COGS detected</span>}</td>
                    <td style={{ textAlign: 'right' }}>{agg.qty.toLocaleString()}</td>
                    <td style={{ textAlign: 'right', color: '#2b6cb0' }}>{agg.revenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    <td style={{ textAlign: 'right', color: '#c53030' }}>{agg.cogs.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', color: agg.margin >= 0 ? '#2f855a' : '#c53030' }}>
                      {agg.margin.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                    </td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', color: agg.margin_pct >= 0 ? '#2f855a' : '#c53030' }}>
                      {agg.margin_pct.toLocaleString(undefined, { maximumFractionDigits: 1 })}%
                    </td>
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
