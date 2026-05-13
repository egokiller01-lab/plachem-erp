'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';
import { useMemo } from 'react';

interface AccountsPayable {
  id: number;
  vendor_id: string;
  ref_type: string;
  ref_id: number;
  doc_date: string;
  total_amount: number;
  paid_amount: number;
  status: 'unpaid' | 'partially_paid' | 'paid' | 'void';
  customers: {
    customer_name: string;
    customer_code: string;
  };
}

export default function AccountsPayablePage() {
  const { isManager, isAdmin } = useUserRole();
  const [apList, setApList] = useState<AccountsPayable[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [typeFilter, setTypeFilter] = useState<string>('all');
  
  // 지급 등록 모달 상태
  const [showModal, setShowModal] = useState(false);
  const [selectedAp, setSelectedAp] = useState<AccountsPayable | null>(null);
  const [paymentForm, setPaymentForm] = useState({
    amount: 0,
    date: new Date().toISOString().split('T')[0],
    method: 'BANK',
    remark: ''
  });

  const fetchApList = async () => {
    setLoading(true);
    let query = supabase
      .from('accounts_payable')
      .select('*, customers(customer_name, customer_code)')
      .order('doc_date', { ascending: false });

    if (statusFilter !== 'all') {
      query = query.eq('status', statusFilter);
    }
    if (typeFilter !== 'all') {
      query = query.eq('ref_type', typeFilter);
    }

    const { data, error } = await query;
    if (error) {
      alert('Failed to fetch AP data');
    } else {
      setApList(data || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchApList();
  }, [statusFilter, typeFilter]);

  const handleOpenPayment = (ap: AccountsPayable) => {
    setSelectedAp(ap);
    setPaymentForm({
      amount: ap.total_amount - ap.paid_amount,
      date: new Date().toISOString().split('T')[0],
      method: 'BANK',
      remark: ''
    });
    setShowModal(true);
  };

  const handleRegisterPayment = async () => {
    if (!selectedAp) return;
    if (paymentForm.amount <= 0) return alert('지급 금액을 입력하세요.');
    
    setLoading(true);
    const { data, error } = await supabase.rpc('register_payment', {
      p_ap_id: selectedAp.id,
      p_amount: paymentForm.amount,
      p_date: paymentForm.date,
      p_method: paymentForm.method,
      p_remark: paymentForm.remark
    });

    if (error) {
      alert('Error: ' + error.message);
    } else if (data && !data.success) {
      alert('지급 실패: ' + data.message);
    } else {
      alert('지급 처리가 완료되었습니다.');
      setShowModal(false);
      fetchApList();
    }
    setLoading(false);
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Accounts Payable (매입채무)</h1>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '8px' }}>
          <div style={{ display: 'flex', gap: '8px' }}>
            <span style={{ fontSize: '13px', color: '#64748B', alignSelf: 'center', marginRight: '8px' }}>Type:</span>
            {['all', 'PURCHASE', 'PRODUCTION_SUBCON', 'EXPENSE'].map(t => (
              <button 
                key={t} 
                className={`btn btn-sm ${typeFilter === t ? 'btn-secondary' : 'btn-ghost'}`}
                onClick={() => setTypeFilter(t)}
              >
                {t === 'all' ? '전체' : t === 'PURCHASE' ? '매입' : t === 'EXPENSE' ? '판관비' : '외주'}
              </button>
            ))}
          </div>
          <div style={{ display: 'flex', gap: '8px' }}>
            <span style={{ fontSize: '13px', color: '#64748B', alignSelf: 'center', marginRight: '8px' }}>Status:</span>
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
      </div>

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>발생일</th>
                <th>유형</th>
                <th>거래처</th>
                <th>참조ID</th>
                <th style={{ textAlign: 'right' }}>총 채무액</th>
                <th style={{ textAlign: 'right' }}>잔액</th>
                <th>상태</th>
                <th>작업</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={8} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : apList.map(ap => (
                <tr key={ap.id}>
                  <td>{ap.doc_date}</td>
                  <td>
                    <span style={{ 
                      fontSize: '11px', 
                      padding: '2px 6px', 
                      borderRadius: '4px', 
                      backgroundColor: ap.ref_type === 'PURCHASE' ? '#E0E7FF' : ap.ref_type === 'EXPENSE' ? '#DCFCE7' : '#F3E8FF',
                      color: ap.ref_type === 'PURCHASE' ? '#4338CA' : ap.ref_type === 'EXPENSE' ? '#166534' : '#7E22CE',
                      fontWeight: '600'
                    }}>
                      {ap.ref_type === 'PURCHASE' ? '매입' : ap.ref_type === 'EXPENSE' ? '판관비' : '외주'}
                    </span>
                  </td>
                  <td>[{ap.customers.customer_code}] {ap.customers.customer_name}</td>
                  <td>{ap.ref_id}</td>
                  <td style={{ textAlign: 'right' }}>{ap.total_amount.toLocaleString()}</td>
                  <td style={{ textAlign: 'right', fontWeight: 'bold', color: 'var(--primary)' }}>
                    {(ap.total_amount - ap.paid_amount).toLocaleString()}
                  </td>
                  <td>
                    <span className={`badge badge-${
                      ap.status === 'paid' ? 'success' : 
                      ap.status === 'unpaid' ? 'danger' : 
                      ap.status === 'void' ? 'ghost' : 'secondary'
                    }`}>
                      {ap.status.toUpperCase()}
                    </span>
                  </td>
                  <td>
                    {(ap.status === 'unpaid' || ap.status === 'partially_paid') && (isManager || isAdmin) && (
                      <button className="btn btn-secondary btn-sm" onClick={() => handleOpenPayment(ap)}>
                        지급 등록
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {showModal && selectedAp && (
        <div style={{ position: 'fixed', top: 0, left: 0, width: '100%', height: '100%', backgroundColor: 'rgba(0,0,0,0.5)', display: 'flex', justifyContent: 'center', alignItems: 'center', zIndex: 1000 }}>
          <div className="card" style={{ width: '450px', padding: '32px' }}>
            <h3 style={{ marginBottom: '24px' }}>지급 실적 등록</h3>
            <div className="form-group">
              <label className="form-label">대상 거래처</label>
              <div style={{ fontWeight: 'bold', padding: '8px 0' }}>{selectedAp.customers.customer_name}</div>
            </div>
            <div className="form-group">
              <label className="form-label">미지급 잔액</label>
              <div style={{ color: 'var(--danger)', fontWeight: 'bold' }}>
                {(selectedAp.total_amount - selectedAp.paid_amount).toLocaleString()} KRW
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">지급 일자</label>
              <input 
                type="date" 
                className="form-control" 
                value={paymentForm.date} 
                onChange={e => setPaymentForm({...paymentForm, date: e.target.value})} 
              />
            </div>
            <div className="form-group">
              <label className="form-label">지급 금액</label>
              <input 
                type="number" 
                className="form-control" 
                value={paymentForm.amount} 
                onChange={e => setPaymentForm({...paymentForm, amount: parseFloat(e.target.value) || 0})} 
              />
            </div>
            <div className="form-group">
              <label className="form-label">지급 수단</label>
              <select 
                className="form-control" 
                value={paymentForm.method} 
                onChange={e => setPaymentForm({...paymentForm, method: e.target.value})}
              >
                <option value="BANK">은행 이체 (BANK)</option>
                <option value="CASH">현금 (CASH)</option>
                <option value="LINK">기타 연동 (LINK)</option>
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">비고</label>
              <input 
                type="text" 
                className="form-control" 
                value={paymentForm.remark} 
                onChange={e => setPaymentForm({...paymentForm, remark: e.target.value})} 
              />
            </div>
            <div className="flex-between" style={{ marginTop: '32px' }}>
              <button className="btn btn-ghost" onClick={() => setShowModal(false)} disabled={loading}>취소</button>
              <button className="btn btn-primary" onClick={handleRegisterPayment} disabled={loading}>
                {loading ? '처리 중...' : '지급 확정'}
              </button>
            </div>
          </div>
        </div>
      )}
    </Shell>
  );
}
