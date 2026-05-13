'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';
import { useUserRole } from '@/hooks/useUserRole';

interface PurchaseHeader {
  id: number;
  purchase_no: string;
  purchase_date: string;
  customer_code: string;
  total_amount: number;
  status: string;
  remark: string;
  customers: { customer_name: string };
  [key: string]: any;
}

export default function PurchaseListPage() {
  const [purchases, setPurchases] = useState<PurchaseHeader[]>([]);
  const [loading, setLoading] = useState(true);
  const { isManager, loading: roleLoading } = useUserRole();

  const fetchPurchases = async () => {
    try {
      const { data, error } = await supabase
        .from('purchase_headers')
        .select('*, customers(customer_name)')
        .order('id', { ascending: false });
      if (error) throw error;
      setPurchases(data || []);
    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleConfirm = async (id: number) => {
    if (!confirm('매입 확정 시 재고와 원가에 즉시 반영되며 이후 수정이 제한됩니다. 계속하시겠습니까?')) return;
    try {
      const { data, error } = await supabase.rpc('confirm_purchase_document', { p_doc_id: id });
      if (error) throw error;
      if (data && !data.success) {
        alert('확정 실패: ' + (data.message || '알 수 없는 오류가 발생했습니다.'));
        return;
      }
      alert(data?.message || '매입이 성공적으로 확정되었습니다.');
      fetchPurchases();
    } catch (err: any) {
      console.error(err);
      alert('System error: ' + (err?.message || err));
    }
  };

  useEffect(() => {
    fetchPurchases();
  }, []);

  return (
    <Shell>
      <div className="container" style={{ padding: '20px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '1rem' }}>
          <h2>Purchase List</h2>
          <Link href="/purchase" className="btn btn-primary">New Purchase</Link>
        </div>
        <div className="table-responsive">
          <table className="table">
            <thead>
              <tr>
                <th>No</th>
                <th>Date</th>
                <th>Customer</th>
                <th>Amount</th>
                <th>Status</th>
                <th>Remark</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading || roleLoading ? (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : purchases.map((p) => (
                <tr key={p.id}>
                  <td>
                    <Link href={`/purchase?id=${p.id}`} className="text-secondary" style={{ fontWeight: '600', textDecoration: 'underline' }}>
                      {p.purchase_no || 'View Detail'}
                    </Link>
                  </td>
                  <td>{p.purchase_date}</td>
                  <td>{p.customers?.customer_name} ({p.customer_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{p.total_amount?.toLocaleString() || 0}</td>
                  <td>
                    {p.status === 'confirmed' ? (
                      <span className="badge badge-success">Confirmed</span>
                    ) : (
                      <span className="badge badge-warning">Draft</span>
                    )}
                  </td>
                  <td>{p.remark}</td>
                  <td>
                    {p.status !== 'confirmed' && isManager && (
                      <button className="btn btn-primary" style={{ padding: '4px 8px', fontSize: '12px' }} onClick={() => handleConfirm(p.id)}>
                        Confirm
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {purchases.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
