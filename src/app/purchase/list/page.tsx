'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';

interface PurchaseHeader {
  id: string;
  purchase_no: string;
  purchase_date: string;
  customer_code: string;
  total_amount: number;
  status: string;
  remark: string;
  customers?: { customer_name: string };
}

export default function PurchaseListPage() {
  const [purchases, setPurchases] = useState<PurchaseHeader[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchPurchases = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('purchase_headers')
      .select('*, customers(customer_name)')
      .order('purchase_date', { ascending: false });

    if (error) {
      console.error(error);
    } else {
      setPurchases(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchPurchases();
  }, []);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>구매 입고 목록</h1>
        <Link href="/purchase" className="btn btn-primary">신규 등록</Link>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>관리 번호</th>
                <th>입고 일자</th>
                <th>공급처</th>
                <th>총액</th>
                <th>상태</th>
                <th>비고</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>로딩 중...</td></tr>
              ) : purchases.map((p) => (
                <tr key={p.id}>
                  <td>{p.purchase_no || '-'}</td>
                  <td>{p.purchase_date}</td>
                  <td>{p.customers?.customer_name} ({p.customer_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{p.total_amount?.toLocaleString() || 0} 원</td>
                  <td>
                    <span className="badge badge-success">입고완료</span>
                  </td>
                  <td>{p.remark}</td>
                </tr>
              ))}
              {purchases.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>데이터가 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
