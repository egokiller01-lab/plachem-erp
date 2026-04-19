'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

interface LedgerEntry {
  source_id: number;
  customer_id: number;
  doc_date: string;
  ref_type: string;
  ref_id: number;
  amount: number;
  remark: string;
}

export default function CustomerLedgerPage() {
  const { isManager, isAdmin } = useUserRole();
  const [customers, setCustomers] = useState<any[]>([]);
  const [selectedCustomerId, setSelectedCustomerId] = useState<string>('');
  const [ledgerEntries, setLedgerEntries] = useState<LedgerEntry[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const fetchCustomers = async () => {
      const { data } = await supabase.from('customers').select('id, customer_name, customer_code').eq('status', 'active');
      setCustomers(data || []);
    };
    fetchCustomers();
  }, []);

  const fetchLedger = async (customerId: string) => {
    if (!customerId) return;
    setLoading(true);
    const { data, error } = await supabase
      .from('v_customer_ledger')
      .select('*')
      .eq('customer_id', customerId)
      .order('doc_date', { ascending: true })
      .order('source_id', { ascending: true }); // Secondary sort for stable running balance

    if (error) {
      alert('Failed to fetch ledger data');
    } else {
      setLedgerEntries(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    if (selectedCustomerId) {
      fetchLedger(selectedCustomerId);
    } else {
      setLedgerEntries([]);
    }
  }, [selectedCustomerId]);

  // Calculate Running Balance
  const ledgerWithBalance = useMemo(() => {
    let balance = 0;
    return ledgerEntries.map(entry => {
      balance += entry.amount;
      return { ...entry, running_balance: balance };
    });
  }, [ledgerEntries]);

  if (!isManager && !isAdmin) {
    return <Shell><div>준비 중이거나 권한이 없는 페이지입니다.</div></Shell>;
  }

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Customer Ledger (거래처 원장)</h1>
        <div style={{ width: '300px' }}>
          <select 
            className="form-control"
            value={selectedCustomerId}
            onChange={(e) => setSelectedCustomerId(e.target.value)}
          >
            <option value="">거래처를 선택하세요</option>
            {customers.map(c => (
              <option key={c.id} value={c.id}>[{c.customer_code}] {c.customer_name}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th style={{ width: '120px' }}>일자</th>
                <th style={{ width: '120px' }}>유형</th>
                <th>전표번호/참조</th>
                <th style={{ textAlign: 'right', width: '150px' }}>증감액</th>
                <th style={{ textAlign: 'right', width: '150px', backgroundColor: '#f8fafc' }}>순채권 잔액</th>
                <th>비고</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : ledgerWithBalance.length === 0 ? (
                <tr><td colSpan={6} style={{ textAlign: 'center', color: 'var(--text-muted)' }}>거래 내역이 없습니다. 거래처를 선택해 주세요.</td></tr>
              ) : (
                ledgerWithBalance.map((item, idx) => (
                  <tr key={`${item.ref_type}-${item.source_id}-${idx}`}>
                    <td>{item.doc_date}</td>
                    <td>
                      <span style={{ 
                        fontSize: '11px', 
                        padding: '2px 6px', 
                        borderRadius: '4px',
                        backgroundColor: item.amount > 0 ? '#E0F2FE' : '#FEE2E2',
                        color: item.amount > 0 ? '#0369A1' : '#B91C1C'
                      }}>
                        {item.ref_type}
                      </span>
                    </td>
                    <td>{item.ref_id}</td>
                    <td style={{ textAlign: 'right', fontWeight: '600', color: item.amount > 0 ? 'var(--primary)' : 'var(--danger)' }}>
                      {item.amount > 0 ? '+' : ''}{item.amount.toLocaleString()}
                    </td>
                    <td style={{ textAlign: 'right', fontWeight: 'bold', backgroundColor: '#f8fafc' }}>
                      {item.running_balance.toLocaleString()}
                    </td>
                    <td style={{ color: 'var(--text-muted)', fontSize: '13px' }}>{item.remark}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="mt-24" style={{ fontSize: '14px', color: 'var(--text-muted)' }}>
        <p>* AR = 매출(순채권 증가), AP = 매입(순채권 감소), RECEIPT = 수금(미수금 감소), PAYMENT = 지급(미지급 감소)</p>
        <p>* 모든 금액은 부가세가 포함된 총 청구액 기준입니다.</p>
      </div>
    </Shell>
  );
}
