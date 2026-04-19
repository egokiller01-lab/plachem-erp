'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

interface AccountsReceivable {
  id: number;
  customer_id: string;
  ref_type: string;
  ref_id: number;
  doc_date: string;
  due_date: string;
  total_amount: number;
  received_amount: number;
  status: 'unpaid' | 'partially_paid' | 'paid' | 'void';
  customers: {
    customer_name: string;
    customer_code: string;
  };
}

export default function AccountsReceivablePage() {
  const { isManager, isAdmin } = useUserRole();
  const [arList, setArList] = useState<AccountsReceivable[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<string>('all');
  
  // 수금 등록 모달 상태
  const [showModal, setShowModal] = useState(false);
  const [selectedAr, setSelectedAr] = useState<AccountsReceivable | null>(null);
  const [receiptForm, setReceiptForm] = useState({
    amount: 0,
    date: new Date().toISOString().split('T')[0],
    method: 'BANK',
    remark: ''
  });

  const fetchArList = async () => {
    setLoading(true);
    let query = supabase
      .from('accounts_receivable')
      .select('*, customers(customer_name, customer_code)')
      .order('doc_date', { ascending: false });

    if (statusFilter !== 'all') {
      query = query.eq('status', statusFilter);
    }

    const { data, error } = await query;
    if (error) {
      alert('Failed to fetch AR data');
    } else {
      setArList(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchArList();
  }, [statusFilter]);

  const handleOpenReceipt = (ar: AccountsReceivable) => {
    setSelectedAr(ar);
    setReceiptForm({
      amount: ar.total_amount - ar.received_amount,
      date: new Date().toISOString().split('T')[0],
      method: 'BANK',
      remark: ''
    });
    setShowModal(true);
  };

  const handleRegisterReceipt = async () => {
    if (!selectedAr) return;
    if (receiptForm.amount <= 0) return alert('수금 금액을 입력하세요.');
    
    setLoading(true);
    const { data, error } = await supabase.rpc('register_receipt', {
      p_ar_id: selectedAr.id,
      p_amount: receiptForm.amount,
      p_date: receiptForm.date,
      p_method: receiptForm.method,
      p_remark: receiptForm.remark
    });

    if (error) {
      alert('Error: ' + error.message);
    } else if (data && !data.success) {
      alert('수금 실패: ' + data.message);
    } else {
      alert('수금 처리가 완료되었습니다.');
      setShowModal(false);
      fetchArList();
    }
    setLoading(false);
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Accounts Receivable (매출채권)</h1>
        <div style={{ display: 'flex', gap: '8px' }}>
          {['all', 'unpaid', 'partially_paid', 'paid', 'void'].map(s => (
            <button 
              key={s} 
              className={`btn btn-sm ${statusFilter === s ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setStatusFilter(s)}
              style={{ textTransform: 'capitalize' }}
            >
              {s}
            </button>
          ))}
        </div>
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>발생일</th>
                <th>수금기한</th>
                <th>고객사</th>
                <th>참조ID</th>
                <th style={{ textAlign: 'right' }}>총 매출액</th>
                <th style={{ textAlign: 'right' }}>잔액</th>
                <th>상태</th>
                <th>작업</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={8} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : arList.map(ar => (
                <tr key={ar.id}>
                  <td>{ar.doc_date}</td>
                  <td style={{ color: new Date(ar.due_date) < new Date() && ar.status !== 'paid' ? 'var(--danger)' : 'inherit' }}>
                    {ar.due_date}
                  </td>
                  <td>[{ar.customers.customer_code}] {ar.customers.customer_name}</td>
                  <td>{ar.ref_id}</td>
                  <td style={{ textAlign: 'right' }}>{ar.total_amount.toLocaleString()}</td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold', color: 'var(--primary)' }}>
                    {(ar.total_amount - ar.received_amount).toLocaleString()}
                  </td>
                  <td>
                    <span className={`badge badge-${
                      ar.status === 'paid' ? 'success' : 
                      ar.status === 'unpaid' ? 'danger' : 
                      ar.status === 'void' ? 'ghost' : 'secondary'
                    }`}>
                      {ar.status.toUpperCase()}
                    </span>
                  </td>
                  <td>
                    {(ar.status === 'unpaid' || ar.status === 'partially_paid') && (isManager || isAdmin) && (
                      <button className="btn btn-secondary btn-sm" onClick={() => handleOpenReceipt(ar)}>
                        수금 등록
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {showModal && selectedAr && (
        <div style={{ position: 'fixed', top: 0, left: 0, width: '100%', height: '100%', backgroundColor: 'rgba(0,0,0,0.5)', display: 'flex', justifyContent: 'center', alignItems: 'center', zIndex: 1000 }}>
          <div className="card" style={{ width: '450px', padding: '32px' }}>
            <h3 style={{ marginBottom: '24px' }}>수금 실적 등록</h3>
            <div className="form-group">
              <label className="form-label">대상 고객사</label>
              <div style={{ fontWeight: 'bold', padding: '8px 0' }}>{selectedAr.customers.customer_name}</div>
            </div>
            <div className="form-group">
              <label className="form-label">미수금 잔액</label>
              <div style={{ color: 'var(--danger)', fontWeight: 'bold' }}>
                {(selectedAr.total_amount - selectedAr.received_amount).toLocaleString()} KRW
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">수금 일자</label>
              <input 
                type="date" 
                className="form-control" 
                value={receiptForm.date} 
                onChange={e => setReceiptForm({...receiptForm, date: e.target.value})} 
              />
            </div>
            <div className="form-group">
              <label className="form-label">수금 금액</label>
              <input 
                type="number" 
                className="form-control" 
                value={receiptForm.amount} 
                onChange={e => setReceiptForm({...receiptForm, amount: parseFloat(e.target.value) || 0})} 
              />
            </div>
            <div className="form-group">
              <label className="form-label">수금 수단</label>
              <select 
                className="form-control" 
                value={receiptForm.method} 
                onChange={e => setReceiptForm({...receiptForm, method: e.target.value})}
              >
                <option value="BANK">은행 이체 (BANK)</option>
                <option value="CASH">현금 (CASH)</option>
                <option value="CARD">법인/신용카드 (CARD)</option>
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">비고</label>
              <input 
                type="text" 
                className="form-control" 
                value={receiptForm.remark} 
                onChange={e => setReceiptForm({...receiptForm, remark: e.target.value})} 
              />
            </div>
            <div className="flex-between" style={{ marginTop: '32px' }}>
              <button className="btn btn-ghost" onClick={() => setShowModal(false)} disabled={loading}>취소</button>
              <button className="btn btn-primary" onClick={handleRegisterReceipt} disabled={loading}>
                {loading ? '처리 중...' : '수금 확정'}
              </button>
            </div>
          </div>
        </div>
      )}
    </Shell>
  );
}
