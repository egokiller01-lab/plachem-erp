'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, Suspense } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter, useSearchParams } from 'next/navigation';
import { useUserRole } from '@/hooks/useUserRole';
import { useMemo } from 'react';
import ProductSelector from '@/components/ProductSelector';
import ProductDisplay from '@/components/ProductDisplay';

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

function PurchaseEntryContent() {
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
    customer_id: string;
    status: string;
    attachment_url: string;
    remark: string;
    created_by?: string;
    due_date?: string;
  }>({
    purchase_no: '',
    purchase_date: new Date().toISOString().split('T')[0],
    customer_id: '',
    status: 'draft',
    attachment_url: '',
    remark: '',
    due_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
  });

  const [items, setItems] = useState<PurchaseItem[]>([]);

  const isConfirmed = useMemo(() => header.status === 'confirmed', [header.status]);
  const canEdit = useMemo(() => {
    if (!editId) return true; // 신규 생성 시 무조건 작성 허용 (생성자 검증 불가 회피)
    // Draft 상태에서만 수정 가능하며, (관리자/팀장) 또는 (본인 작성)이어야 함
    return header.status === 'draft' && (isAdmin || isManager || header.created_by === userId);
  }, [editId, header.status, isAdmin, isManager, header.created_by, userId]);

  useEffect(() => {
    const init = async () => {
      setInitialLoading(true);
      const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      setCustomers(custData || []);
      setProducts(prodData || []);

      if (editId) {
        const { data: headData, error: headError } = await supabase.from('purchase_headers').select('*').eq('id', editId).single();
        if (headError) { alert('Failed to load header'); setInitialLoading(false); return; }
        setHeader({
          ...headData,
          customer_id: headData.customer_id ? String(headData.customer_id) : ''
        });

        const { data: itemData, error: itemError } = await supabase.from('purchase_items').select('*').eq('purchase_header_id', editId).order('line_no', { ascending: true });
        if (itemError) { alert('Failed to load items'); setInitialLoading(false); return; }
        setItems(itemData || []);
      } else {
        setItems([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, remark: '' }]);
      }
      setInitialLoading(false);
    };
    init();
  }, [editId]);

  const handleAddItem = () => {
    if (!canEdit) return;
    setItems([...items, { line_no: items.length + 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, remark: '' }]);
  };

  const handleRemoveItem = (index: number) => {
    if (!canEdit) return;
    const newItems = items.filter((_, i) => i !== index).map((item, idx) => ({ ...item, line_no: idx + 1 }));
    setItems(newItems);
  };

  const recalculatePurchaseItem = (item: PurchaseItem): PurchaseItem => {
    const net = (Number(item.qty) || 0) * (Number(item.net_unit_price) || 0);
    const vat = net * ((Number(item.vat_rate) || 0) / 100);
    return {
      ...item,
      net_amount: net,
      vat_amount: vat,
      amount: net + vat,
    };
  };

  const handleItemChange = (index: number, field: keyof PurchaseItem, value: any) => {
    if (!canEdit) return;
    setItems(prevItems => {
      const newItems = [...prevItems];
      const current = newItems[index];
      if (!current) return prevItems;

      const prod = field === 'product_code'
        ? products.find(p => p.id?.toString() === value?.toString())
        : null;

      let item: PurchaseItem;
      if (field === 'product_code') {
        if (!prod) return prevItems;
        item = {
          ...current,
          product_id: prod.id,
          product_code: prod.product_code || '',
          qty: current.qty || 1,
        };
      } else {
        item = { ...current, [field]: value };
      }

      if (field === 'qty' || field === 'net_unit_price' || field === 'vat_rate' || field === 'product_code') {
        item = recalculatePurchaseItem(item);
      }

      newItems[index] = item;
      return newItems;
    });
  };

  const totalNetAmount = items.reduce((sum, item) => sum + item.net_amount, 0);
  const totalVatAmount = items.reduce((sum, item) => sum + item.vat_amount, 0);
  const totalAmount = items.reduce((sum, item) => sum + item.amount, 0);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canEdit) return;
    if (!header.customer_id) return alert('Please select a supplier.');
    if (items.some(i => !i.product_id || !i.product_code || i.qty <= 0)) return alert('Please enter valid product details.');

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    let headId = editId;

    if (editId) {
      // Update Header
      const updatePayload: any = {
        purchase_date: header.purchase_date,
        customer_id: header.customer_id ? Number(header.customer_id) : null,
        status: header.status,
        attachment_url: header.attachment_url,
        remark: header.remark,
        due_date: header.due_date,
        total_net_amount: totalNetAmount,
        total_vat_amount: totalVatAmount,
        total_amount: totalAmount,
        updated_at: new Date().toISOString()
      };

      if (header.purchase_no?.trim()) {
        updatePayload.purchase_no = header.purchase_no.trim();
      }

      const { error: headError } = await supabase
        .from('purchase_headers')
        .update(updatePayload)
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
      const purchaseHeaderPayload: any = {
        purchase_date: header.purchase_date,
        customer_id: header.customer_id ? Number(header.customer_id) : null,
        status: header.status,
        attachment_url: header.attachment_url,
        remark: header.remark,
        due_date: header.due_date,
        total_net_amount: totalNetAmount,
        total_vat_amount: totalVatAmount,
        total_amount: totalAmount,
        created_by: userData.user?.id
      };

      if (header.purchase_no?.trim()) {
        purchaseHeaderPayload.purchase_no = header.purchase_no.trim();
      }

      const { data: headData, error: headError } = await supabase
        .from('purchase_headers')
        .insert([purchaseHeaderPayload])
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
        qty: item.qty,
        unit_price: item.net_unit_price,
        net_unit_price: item.net_unit_price,
        vat_rate: item.vat_rate,
        net_amount: item.net_amount,
        vat_amount: item.vat_amount,
        amount: item.amount,
        remark: item.remark
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
    if (!editId || (!isAdmin && !isManager)) return;
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

      <div className="flex-between mb-12">
        <h1 style={{ fontSize: '20px', fontWeight: 'bold' }}>
          {editId ? (isConfirmed ? 'View Purchase' : 'Edit Purchase') : 'Add Purchase Entry'}
        </h1>
        <div style={{ display: 'flex', gap: '8px' }}>
          {editId && isConfirmed && isAdmin && (
            <button type="button" className="btn btn-ghost" onClick={handleUnconfirmAction} disabled={loading} style={{ color: 'var(--danger)', border: '1px solid var(--danger)', padding: '4px 12px', fontSize: '12px' }}>
              Unconfirm (Admin)
            </button>
          )}
          {editId && !isConfirmed && (isAdmin || isManager) && (
            <button type="button" className="btn btn-secondary" onClick={handleConfirmAction} disabled={loading} style={{ padding: '4px 12px', fontSize: '12px' }}>
              Confirm Now
            </button>
          )}
          <button className="btn btn-ghost" onClick={() => router.push('/purchase/list')} style={{ padding: '4px 12px', fontSize: '12px' }}>Back to List</button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-12" style={{ padding: '12px 16px' }}>
          <div className="grid-cols-2" style={{ gap: '12px' }}>
            <div className="grid-cols-2" style={{ gap: '12px' }}>
              <div className="form-group mb-0">
                <label className="form-label">Purchase No</label>
                <input type="text" className="form-control" value={header.purchase_no} onChange={(e) => setHeader({...header, purchase_no: e.target.value})} readOnly={!canEdit} />
              </div>
              <div className="form-group mb-0">
                <label className="form-label">Date *</label>
                <input type="date" className="form-control" value={header.purchase_date} onChange={(e) => setHeader({...header, purchase_date: e.target.value})} required readOnly={!canEdit} />
              </div>
            </div>
            <div className="grid-cols-2" style={{ gap: '12px' }}>
              <div className="form-group mb-0">
                <label className="form-label">Supplier *</label>
                <select className="form-control" value={header.customer_id} onChange={(e) => setHeader({...header, customer_id: e.target.value})} required disabled={!canEdit}>
                  <option value="">Select Supplier</option>
                  {customers.map(c => <option key={c.id} value={c.id}>[{c.customer_code}] {c.customer_name}</option>)}
                </select>
              </div>
              <div className="form-group mb-0">
                <label className="form-label">Due Date</label>
                <input type="date" className="form-control" value={header.due_date || ''} onChange={(e) => setHeader({...header, due_date: e.target.value})} readOnly={!canEdit} />
              </div>
            </div>
          </div>
          <div className="grid-cols-4 mt-8" style={{ gap: '12px', alignItems: 'end' }}>
            <div className="col-span-3" style={{ gridColumn: 'span 3' }}>
              <label className="form-label">Remark / Attachment URL</label>
              <div style={{ display: 'flex', gap: '8px' }}>
                <input type="text" className="form-control" placeholder="Remark" value={header.remark} onChange={(e) => setHeader({...header, remark: e.target.value})} readOnly={!canEdit} style={{ flex: 2 }} />
                <input type="text" className="form-control" placeholder="Attachment URL" value={header.attachment_url} onChange={(e) => setHeader({...header, attachment_url: e.target.value})} readOnly={!canEdit} style={{ flex: 1 }} />
              </div>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="flex-between mb-12">
            <h3 style={{ fontSize: '15px', fontWeight: 'bold' }}>Item Details</h3>
            {canEdit && (
              <button type="button" className="btn btn-ghost" onClick={handleAddItem} style={{ color: 'var(--primary)', padding: '2px 8px', fontSize: '12px' }}>
                + Add Item
              </button>
            )}
          </div>
          
          <div className="data-table-container" style={{ overflowX: 'auto' }}>
            <table className="data-table" style={{ minWidth: '1350px', width: '100%' }}>
              <thead>
                <tr>
                  <th style={{ width: '50px', minWidth: '50px' }}>No</th>
                  <th style={{ minWidth: '350px' }}>Product Info *</th>
                  <th style={{ width: '130px', minWidth: '130px' }}>Qty *</th>
                  <th style={{ width: '170px', minWidth: '170px' }}>Net Price *</th>
                  <th style={{ width: '100px', minWidth: '100px' }}>VAT %</th>
                  <th style={{ width: '160px', minWidth: '160px' }}>VAT Amt</th>
                  <th style={{ width: '180px', minWidth: '180px' }}>Gross Amt</th>
                  <th style={{ minWidth: '150px' }}>Remark</th>
                  <th style={{ width: '80px', minWidth: '80px' }}>Action</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item, index) => (
                  <tr key={index}>
                    <td>{item.line_no}</td>
                    <td>
                      <ProductSelector 
                        products={products}
                        value={item.product_id}
                        onChange={(val) => handleItemChange(index, 'product_code', val)}
                        disabled={!canEdit}
                      />
                      <ProductDisplay 
                        product={products.find(p => p.id?.toString() === item.product_id?.toString())} 
                      />
                    </td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.qty === 0 ? '' : item.qty}
                        onChange={(e) => {
                          const val = e.target.value;
                          handleItemChange(index, 'qty', val === '' ? '' : Number(val));
                        }}
                        required
                        min="0.1"
                        step="0.1"
                        style={{ textAlign: 'right' }}
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.net_unit_price === 0 ? '' : item.net_unit_price}
                        onChange={(e) => {
                          const val = e.target.value;
                          handleItemChange(index, 'net_unit_price', val === '' ? '' : Number(val));
                        }}
                        required
                        min="0"
                        style={{ textAlign: 'right' }}
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
            <div style={{ fontSize: '15px', display: 'flex', gap: '20px' }}>
              <div>Net Total: <span style={{ fontWeight: 'normal' }}>{totalNetAmount.toLocaleString()}</span></div>
              <div>VAT Total: <span style={{ fontWeight: 'normal' }}>{totalVatAmount.toLocaleString()}</span></div>
              <div style={{ fontWeight: 'bold' }}>
                Total: <span style={{ color: 'var(--primary)', marginLeft: '8px' }}>{totalAmount.toLocaleString()}</span>
              </div>
            </div>
            {canEdit && (
              <button type="submit" className="btn btn-primary" disabled={loading} style={{ padding: '8px 24px' }}>
                {loading ? 'Saving...' : 'Save All'}
              </button>
            )}
          </div>
        </div>
      </form>
    </Shell>
  );
}

export default function PurchaseEntryPage() {
  return (
    <Suspense fallback={<Shell><div>Loading...</div></Shell>}>
      <PurchaseEntryContent />
    </Suspense>
  );
}
