'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter, useSearchParams } from 'next/navigation';
import { useUserRole } from '@/hooks/useUserRole';
import { useMemo } from 'react';

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

export default function SalesEntryPage() {
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
    // Draft 상태에서만 수정 가능하며, (관리자/팀장) 또는 (본인 작성)이어야 함
    return header.status === 'draft' && (isAdmin || isManager || header.created_by === userId);
  }, [header.status, isAdmin, isManager, header.created_by, userId]);

  useEffect(() => {
    const fetchMasters = async () => {
      const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      const { data: stockData } = await supabase.from('v_product_stock').select('*');
      setCustomers(custData || []);
      setProducts(prodData || []);
      setStocks(stockData || []);
    };

    const fetchExistingData = async () => {
      if (!editId) {
        setItems([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, unit_price: 0, net_unit_price: 0, vat_rate: 10, net_amount: 0, vat_amount: 0, amount: 0, current_stock: 0, price_source: 'auto', remark: '' }]);
        setInitialLoading(false);
        return;
      }
      setInitialLoading(true);
      const { data: headData, error: headError } = await supabase.from('sales_headers').select('*').eq('id', editId).single();
      if (headError) { alert('Failed to load header'); setInitialLoading(false); return; }
      
      const cust = customers.find(c => c.id === headData.customer_id);
      setHeader({
        ...headData,
        customer_id: headData.customer_id?.toString() || '',
        customer_code: headData.customer_code || ''
      });

      const { data: itemData, error: itemError } = await supabase.from('sales_items').select('*').eq('sales_header_id', editId).order('line_no', { ascending: true });
      if (itemError) { alert('Failed to load items'); setInitialLoading(false); return; }
      setItems(itemData || []);

      // Fetch Credit Request
      const { data: reqData } = await supabase
        .from('credit_exception_requests')
        .select('*')
        .eq('sales_header_id', editId)
        .order('created_at', { ascending: false })
        .limit(1)
        .single();
      setCreditRequest(reqData || null);

      setInitialLoading(false);
    };

    fetchMasters();
    fetchExistingData();
  }, [editId]);

  const handleProductSelect = async (index: number, productCode: string) => {
    if (!canEdit) return;
    const newItems = [...items];
    const prod = products.find(p => p.product_code === productCode);
    const item = { ...newItems[index], product_code: productCode, product_id: prod?.id };
    
    // Get stock
    const stock = stocks.find(s => s.product_code === productCode)?.stock_qty || 0;
    item.current_stock = stock;

    // Get current price from view
    const { data: priceData } = await supabase
      .from('v_customer_product_current_prices')
      .select('price')
      .eq('customer_code', header.customer_code)
      .eq('product_code', productCode)
      .single();

    if (priceData) {
      item.net_unit_price = priceData.price;
      item.price_source = 'auto';
    } else {
      item.net_unit_price = 0;
      item.price_source = 'manual';
    }

    const { data: prodData } = await supabase.from('products').select('moving_avg_cost').eq('product_code', productCode).single();
    if (prodData) {
      item.moving_avg_cost = prodData.moving_avg_cost;
    }

    const net = item.qty * item.net_unit_price;
    const vat = net * (item.vat_rate / 100);
    item.net_amount = net;
    item.vat_amount = vat;
    item.amount = net + vat;
    newItems[index] = item;
    setItems(newItems);
  };

  const handleItemChange = (index: number, field: keyof SalesItem, value: any) => {
    if (!canEdit) return;
    const newItems = [...items];
    const item = { ...newItems[index], [field]: value };
    
    if (field === 'net_unit_price') {
      item.price_source = 'manual';
    }

    if (field === 'qty' || field === 'net_unit_price' || field === 'vat_rate') {
      const net = item.qty * item.net_unit_price;
      const vat = net * (item.vat_rate / 100);
      item.net_amount = net;
      item.vat_amount = vat;
      item.amount = net + vat;
    }
    
    newItems[index] = item;
    setItems(newItems);
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
      const { error: headError } = await supabase
        .from('sales_headers')
        .update({
          sales_no: header.sales_no,
          sales_date: header.sales_date,
          customer_id: header.customer_id ? Number(header.customer_id) : null,
          status: header.status,
          attachment_url: header.attachment_url,
          remark: header.remark,
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
      const { error: delError } = await supabase.from('sales_items').delete().eq('sales_header_id', editId);
      if (delError) { 
        if (delError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
        else alert('Failed to clear old items'); 
        setLoading(false); return; 
      }
    } else {
      // Insert Header
      const { data: headData, error: headError } = await supabase
        .from('sales_headers')
        .insert([{
          sales_no: header.sales_no,
          sales_date: header.sales_date,
          customer_id: header.customer_id ? Number(header.customer_id) : null,
          status: header.status,
          attachment_url: header.attachment_url,
          remark: header.remark,
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
      .from('sales_items')
      .insert(items.map(item => ({
        sales_header_id: headId,
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
        price_source: item.price_source,
        remark: item.remark,
        created_by: userData.user?.id
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
      {header.status !== 'draft' && (
        <div style={{ backgroundColor: '#fee2e2', border: '1px solid #ef4444', color: '#b91c1c', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 전표는 [{header.status === 'confirmed' ? '확정' : '취소'}] 상태로 수량이 이미 매출 처리되었습니다. 모든 수정/삭제가 제한됩니다.</span>
        </div>
      )}
      {header.status === 'draft' && !canEdit && (
        <div style={{ backgroundColor: '#fef3c7', border: '1px solid #f59e0b', color: '#92400e', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 전표는 타인이 작성한 [Draft] 상태로 읽기 전용 모드입니다. (작성자 외 수정 불가)</span>
        </div>
      )}

      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>
          {editId ? (isConfirmed ? 'View Sales' : 'Edit Sales') : 'Add Sales Entry'}
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
          <button className="btn btn-ghost" onClick={() => router.push('/sales/list')}>Back to List</button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-24">
          <h3 style={{ marginBottom: '16px' }}>Basic Info</h3>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">Sales No</label>
              <input 
                type="text" 
                className="form-control" 
                placeholder="Auto-generated or enter manually"
                value={header.sales_no}
                onChange={(e) => setHeader({...header, sales_no: e.target.value})}
                readOnly={!canEdit}
              />
            </div>
            <div className="form-group">
              <label className="form-label">Sales Date *</label>
              <input 
                type="date" 
                className="form-control" 
                value={header.sales_date}
                onChange={(e) => setHeader({...header, sales_date: e.target.value})}
                required
                readOnly={!canEdit}
              />
            </div>
          </div>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">Customer *</label>
              <select 
                className="form-control" 
                value={header.customer_id}
                onChange={(e) => {
                  const cust = customers.find(c => c.id.toString() === e.target.value);
                  setHeader({...header, customer_id: e.target.value, customer_code: cust?.customer_code || ''});
                }}
                required
                disabled={!canEdit}
              >
                <option value="">Select Customer</option>
                {customers.map(c => <option key={c.id} value={c.id}>[{c.customer_code}] {c.customer_name}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">Due Date (수금기한)</label>
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
            <div className="form-group">
              <label className="form-label">Remark</label>
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
                  <th style={{ width: '90px' }}>Stock</th>
                  <th style={{ width: '90px' }}>Qty *</th>
                  <th style={{ width: '130px' }}>Net Price *</th>
                  <th style={{ width: '80px' }}>VAT %</th>
                  <th style={{ width: '80px' }}>VAT Amt</th>
                  <th style={{ width: '130px' }}>Gross Amt</th>
                  <th>Price Source</th>
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
                        onChange={(e) => handleProductSelect(index, e.target.value)}
                        required
                        disabled={!header.customer_id || !canEdit}
                      >
                        <option value="">Select Product</option>
                        {products.map(p => <option key={p.product_code} value={p.product_code}>{p.product_name}</option>)}
                      </select>
                    </td>
                    <td style={{ textAlign: 'center', fontSize: '13px' }}>{item.current_stock}</td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.qty}
                        onChange={(e) => handleItemChange(index, 'qty', parseFloat(e.target.value))}
                        required
                        min="0.1"
                        step="0.1"
                        style={{ borderColor: item.qty > item.current_stock ? 'var(--danger)' : '' }}
                        readOnly={!canEdit}
                      />
                    </td>
                    <td>
                      <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                        <input 
                          type="number" 
                          className="form-control" 
                          value={item.net_unit_price}
                          onChange={(e) => handleItemChange(index, 'net_unit_price', parseFloat(e.target.value))}
                          required
                          min="0"
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
