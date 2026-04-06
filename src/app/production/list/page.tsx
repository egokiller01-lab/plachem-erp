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
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>생산 실적 목록</h1>
        <Link href="/production" className="btn btn-primary">신규 생산 등록</Link>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>관리 번호</th>
                <th>생산 일자</th>
                <th>상태</th>
                <th>비고</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={4} style={{ textAlign: 'center' }}>로딩 중...</td></tr>
              ) : productions.map((p) => (
                <tr key={p.id}>
                  <td>{p.production_no || '-'}</td>
                  <td>{p.production_date}</td>
                  <td>
                    <span className="badge badge-success">생산완료</span>
                  </td>
                  <td>{p.remark}</td>
                </tr>
              ))}
              {productions.length === 0 && !loading && (
                <tr><td colSpan={4} style={{ textAlign: 'center' }}>생산 데이터가 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
