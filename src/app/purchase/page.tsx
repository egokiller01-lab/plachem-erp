'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter, useSearchParams } from 'next/navigation';
import { useUserRole } from '@/hooks/useUserRole';
import { useMemo } from 'react';

interface PurchaseItem {
  line_no: number;
  product_id?: number | string; // bigint ID
  product_code: string;
  qty: number;
  unit_price: number; // keeping strictly for fallback or rename
  net_unit_price: number;
  vat_rate: number;
  net_amount: number;
  vat_amount: number;
  amount: number; // Gross amount
  remark: string;
}

export default function PurchaseEntryPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const editId = searchParams.get('id');
  const { isManager, isAdmin, userId } = useUserRole();

  const [customers, setCustomers] = useState<any[]>([]);
  const [products, setProducts] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [initialLoading, setInitialLoading] = useState(Boolean(editId));

  const [header, setHeader] = useState<{
    purchase_no: string;
    purchase_date: string;
    supplier_id: string;
    status: string;
    attachment_url: string;
    remark: string;
    created_by?: string;
    due_date?: string;
  }>({
    purchase_no: '',
    purchase_date: new Date().toISOString().split('T')[0],
    supplier_id: '',
    status: 'draft',
    attachment_url: '',
    remark: '',
    due_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
  });

  const [items, setItems] = useState<PurchaseItem[]>([]);

  const isConfirmed = useMemo(() => header.status === 'confirmed', [header.status]);
  const canEdit = useMemo(() => {
    // Draft 상태에서만 수정 가능하며, (관리자/팀장) 또는 (본인 작성)이어야 함
    return header.status === 'draft' && (isAdmin || isManager || header.created_by === userId);
  }, [header.status, isAdmin, isManager, header.created_by, userId]);

  useEffect(() => {
    const fetchMasters = async () => {
      const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      setCustomers(custData || []);
      setProducts(prodData || []);
    };
    
    const fetchExistingData = async () => {
      if (!editId) {
        setItems([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, remark: '' }]);
        setInitialLoading(false);
        return;
      }
      setInitialLoading(true);
      const { data: headData, error: headError } = await supabase.from('purchase_headers').select('*').eq('id', editId).single();
      if (headError) { alert('Failed to load header'); setInitialLoading(false); return; }
      setHeader(headData);

      const { data: itemData, error: itemError } = await supabase.from('purchase_items').select('*').eq('purchase_header_id', editId).order('line_no', { ascending: true });
      if (itemError) { alert('Failed to load items'); setInitialLoading(false); return; }
      setItems(itemData || []);
      setInitialLoading(false);
    };

    fetchMasters();
    fetchExistingData();
  }, [editId]);

  const handleAddItem = () => {
    if (!canEdit) return;
    setItems([...items, { line_no: items.length + 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, remark: '' }]);
  };

  const handleRemoveItem = (index: number) => {
    const newItems = items.filter((_, i) => i !== index).map((item, idx) => ({ ...item, line_no: idx + 1 }));
    setItems(newItems);
  };

  const handleItemChange = (index: number, field: keyof PurchaseItem, value: any) => {
    if (!canEdit) return;
    const newItems = [...items];
    const item = { ...newItems[index], [field]: value };
    
    if (field === 'qty' || field === 'net_unit_price' || field === 'vat_rate') {
      const net = item.qty * item.net_unit_price;
      const vat = net * (item.vat_rate / 100);
      item.net_amount = net;
      item.vat_amount = vat;
      item.amount = net + vat;
    }
    
    if (field === 'product_code') {
      const prod = products.find(p => p.product_code === value);
      item.product_id = prod?.id;
    }
    
    newItems[index] = item;
    setItems(newItems);
  };

  const totalNetAmount = items.reduce((sum, item) => sum + item.net_amount, 0);
  const totalVatAmount = items.reduce((sum, item) => sum + item.vat_amount, 0);
  const totalAmount = items.reduce((sum, item) => sum + item.amount, 0);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canEdit) return;
    if (!header.supplier_id) return alert('Please select a supplier.');
    if (items.some(i => !i.product_code || i.qty <= 0)) return alert('Please enter valid product details.');

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    let headId = editId;

    if (editId) {
      // Update Header
      const { error: headError } = await supabase
        .from('purchase_headers')
        .update({
          ...header,
          total_net_amount: totalNetAmount,
          total_vat_amount: totalVatAmount,
          total_amount: totalAmount,
          updated_at: new Date().toISOString()
        })
        .eq('id', editId);

      if (headError) { 
        if (headError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Update failed: ' + headError.message); 
        setLoading(false); return; 
      }

      // Delete old items
      const { error: delError } = await supabase.from('purchase_items').delete().eq('purchase_header_id', editId);
      if (delError) { 
        if (delError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Failed to clear old items'); 
        setLoading(false); return; 
      }
    } else {
      // Insert Header
      const { data: headData, error: headError } = await supabase
        .from('purchase_headers')
        .insert([{
          ...header,
          total_net_amount: totalNetAmount,
          total_vat_amount: totalVatAmount,
          total_amount: totalAmount,
          created_by: userData.user?.id
        }])
        .select()
        .single();

      if (headError) { 
        if (headError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Save failed: ' + headError.message); 
        setLoading(false); return; 
      }
      headId = headData.id;
    }

    // Insert Items
    const { error: itemError } = await supabase
      .from('purchase_items')
      .insert(items.map(item => ({
        purchase_header_id: headId,
        line_no: item.line_no,
        product_id: item.product_id,
        product_code: item.product_code,
        qty: item.qty,
        unit_price: item.net_unit_price,
        net_unit_price: item.net_unit_price,
        vat_rate: item.vat_rate,
        net_amount: item.net_amount,
        vat_amount: item.vat_amount,
        amount: item.amount,
        remark: item.remark,
        created_by: userData.user?.id
      })));

    if (itemError) {
      if (itemError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
      else alert('Items process failed: ' + itemError.message);
    } else {
      alert('All changes saved!');
      router.push('/purchase/list');
    }
    setLoading(false);
  };

  const handleConfirmAction = async () => {
    if (!editId || !isManager) return;
    if (!confirm('매입 확정 시 재고와 원가에 즉시 반영되며 이후 수정이 제한됩니다. 계속하시겠습니까?')) return;
    
    setLoading(true);
    const { data, error } = await supabase.rpc('confirm_purchase_document', { p_doc_id: Number(editId) });
    
    if (error) {
      alert('System error: ' + error.message);
    } else if (data?.success) {
      alert(data.message || '매입이 성공적으로 확정되었습니다.');
      window.location.reload(); 
    } else {
      alert('확정 실패: ' + (data?.message || '알 수 없는 오류가 발생했습니다.'));
    }
    setLoading(false);
  };

  const handleUnconfirmAction = async () => {
    if (!editId || !isAdmin) return;
    const reason = prompt('확정 취소 사유를 입력해주세요 (필수):');
    if (!reason) return alert('사유를 입력해야 취소가 가능합니다.');

    if (!confirm('확정 취소 시 재고 트랜잭션이 역반영(삭제)되며 전표가 Draft 상태로 돌아갑니다. 진행하시겠습니까?')) return;

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();
    const { data, error } = await supabase.rpc('unconfirm_purchase_document', { 
      p_doc_id: Number(editId),
      p_reason: reason,
      p_user_uuid: userData.user?.id
    });

    if (error) {
      alert('System error: ' + error.message);
    } else if (data?.success) {
      alert(data.message || '확정 취소가 성공적으로 처리되었습니다.');
      window.location.reload(); 
    } else {
      alert('확정 취소 실패: ' + (data?.message || '권한이 없거나 이미 지급된 건입니다.'));
    }
    setLoading(false);
  };

  if (initialLoading) return <Shell><div>Loading record data...</div></Shell>;

  return (
    <Shell>
      {header.status !== 'draft' && (
        <div style={{ backgroundColor: '#fee2e2', border: '1px solid #ef4444', color: '#b91c1c', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 전표는 [{header.status === 'confirmed' ? '확정' : '취소'}] 상태로 수량이 이미 반영되었습니다. 모든 수정/삭제가 제한됩니다.</span>
        </div>
      )}
      {header.status === 'draft' && !canEdit && (
        <div style={{ backgroundColor: '#fef3c7', border: '1px solid #f59e0b', color: '#92400e', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 전표는 타인이 작성한 [Draft] 상태로 읽기 전용 모드입니다. (작성자 외 수정 불가)</span>
        </div>
      )}

      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>
          {editId ? (isConfirmed ? 'View Purchase' : 'Edit Purchase') : 'Add Purchase Entry'}
        </h1>
        <div style={{ display: 'flex', gap: '8px' }}>
          {editId && isConfirmed && isAdmin && (
            <button type="button" className="btn btn-ghost" onClick={handleUnconfirmAction} disabled={loading} style={{ color: 'var(--danger)', border: '1px solid var(--danger)' }}>
              Unconfirm (Admin)
            </button>
          )}
          {editId && !isConfirmed && isManager && (
            <button type="button" className="btn btn-secondary" onClick={handleConfirmAction} disabled={loading}>
              Confirm Now
            </button>
          )}
          <button className="btn btn-ghost" onClick={() => router.push('/purchase/list')}>Back to List</button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-24">
          <h3 style={{ marginBottom: '16px' }}>Basic Info</h3>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">Purchase No</label>
              <input 
                type="text" 
                className="form-control" 
                placeholder="Auto-generated or enter manually"
                value={header.purchase_no}
                onChange={(e) => setHeader({...header, purchase_no: e.target.value})}
                readOnly={!canEdit}
              />
            </div>
            <div className="form-group">
              <label className="form-label">Purchase Date *</label>
              <input 
                type="date" 
                className="form-control" 
                value={header.purchase_date}
                onChange={(e) => setHeader({...header, purchase_date: e.target.value})}
                required
                readOnly={!canEdit}
              />
            </div>
          </div>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">Supplier *</label>
              <select 
                className="form-control" 
                value={header.supplier_id}
                onChange={(e) => setHeader({...header, supplier_id: e.target.value})}
                required
                disabled={!canEdit}
              >
                <option value="">Select Supplier</option>
                {customers.map(c => <option key={c.id} value={c.id}>[{c.customer_code}] {c.customer_name}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Due Date (지급기한)</label>
              <input 
                type="date" 
                className="form-control" 
                value={header.due_date || ''}
                onChange={(e) => setHeader({...header, due_date: e.target.value})}
                readOnly={!canEdit}
              />
            </div>
          </div>
          <div className="grid-cols-2">
              <input 
                type="text" 
                className="form-control" 
                value={header.remark}
                onChange={(e) => setHeader({...header, remark: e.target.value})}
                readOnly={!canEdit}
              />
            </div>
          </div>
          <div className="form-group" style={{ marginTop: '16px' }}>
            <label className="form-label">Attachment (PDF url)</label>
            <input 
              type="text" 
              className="form-control" 
              placeholder="(Mockup) Enter URL for attachment..."
              value={header.attachment_url}
              onChange={(e) => setHeader({...header, attachment_url: e.target.value})}
              readOnly={!canEdit}
            />
          </div>
        </div>

        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>Item Details</h3>
            {canEdit && (
              <button type="button" className="btn btn-ghost" onClick={handleAddItem} style={{ color: 'var(--primary)' }}>
                + Add Item
              </button>
            )}
          </div>
          
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th style={{ width: '60px' }}>No</th>
                  <th style={{ minWidth: '150px' }}>Product Name *</th>
                  <th style={{ width: '90px' }}>Qty *</th>
                  <th style={{ width: '130px' }}>Net Price *</th>
                  <th style={{ width: '80px' }}>VAT %</th>
                  <th style={{ width: '100px' }}>VAT Amt</th>
                  <th style={{ width: '130px' }}>Gross Amt</th>
                  <th>Remark</th>
                  <th style={{ width: '80px' }}>Action</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item, index) => (
                  <tr key={index}>
                    <td>{item.line_no}</td>
                    <td>
                      <select 
                        className="form-control"
                        value={item.product_code}
                        onChange={(e) => handleItemChange(index, 'product_code', e.target.value)}
                        required
                        disabled={!canEdit}
                      >
                        <option value="">Select Product</option>
                        {products.map(p => <option key={p.product_code} value={p.product_code}>{p.product_name}</option>)}
                      </select>
                    </td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.qty}
                        onChange={(e) => handleItemChange(index, 'qty', parseFloat(e.target.value))}
                        required
                        min="0.1"
                        step="0.1"
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.net_unit_price}
                        onChange={(e) => handleItemChange(index, 'net_unit_price', parseFloat(e.target.value))}
                        required
                        min="0"
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      <select 
                        className="form-control" 
                        value={item.vat_rate}
                        onChange={(e) => handleItemChange(index, 'vat_rate', parseFloat(e.target.value))}
                        disabled={!canEdit}
                      >
                        <option value="0">0%</option>
                        <option value="8">8%</option>
                        <option value="10">10%</option>
                      </select>
                    </td>
                    <td style={{ textAlign: 'right' }}>{item.vat_amount.toLocaleString()}</td>
                    <td style={{ fontWeight: 'bold', textAlign: 'right', color: 'var(--primary)' }}>{item.amount.toLocaleString()}</td>
                    <td>
                      <input 
                        type="text" 
                        className="form-control"
                        value={item.remark}
                        onChange={(e) => handleItemChange(index, 'remark', e.target.value)}
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      {canEdit && (
                        <button 
                          type="button" 
                          className="btn btn-ghost" 
                          style={{ color: 'var(--danger)' }}
                          onClick={() => handleRemoveItem(index)}
                          disabled={items.length === 1}
                        >
                          Delete
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex-between mt-24" style={{ padding: '0 16px' }}>
            <div style={{ fontSize: '18px', display: 'flex', gap: '24px' }}>
              <div>Net Total: <span style={{ fontWeight: 'normal' }}>{totalNetAmount.toLocaleString()}</span></div>
              <div>VAT Total: <span style={{ fontWeight: 'normal' }}>{totalVatAmount.toLocaleString()}</span></div>
              <div style={{ fontWeight: 'bold' }}>
                Gross Total: <span style={{ color: 'var(--primary)', marginLeft: '12px' }}>{totalAmount.toLocaleString()}</span>
              </div>
            </div>
            {canEdit && (
              <button type="submit" className="btn btn-primary" disabled={loading} style={{ padding: '12px 40px' }}>
                {loading ? 'Saving...' : 'Save All'}
              </button>
            )}
          </div>
        </div>
      </form>
    </Shell>
  );
}
