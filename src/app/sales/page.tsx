'use client';
export const dynamic = 'force-dynamic';

import React, { useEffect, useState, Suspense, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter, useSearchParams } from 'next/navigation';
import { useUserRole } from '@/hooks/useUserRole';
import ProductSelector from '@/components/ProductSelector';
import ProductDisplay from '@/components/ProductDisplay';

interface SalesItem {
  line_no: number;
  product_id?: number | string; // bigint ID
  product_code: string;
  qty: number;
  unit_price: number; // fallback
  net_unit_price: number;
  vat_rate: number;
  net_amount: number;
  vat_amount: number;
  amount: number; // gross amount
  moving_avg_cost?: number;
  current_stock: number;
  price_source: 'auto' | 'manual';
  remark: string;
}

function SalesEntryContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const editId = searchParams.get('id');
  const { isManager, isAdmin, userId } = useUserRole();

  const [customers, setCustomers] = useState<any[]>([]);
  const [products, setProducts] = useState<any[]>([]);
  const [stocks, setStocks] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [initialLoading, setInitialLoading] = useState(Boolean(editId));

  const [header, setHeader] = useState<{
    sales_no: string;
    sales_date: string;
    customer_id: string;
    customer_code: string;
    status: string;
    attachment_url: string;
    remark: string;
    created_by?: string;
    due_date?: string;
  }>({
    sales_no: '',
    sales_date: new Date().toISOString().split('T')[0],
    customer_id: '',
    customer_code: '',
    status: 'draft',
    attachment_url: '',
    remark: '',
    due_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0], // Default +30 days
  });

  const [items, setItems] = useState<SalesItem[]>([]);
  const [creditRequest, setCreditRequest] = useState<any>(null);

  const isConfirmed = useMemo(() => header.status === 'confirmed', [header.status]);
  const canEdit = useMemo(() => {
    if (!editId) return true; // 신규 생성 시 무조건 작성 허용 (생성자 검증 불가 회피)
    // Draft 상태에서만 수정 가능하며, (관리자/팀장) 또는 (본인 작성)이어야 함
    return header.status === 'draft' && (isAdmin || isManager || header.created_by === userId);
  }, [editId, header.status, isAdmin, isManager, header.created_by, userId]);

  useEffect(() => {
    const init = async () => {
      setInitialLoading(true);
      // 1. Fetch Masters first
      const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      const { data: stockData } = await supabase.from('v_product_stock').select('*');
      
      const loadedCustomers = custData || [];
      const loadedProducts = prodData || [];
      
      setCustomers(loadedCustomers);
      setProducts(loadedProducts);
      setStocks(stockData || []);

      // 2. Then fetch existing data if editId exists
      if (editId) {
        const { data: headData, error: headError } = await supabase.from('sales_headers').select('*').eq('id', editId).single();
        if (headError) { alert('Failed to load header'); setInitialLoading(false); return; }
        
        setHeader({
          ...headData,
          customer_id: headData.customer_id?.toString() || '',
          customer_code: headData.customer_code || ''
        });

        const { data: itemData, error: itemError } = await supabase.from('sales_items').select('*').eq('sales_header_id', editId).order('line_no', { ascending: true });
        if (itemError) { alert('Failed to load items'); setInitialLoading(false); return; }
        setItems(itemData || []);

        const { data: reqData } = await supabase
          .from('credit_exception_requests')
          .select('*')
          .eq('sales_header_id', editId)
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();
        setCreditRequest(reqData || null);
      } else {
        setItems([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, current_stock: 0, price_source: 'auto', remark: '' }]);
      }
      setInitialLoading(false);
    };

    init();
  }, [editId]);

  const recalculateSalesItem = (item: SalesItem): SalesItem => {
    const net = (Number(item.qty) || 0) * (Number(item.net_unit_price) || 0);
    const vat = net * ((Number(item.vat_rate) || 0) / 100);
    return {
      ...item,
      net_amount: net,
      vat_amount: vat,
      amount: net + vat,
    };
  };

  const handleProductSelect = React.useCallback(async (index: number, productId: number | string) => {
    if (!canEdit) return;
    const prod = products.find(p => p.id?.toString() === productId?.toString());
    if (!prod) return;

    const productCode = prod.product_code || (prod as any).code || '';
    const stock = stocks.find(s => s.product_code === productCode)?.stock_qty || 0;

    // Apply the selected product immediately so quick user input cannot overwrite product_id with stale state.
    setItems(prevItems => {
      const newItems = [...prevItems];
      const current = newItems[index];
      if (!current) return prevItems;
      newItems[index] = recalculateSalesItem({
        ...current,
        product_id: prod.id,
        product_code: productCode,
        qty: current.qty || 1,
        current_stock: stock,
        moving_avg_cost: prod.moving_avg_cost || 0,
      });
      return newItems;
    });

    const { data: priceData } = await supabase
      .from('v_customer_product_current_prices')
      .select('price')
      .eq('customer_id', Number(header.customer_id))
      .eq('product_id', Number(productId))
      .maybeSingle();

    setItems(prevItems => {
      const newItems = [...prevItems];
      const current = newItems[index];
      if (!current || current.product_id?.toString() !== productId.toString()) return prevItems;
      newItems[index] = recalculateSalesItem({
        ...current,
        net_unit_price: priceData?.price || 0,
        price_source: priceData ? 'auto' : 'manual',
      });
      return newItems;
    });
  }, [canEdit, products, stocks, header.customer_id]);

  const handleItemChange = (index: number, field: keyof SalesItem, value: any) => {
    if (!canEdit) return;
    setItems(prevItems => {
      const newItems = [...prevItems];
      const current = newItems[index];
      if (!current) return prevItems;
      let item = { ...current, [field]: value };
      
      if (field === 'net_unit_price') {
        item.price_source = 'manual';
      }

      if (field === 'qty' || field === 'net_unit_price' || field === 'vat_rate') {
        item = recalculateSalesItem(item);
      }
      
      newItems[index] = item;
      return newItems;
    });
  };

  const handleAddItem = () => {
    if (!canEdit) return;
    setItems([...items, { line_no: items.length + 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, current_stock: 0, price_source: 'auto', remark: '' }]);
  };

  const handleRemoveItem = (index: number) => {
    if (!canEdit) return;
    const newItems = items.filter((_, i) => i !== index).map((item, idx) => ({ ...item, line_no: idx + 1 }));
    setItems(newItems);
  };

  const totalNetAmount = items.reduce((sum, item) => sum + item.net_amount, 0);
  const totalVatAmount = items.reduce((sum, item) => sum + item.vat_amount, 0);
  const totalAmount = items.reduce((sum, item) => sum + item.amount, 0);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canEdit) return;
    if (!header.customer_id) return alert('Please select a customer.');
    if (items.some(i => i.qty > i.current_stock)) {
      if (!confirm('Some items are low on stock. Do you want to proceed?')) return;
    }

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    let headId = editId;

    if (editId) {
      // Update Header
      const updatePayload: any = {
        sales_date: header.sales_date,
        customer_id: header.customer_id ? Number(header.customer_id) : null,
        status: header.status,
        attachment_url: header.attachment_url,
        remark: header.remark,
        total_net_amount: totalNetAmount,
        total_vat_amount: totalVatAmount,
        total_amount: totalAmount,
        updated_at: new Date().toISOString()
      };

      if (header.sales_no?.trim()) {
        updatePayload.sales_no = header.sales_no.trim();
      }

      const { error: headError } = await supabase
        .from('sales_headers')
        .update(updatePayload)
        .eq('id', editId);

      if (headError) { 
        if (headError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Update failed: ' + headError.message); 
        setLoading(false); return; 
      }

      // Delete old items
      const { error: delError } = await supabase.from('sales_items').delete().eq('sales_header_id', editId);
      if (delError) { 
        if (delError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Failed to clear old items'); 
        setLoading(false); return; 
      }
    } else {
      // Insert Header
      const salesHeaderPayload: any = {
        sales_date: header.sales_date,
        customer_id: header.customer_id ? Number(header.customer_id) : null,
        status: header.status,
        attachment_url: header.attachment_url,
        remark: header.remark,
        total_net_amount: totalNetAmount,
        total_vat_amount: totalVatAmount,
        total_amount: totalAmount,
        created_by: userData.user?.id
      };

      if (header.sales_no?.trim()) {
        salesHeaderPayload.sales_no = header.sales_no.trim();
      }

      const { data: headData, error: headError } = await supabase
        .from('sales_headers')
        .insert([salesHeaderPayload])
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
      .from('sales_items')
      .insert(items.map(item => ({
        sales_header_id: headId,
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
      if (!editId) {
        router.push(`/sales?id=${headId}`);
      } else {
        window.location.reload();
      }
    }
    setLoading(false);
  };

  const handleRequestCreditApproval = async () => {
    if (!editId) return alert('전표를 먼저 저장해주세요.');
    const reason = prompt('여신 초과 승인 요청 사유를 입력하세요:');
    if (!reason) return;

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();
    const { error } = await supabase.from('credit_exception_requests').insert([{
      sales_header_id: Number(editId),
      requested_by: userData.user?.id,
      reason: reason,
      status: 'pending'
    }]);

    if (error) alert('요청 실패: ' + error.message);
    else {
      alert('승인 요청이 관리자에게 전송되었습니다.');
      window.location.reload();
    }
    setLoading(false);
  };

  const handleConfirmAction = async () => {
    if (!editId || (!isAdmin && !isManager)) return;
    if (!confirm('매출을 확정하시겠습니까? 확정 시 재고 트랜잭션이 발생하며 수정이 제한됩니다.')) return;

    setLoading(true);
    const { data: rpc_result, error: rpc_error } = await supabase.rpc('confirm_sales_document', { p_doc_id: Number(editId) });
    
    if (rpc_error) {
      alert('System error: ' + rpc_error.message);
    } else if (rpc_result && rpc_result.success) {
      alert(rpc_result.message || '매출이 확정되었습니다.');
      window.location.reload();
    } else if (rpc_result?.error_type === 'CREDIT_EXCEEDED') {
      if (confirm(rpc_result.message + '\n\n지금 관리자에게 예외 승인을 요청하시겠습니까?')) {
        handleRequestCreditApproval();
      }
    } else {
      alert('확정 실패: ' + (rpc_result?.message || '알 수 없는 오류가 발생했습니다.'));
    }
    setLoading(false);
  };

  const handleUnconfirmAction = async () => {
    if (!editId || !isAdmin) return;
    const reason = prompt('확정 취소 사유를 입력해주세요 (필수):');
    if (!reason) return alert('사유를 입력해야 취소가 가능합니다.');

    if (!confirm('확정 취소 시 전표가 Draft 상태로 돌아가며 매출원가 데이터가 초기화됩니다. 진행하시겠습니까?')) return;

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();
    const { data, error } = await supabase.rpc('unconfirm_sales_document', { 
      p_doc_id: Number(editId),
      p_reason: reason,
      p_user_uuid: userData.user?.id
    });

    if (error) {
      alert('System error: ' + error.message);
    } else if (data?.success) {
      alert(data.message || '확정 취소가 완료되었습니다.');
      window.location.reload();
    } else {
      alert('확정 취소 실패: ' + (data?.message || '권한이 없거나 이미 수금된 건입니다.'));
    }
    setLoading(false);
  };

  if (initialLoading) return <Shell><div>Loading record data...</div></Shell>;

  return (
    <Shell>
      {creditRequest && (
        <div style={{ backgroundColor: '#eff6ff', border: '1px solid #3b82f6', color: '#1e40af', padding: '12px', borderRadius: '6px', marginBottom: '12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <span className={`badge ${
              creditRequest.status === 'approved' ? 'badge-success' : 
              creditRequest.status === 'rejected' ? 'badge-danger' : 
              creditRequest.status === 'void' ? 'badge-ghost' : 'badge-warning'
            }`} style={{ marginRight: '12px' }}>
              여신 승인: {creditRequest.status.toUpperCase()}
            </span>
            <span style={{ fontSize: '14px' }}>
              {creditRequest.status === 'pending' ? '관리자 승인 대기 중입니다.' : 
               creditRequest.status === 'approved' ? '승인되었습니다. 이제 확정이 가능합니다.' : 
               `반려/무효화: ${creditRequest.approver_comment || '사유 없음'}`}
            </span>
          </div>
          {creditRequest.status === 'rejected' && (
            <button className="btn btn-sm btn-primary" onClick={handleRequestCreditApproval}>재요청</button>
          )}
        </div>
      )}
      <div className="flex-between mb-12">
        <h1 style={{ fontSize: '20px', fontWeight: 'bold' }}>
          {editId ? (isConfirmed ? 'View Sales' : 'Edit Sales') : 'Add Sales Entry'}
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
          <button className="btn btn-ghost" onClick={() => router.push('/sales/list')} style={{ padding: '4px 12px', fontSize: '12px' }}>Back to List</button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-12" style={{ padding: '12px 16px' }}>
          <div className="grid-cols-2" style={{ gap: '12px' }}>
            <div className="grid-cols-2" style={{ gap: '12px' }}>
              <div className="form-group mb-0">
                <label className="form-label">Sales No</label>
                <input type="text" className="form-control" value={header.sales_no} onChange={(e) => setHeader({...header, sales_no: e.target.value})} readOnly={!canEdit} />
              </div>
              <div className="form-group mb-0">
                <label className="form-label">Sales Date *</label>
                <input type="date" className="form-control" value={header.sales_date} onChange={(e) => setHeader({...header, sales_date: e.target.value})} required readOnly={!canEdit} />
              </div>
            </div>
            <div className="grid-cols-2" style={{ gap: '12px' }}>
              <div className="form-group mb-0">
                <label className="form-label">Customer *</label>
                <select className="form-control" value={header.customer_id} onChange={(e) => {
                  const cust = customers.find(c => c.id.toString() === e.target.value);
                  setHeader({...header, customer_id: e.target.value, customer_code: cust?.customer_code || ''});
                }} required disabled={!canEdit}>
                  <option value="">Select Customer</option>
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
            <table className="data-table" style={{ minWidth: '1300px', width: '100%' }}>
              <thead>
                <tr>
                  <th style={{ width: '50px', minWidth: '50px' }}>No</th>
                  <th style={{ minWidth: '350px' }}>Product Info *</th>
                  <th style={{ width: '100px', minWidth: '100px' }}>Stock</th>
                  <th style={{ width: '130px', minWidth: '130px' }}>Qty *</th>
                  <th style={{ width: '170px', minWidth: '170px' }}>Net Price *</th>
                  <th style={{ width: '100px', minWidth: '100px' }}>VAT %</th>
                  <th style={{ width: '160px', minWidth: '160px' }}>VAT Amt</th>
                  <th style={{ width: '180px', minWidth: '180px' }}>Gross Amt</th>
                  <th style={{ width: '90px', minWidth: '90px' }}>Source</th>
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
                        onChange={(val) => handleProductSelect(index, val)}
                        disabled={!header.customer_id || !canEdit}
                      />
                      <ProductDisplay 
                        product={products.find(p => p.id?.toString() === item.product_id?.toString())} 
                      />
                    </td>
                    <td style={{ textAlign: 'center', fontSize: '13px' }}>{item.current_stock}</td>
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
                        style={{ 
                          textAlign: 'right',
                          borderColor: Number(item.qty) > item.current_stock ? 'var(--danger)' : '' 
                        }}
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
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
                        {item.moving_avg_cost !== undefined && (
                          <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
                            MAC: {item.moving_avg_cost.toLocaleString()}
                          </div>
                        )}
                      </div>
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
                      <span className={`badge ${item.price_source === 'auto' ? 'badge-success' : 'badge-warning'}`}>
                        {item.price_source === 'auto' ? 'Auto' : 'Manual'}
                      </span>
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

          <div className="flex-between mt-24">
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

export default function SalesEntryPage() {
  return (
    <Suspense fallback={<Shell><div>Loading...</div></Shell>}>
      <SalesEntryContent />
    </Suspense>
  );
}
