'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';

interface ProductionHeader {
  id: string;
  production_no: string;
  production_date: string;
  status: string;
  remark: string;
}

export default function ProductionListPage() {
  const [productions, setProductions] = useState<ProductionHeader[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchProductions = async () => {
    setLoading(true);
    const { data } = await supabase
      .from('production_headers')
      .select('*')
      .order('production_date', { ascending: false });

    setProductions(data || []);
    setLoading(false);
  };

  useEffect(() => {
    fetchProductions();
  }, []);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Production List</h1>
        <Link href="/production" className="btn btn-primary">New Entry</Link>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>Production No</th>
                <th>Production Date</th>
                <th>Status</th>
                <th>Remark</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={4} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : productions.map((p) => (
                <tr key={p.id}>
                  <td>{p.production_no || '-'}</td>
                  <td>{p.production_date}</td>
                  <td>
                    <span className="badge badge-success">Completed</span>
                  </td>
                  <td>{p.remark}</td>
                </tr>
              ))}
              {productions.length === 0 && !loading && (
                <tr><td colSpan={4} style={{ textAlign: 'center' }}>No data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
