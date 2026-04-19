'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

export default function ExpensesPage() {
  const { isManager, isAdmin, userId } = useUserRole();
  const [categories, setCategories] = useState<any[]>([]);
  const [vendors, setVendors] = useState<any[]>([]);
  const [expenses, setExpenses] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const [formData, setFormData] = useState({
    id: null as number | null,
    category_id: '',
    expense_date: new Date().toISOString().substring(0, 10),
    is_payable: false,
    vendor_id: '',
    due_date: '',
    amount: 0,
    vat_amount: 0,
    remark: ''
  });

  const fetchBaseData = async () => {
    setLoading(true);
    const { data: cat } = await supabase.from('expense_categories').select('*').eq('is_active', true);
    const { data: ven } = await supabase.from('customers').select('id, customer_name');
    const { data: exp } = await supabase.from('expense_records').select('*, expense_categories(category_name), customers(customer_name)').order('expense_date', { ascending: false });
    setCategories(cat || []);
    setVendors(ven || []);
    setExpenses(exp || []);
    setLoading(false);
  };

  useEffect(() => {
    if (isManager || isAdmin) fetchBaseData();
  }, [isManager, isAdmin]);

  const handleSave = async () => {
    const total = Number(formData.amount) + Number(formData.vat_amount);
    const payload = {
      category_id: formData.category_id,
      expense_date: formData.expense_date,
      is_payable: formData.is_payable,
      vendor_id: formData.is_payable ? formData.vendor_id : null,
      due_date: formData.is_payable ? formData.due_date : null,
      amount: formData.amount,
      vat_amount: formData.vat_amount,
      total_amount: total,
      remark: formData.remark,
      created_by: userId
    };

    let error;
    if (formData.id) {
      const { error: err } = await supabase.from('expense_records').update(payload).eq('id', formData.id);
      error = err;
    } else {
      const { error: err } = await supabase.from('expense_records').insert([payload]);
      error = err;
    }

    if (error) alert('저장 실패: ' + error.message);
    else {
      alert('성공적으로 저장되었습니다.');
      setFormData({ ...formData, id: null, remark: '', amount: 0, vat_amount: 0 });
      fetchBaseData();
    }
  };

  const handleAction = async (id: number, action: 'confirm' | 'unconfirm') => {
    let res;
    if (action === 'confirm') {
      res = await supabase.rpc('confirm_expense_document', { p_doc_id: id });
    } else {
      const reason = prompt('확정 취소 사유를 입력하세요:');
      if (!reason) return;
      res = await supabase.rpc('unconfirm_expense_document', { p_doc_id: id, p_reason: reason });
    }

    if (res.data?.success) {
      alert(res.data.message);
      fetchBaseData();
    } else {
      alert('오류: ' + (res.data?.message || '알 수 없는 오류'));
    }
  };

  if (!isManager && !isAdmin) return <Shell><div>권한이 없습니다.</div></Shell>;

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>일반 판관비 관리 (SG&A)</h1>
        <button className="btn btn-primary" onClick={() => setFormData({ ...formData, id: null })}>신규 전표 작성</button>
      </div>

      <div className="grid-cols-3" style={{ gap: '24px', alignItems: 'start' }}>
        {/* Form Section */}
        <div className="card col-span-1">
          <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px' }}>{formData.id ? '전표 수정' : '신규 전표'}</h3>
          <div className="grid-cols-1" style={{ gap: '12px' }}>
            <label className="form-label">비용 항목</label>
            <select className="form-control" value={formData.category_id} onChange={e => setFormData({ ...formData, category_id: e.target.value })}>
              <option value="">항목 선택</option>
              {categories.map(c => <option key={c.id} value={c.id}>{c.category_name}</option>)}
            </select>

            <label className="form-label">발생일 (P&L 반영일)</label>
            <input type="date" className="form-control" value={formData.expense_date} onChange={e => setFormData({ ...formData, expense_date: e.target.value })} />

            <div style={{ display: 'flex', alignItems: 'center', gap: '8px', margin: '8px 0' }}>
              <input type="checkbox" checked={formData.is_payable} onChange={e => setFormData({ ...formData, is_payable: e.target.checked })} />
              <label className="form-label" style={{ marginBottom: 0 }}>외부 지급 의무 (AP 연동)</label>
            </div>

            {formData.is_payable && (
              <>
                <label className="form-label">지급처 (Vendor)</label>
                <select className="form-control" value={formData.vendor_id} onChange={e => setFormData({ ...formData, vendor_id: e.target.value })}>
                  <option value="">거래처 선택</option>
                  {vendors.map(v => <option key={v.id} value={v.id}>{v.customer_name}</option>)}
                </select>
                <label className="form-label">지급 기한 (Due Date)</label>
                <input type="date" className="form-control" value={formData.due_date} onChange={e => setFormData({ ...formData, due_date: e.target.value })} />
              </>
            )}

            <div className="grid-cols-2" style={{ gap: '8px' }}>
              <div>
                <label className="form-label">공급가액</label>
                <input type="number" className="form-control" value={formData.amount} onChange={e => setFormData({ ...formData, amount: Number(e.target.value) })} />
              </div>
              <div>
                <label className="form-label">부가세</label>
                <input type="number" className="form-control" value={formData.vat_amount} onChange={e => setFormData({ ...formData, vat_amount: Number(e.target.value) })} />
              </div>
            </div>

            <label className="form-label">비고 / 비유 (Remark)</label>
            <textarea className="form-control" style={{ height: '80px' }} value={formData.remark} onChange={e => setFormData({ ...formData, remark: e.target.value })} />

            <button className="btn btn-primary mt-16" onClick={handleSave}>전표 저장</button>
          </div>
        </div>

        {/* List Section */}
        <div className="card col-span-2">
          <h3 style={{ fontSize: '18px', fontWeight: 'bold', marginBottom: '16px' }}>비용 기록 리스트</h3>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>발생일</th>
                  <th>항목</th>
                  <th style={{ textAlign: 'right' }}>공급가</th>
                  <th>AP여부</th>
                  <th>지급처</th>
                  <th>상태</th>
                  <th>작업</th>
                </tr>
              </thead>
              <tbody>
                {expenses.map(e => (
                  <tr key={e.id}>
                    <td>{e.expense_date}</td>
                    <td style={{ fontWeight: '600' }}>{e.expense_categories?.category_name}</td>
                    <td style={{ textAlign: 'right' }}>{e.amount.toLocaleString()}</td>
                    <td><span className={e.is_payable ? 'text-primary' : 'text-muted'}>{e.is_payable ? '대상' : '-'}</span></td>
                    <td style={{ fontSize: '12px' }}>{e.customers?.customer_name || '-'}</td>
                    <td>
                      <span className={`badge ${e.status === 'confirmed' ? 'badge-primary' : (e.status === 'void' ? 'badge-danger' : 'badge-ghost')}`}>
                        {e.status.toUpperCase()}
                      </span>
                    </td>
                    <td>
                      <div className="flex-start" style={{ gap: '4px' }}>
                        {e.status === 'draft' ? (
                          <>
                            <button className="btn btn-xs btn-ghost" onClick={() => setFormData({
                              id: e.id,
                              category_id: String(e.category_id),
                              expense_date: e.expense_date,
                              is_payable: e.is_payable,
                              vendor_id: String(e.vendor_id || ''),
                              due_date: e.due_date || '',
                              amount: e.amount,
                              vat_amount: e.vat_amount,
                              remark: e.remark || ''
                            })}>수정</button>
                            <button className="btn btn-xs btn-primary" onClick={() => handleAction(e.id, 'confirm')}>확정</button>
                          </>
                        ) : (
                          isAdmin && e.status === 'confirmed' && (
                            <button className="btn btn-xs btn-danger" onClick={() => handleAction(e.id, 'unconfirm')}>취소</button>
                          )
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Shell>
  );
}
