'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';
import { useUserRole } from '@/hooks/useUserRole';

interface SalesHeader {
  id: number;
  sales_no: string;
  sales_date: string;
  customer_code: string;
  total_amount: number;
  status: string;
  remark: string;
  customers: { customer_name: string };
  [key: string]: any;
}

export default function SalesListPage() {
  const [sales, setSales] = useState<SalesHeader[]>([]);
  const [loading, setLoading] = useState(true);
  const { isManager, loading: roleLoading } = useUserRole();

  const fetchSales = async () => {
    try {
      const { data, error } = await supabase
        .from('sales_headers')
        .select('*, customers(customer_name)')
        .order('id', { ascending: false });
      if (error) throw error;
      setSales(data || []);
    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleConfirm = async (id: number) => {
    if (!confirm('Are you sure you want to confirm this document?')) return;
    try {
      const { error } = await supabase.from('sales_headers').update({ status: 'confirmed' }).eq('id', id);
      if (error) throw error;
      fetchSales();
    } catch (err) {
      console.error(err);
    }
  };

  useEffect(() => {
    fetchSales();
  }, []);

  return (
    <Shell>
      <div className="container" style={{ padding: '20px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '1rem' }}>
          <h2>Sales List</h2>
          <Link href="/sales" className="btn btn-primary">New Sales</Link>
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
              ) : sales.map((s) => (
                <tr key={s.id}>
                  <td>
                    <Link href={`/sales?id=${s.id}`} className="text-secondary" style={{ fontWeight: '600', textDecoration: 'underline' }}>
                      {s.sales_no || 'View Detail'}
                    </Link>
                  </td>
                  <td>{s.sales_date}</td>
                  <td>{s.customers?.customer_name} ({s.customer_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{s.total_amount?.toLocaleString() || 0}</td>
                  <td>
                    {s.status === 'confirmed' ? (
                      <span className="badge badge-success">Confirmed</span>
                    ) : (
                      <span className="badge badge-warning">Draft</span>
                    )}
                  </td>
                  <td>{s.remark}</td>
                  <td>
                    {s.status !== 'confirmed' && isManager && (
                      <button className="btn btn-primary" style={{ padding: '4px 8px', fontSize: '12px' }} onClick={() => handleConfirm(s.id)}>
                        Confirm
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {sales.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
