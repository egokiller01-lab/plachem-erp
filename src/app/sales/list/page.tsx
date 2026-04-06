'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';

interface SalesHeader {
  id: string;
  sales_no: string;
  sales_date: string;
  customer_code: string;
  total_amount: number;
  status: string;
  remark: string;
  customers?: { customer_name: string };
}

export default function SalesListPage() {
  const [sales, setSales] = useState<SalesHeader[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchSales = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('sales_headers')
      .select('*, customers(customer_name)')
      .order('sales_date', { ascending: false });

    if (error) {
      console.error(error);
    } else {
      setSales(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchSales();
  }, []);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>판매 출고 목록</h1>
        <Link href="/sales" className="btn btn-primary">신규 판매 등록</Link>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>관리 번호</th>
                <th>판매 일자</th>
                <th>매입처</th>
                <th>총액</th>
                <th>상태</th>
                <th>비고</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>로딩 중...</td></tr>
              ) : sales.map((s) => (
                <tr key={s.id}>
                  <td>{s.sales_no || '-'}</td>
                  <td>{s.sales_date}</td>
                  <td>{s.customers?.customer_name} ({s.customer_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{s.total_amount?.toLocaleString() || 0} 원</td>
                  <td>
                    <span className="badge badge-success">출고완료</span>
                  </td>
                  <td>{s.remark}</td>
                </tr>
              ))}
              {sales.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>판매 데이터가 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
