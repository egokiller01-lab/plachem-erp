'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import Link from 'next/link';
import { useUserRole } from '@/hooks/useUserRole';

interface PurchaseHeader {
// ... (omitted same part)
export default function PurchaseListPage() {
  const [purchases, setPurchases] = useState<PurchaseHeader[]>([]);
  const [loading, setLoading] = useState(true);
  const { isManager, loading: roleLoading } = useUserRole();

  const fetchPurchases = async () => {
// ... (omitted same part)
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
