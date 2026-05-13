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

interface ProductionItem {
  line_no: number;
  product_id?: number | string;
  product_code: string;
  qty: number;
  remark: string;
  current_stock?: number;
  unit_cost?: number; // Phase 4-C 추가
}

function ProductionEntryContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const editId = searchParams.get('id');
  const { isManager, isAdmin, userId } = useUserRole();

  const [products, setProducts] = useState<any[]>([]);
  const [stocks, setStocks] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [initialLoading, setInitialLoading] = useState(Boolean(editId));

  const [customers, setCustomers] = useState<any[]>([]);
  const [header, setHeader] = useState<{
    production_no: string;
    production_date: string;
    status: string;
    remark: string;
    created_by: string;
    bom_id: bigint | null;
    production_type: 'INTERNAL' | 'SUBCON';
    vendor_id: string;
    processing_fee: number;
    additional_cost: number;
    is_additional_cost_payable: boolean;
  }>({
    production_no: '',
    production_date: new Date().toISOString().split('T')[0],
    status: 'draft',
    remark: '',
    created_by: '',
    bom_id: null,
    production_type: 'INTERNAL',
    vendor_id: '',
    processing_fee: 0,
    additional_cost: 0,
    is_additional_cost_payable: true,
  });

  const canEdit = useMemo(() => {
    if (!editId) return true; // 신규 생성 시 무조건 작성 허용 (생성자 검증 불가 회피)
    // Draft 상태에서만 수정 가능하며, (관리자/팀장) 또는 (본인 작성)이어야 함
    return header.status === 'draft' && (isAdmin || isManager || (header.created_by === userId));
  }, [editId, header.status, isAdmin, isManager, header.created_by, userId]);

  const [inputs, setInputs] = useState<ProductionItem[]>([
    { line_no: 1, product_code: '', qty: 0, remark: '', current_stock: 0 }
  ]);

  const [outputs, setOutputs] = useState<ProductionItem[]>([
    { line_no: 1, product_code: '', qty: 0, remark: '' }
  ]);

  const fetchProductionData = async () => {
    setInitialLoading(true);
    const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
    const { data: stockData } = await supabase.from('v_product_stock').select('*');
    const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
    setProducts(prodData || []);
    setStocks(stockData || []);
    setCustomers(custData || []);

    if (editId) {
      const { data: headData, error: headError } = await supabase.from('production_headers').select('*').eq('id', editId).single();
      if (headError) { alert('Failed to load header'); setInitialLoading(false); return; }
      setHeader(prev => ({
        ...prev,
        ...headData,
        vendor_id: headData.vendor_id ? String(headData.vendor_id) : '',
        production_type: headData.production_type || 'INTERNAL',
        processing_fee: headData.processing_fee || 0,
        additional_cost: headData.additional_cost || 0,
        is_additional_cost_payable: headData.is_additional_cost_payable ?? true,
      }));

      const { data: inData } = await supabase.from('production_inputs').select('*').eq('production_header_id', editId).order('line_no', { ascending: true });
      setInputs(inData || []);

      const { data: outData } = await supabase.from('production_outputs').select('*').eq('production_header_id', editId).order('line_no', { ascending: true });
      setOutputs(outData || []);
    } else {
      setInputs([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, remark: '', current_stock: 0, unit_cost: 0 }]);
      setOutputs([{ line_no: 1, product_id: undefined, product_code: '', qty: 0, remark: '', unit_cost: 0 }]);
    }
    setInitialLoading(false);
  };

  useEffect(() => {
    fetchProductionData();
  }, [editId]);

  const handleInputProductSelect = (index: number, productId: string | number) => {
    if (!canEdit) return;
    const newInputs = [...inputs];
    const prod = products.find(p => p.id?.toString() === productId?.toString());
    const productCode = prod?.product_code || '';
    const stock = stocks.find(s => s.product_code === productCode)?.stock_qty || 0;
    
    newInputs[index] = { 
      ...newInputs[index], 
      product_code: productCode,
      product_id: prod?.id,
      unit_cost: prod?.moving_avg_cost || 0,
      current_stock: stock,
      qty: newInputs[index].qty || 1
    };
    setInputs(newInputs);
  };

  const handleInputChange = (index: number, field: keyof ProductionItem, value: any) => {
    if (!canEdit) return;
    const newInputs = [...inputs];
    newInputs[index] = { ...newInputs[index], [field]: value };
    setInputs(newInputs);
  };

  const handleOutputChange = async (index: number, field: keyof ProductionItem, value: any) => {
    if (!canEdit) return;
    const newOutputs = [...outputs];
    
    if (field === 'product_code') {
      const prod = products.find(p => p.id?.toString() === value?.toString());
      if (!prod) return;
      newOutputs[index] = { 
        ...newOutputs[index], 
        product_id: prod.id,
        product_code: prod.product_code || '',
        qty: newOutputs[index].qty || 1
      };
    } else {
      newOutputs[index] = { ...newOutputs[index], [field]: value };
    }
    setOutputs(newOutputs);

    // BOM 다중 대응 합산 로직 (완제품 전체 순회)
    if (field === 'product_code' || field === 'qty') {
      const allInputMovements: Record<string, { product_code: string, qty: number, bom_id: number }> = {};
      
      setLoading(true);
      for (const out of newOutputs) {
        if (out.product_code && out.qty > 0) {
          // 1. 해당 제품의 활성 BOM 조회
          const { data: bomHead } = await supabase
            .from('bom_headers')
            .select('id')
            .eq('product_id', (await supabase.from('products').select('id').eq('product_code', out.product_code).single()).data?.id)
            .eq('is_active', true)
            .single();

          if (bomHead) {
            const { data: bomItems } = await supabase
              .from('bom_items')
              .select('component_product_id, standard_qty')
              .eq('bom_header_id', bomHead.id);

            if (bomItems) {
              for (const bi of bomItems) {
                const { data: pInfo } = await supabase.from('products').select('product_code').eq('id', bi.component_product_id).single();
                if (pInfo) {
                  const requiredQty = bi.standard_qty * out.qty;
                  if (allInputMovements[pInfo.product_code]) {
                    allInputMovements[pInfo.product_code].qty += requiredQty;
                  } else {
                    allInputMovements[pInfo.product_code] = { 
                      product_code: pInfo.product_code, 
                      qty: requiredQty,
                      bom_id: bomHead.id
                    };
                  }
                }
              }
            }
          }
        }
      }

      // 최종 합산된 결과를 inputs에 반영
      const aggregatedInputs: ProductionItem[] = Object.values(allInputMovements).map((item, idx) => {
        const prod = products.find(p => p.product_code === item.product_code);
        const stock = stocks.find(s => s.product_code === item.product_code)?.stock_qty || 0;
        return {
          line_no: idx + 1,
          product_id: prod?.id,
          product_code: item.product_code,
          qty: item.qty,
          remark: `BOM auto-calc merged`,
          current_stock: stock
        };
      });

      if (aggregatedInputs.length > 0) {
        setInputs(aggregatedInputs);
      } else if (newOutputs.every(o => !o.product_code)) {
        // 완제품이 다 지워졌으면 inputs도 초기화
        setInputs([{ line_no: 1, product_code: '', qty: 0, remark: '', current_stock: 0 }]);
      }
      setLoading(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canEdit) return;

    if (!header.production_no.trim()) return alert('Please enter a production number.');

    const validInputs = inputs.filter(i => i.product_id && Number(i.qty) > 0);
    const validOutputs = outputs.filter(o => o.product_id && Number(o.qty) > 0);
    if (validInputs.length === 0) return alert('Please enter at least one valid material input.');
    if (validOutputs.length === 0) return alert('Please enter at least one valid product output.');
    if (inputs.some(i => (i.product_id || Number(i.qty) > 0) && (!i.product_id || Number(i.qty) <= 0))) return alert('Please enter valid material input details.');
    if (outputs.some(o => (o.product_id || Number(o.qty) > 0) && (!o.product_id || Number(o.qty) <= 0))) return alert('Please enter valid product output details.');

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    // 1. Save/Update Header
    const baseHeadPayload = {
      production_no: header.production_no.trim(),
      production_date: header.production_date,
      status: header.status,
      remark: header.remark,
      created_by: userData.user?.id,
      is_additional_cost_payable: header.is_additional_cost_payable,
    };
    const extendedHeadPayload = {
      ...baseHeadPayload,
      production_type: header.production_type,
      vendor_id: header.production_type === 'SUBCON' && header.vendor_id ? Number(header.vendor_id) : null,
      processing_fee: header.production_type === 'SUBCON' ? Number(header.processing_fee) || 0 : 0,
      additional_cost: Number(header.additional_cost) || 0,
    };

    const persistHeader = (payload: any) => editId
      ? supabase.from('production_headers').update(payload).eq('id', editId).select().single()
      : supabase.from('production_headers').insert([payload]).select().single();

    let { data: headData, error: headError } = await persistHeader(extendedHeadPayload);
    if (headError && headError.message.includes('schema cache')) {
      ({ data: headData, error: headError } = await persistHeader(baseHeadPayload));
    }

    if (headError) {
      if (headError.code === '42501') alert('권한이 없거나 확정된 데이터는 수정할 수 없습니다.');
      else alert('Header save failed: ' + headError.message);
      setLoading(false);
      return;
    }

    // 2. 수정 모드일 경우 기존 하위 데이터 삭제 (Refill 방식)
    if (editId) {
      await supabase.from('production_inputs').delete().eq('production_header_id', editId);
      await supabase.from('production_outputs').delete().eq('production_header_id', editId);
    }

    const docId = headData.id;

    // 3. Insert Inputs
    const rollbackDraftHeader = async () => {
      await supabase.from('production_inputs').delete().eq('production_header_id', docId);
      await supabase.from('production_outputs').delete().eq('production_header_id', docId);
      if (!editId) await supabase.from('production_headers').delete().eq('id', docId);
    };

    const { error: inputError } = await supabase.from('production_inputs').insert(
      validInputs.map(i => ({
        production_header_id: docId,
        line_no: i.line_no,
        product_id: Number(i.product_id),
        qty: Number(i.qty),
        remark: i.remark
      }))
    );
    if (inputError) {
      await rollbackDraftHeader();
      alert('Input save failed: ' + inputError.message);
      setLoading(false);
      return;
    }

    // 4. Insert Outputs
    const { error: outputError } = await supabase.from('production_outputs').insert(
      validOutputs.map(o => ({
        production_header_id: docId,
        line_no: o.line_no,
        product_id: Number(o.product_id),
        qty: Number(o.qty),
        remark: o.remark
      }))
    );
    if (outputError) {
      await rollbackDraftHeader();
      alert('Output save failed: ' + outputError.message);
      setLoading(false);
      return;
    }

    alert('Saved successfully!');
    if (!editId) router.push('/production/list');
    else fetchProductionData(); // Refresh if editing
    setLoading(false);
  };

  const handleConfirm = async () => {
    if (!editId || !isAdmin && !isManager) return;
    if (!confirm('생산 실적을 확정하시겠습니까? 확정 후에는 재고가 즉시 반영되며 수정이 제한됩니다.')) return;
    
    setLoading(true);
    const { data, error } = await supabase.rpc('confirm_production_document', { p_doc_id: editId });
    
    if (error) {
      alert('Error: ' + error.message);
    } else if (data && !data.success) {
      alert('확정 실패: ' + data.message);
    } else {
      alert(data.message || '생산 실적이 성공적으로 확정되었습니다.');
      fetchProductionData();
    }
    setLoading(false);
  };

  const handleUnconfirm = async () => {
    if (!editId || !isAdmin) return;
    const reason = prompt('확정 취소 사유를 입력해 주세요 (필수):');
    if (!reason) return;

    setLoading(true);
    const { data, error } = await supabase.rpc('unconfirm_production_document', { 
      p_doc_id: editId,
      p_reason: reason
    });

    if (error) {
      alert('Error: ' + error.message);
    } else if (data && !data.success) {
      alert('취소 실패: ' + data.message);
    } else {
      alert('생산 확정이 취소되었습니다. (Draft 환원)');
      fetchProductionData();
    }
    setLoading(false);
  };

  if (initialLoading) return <Shell><div>Loading production data...</div></Shell>;

  return (
    <Shell>
      {header.status !== 'draft' && (
        <div style={{ backgroundColor: '#fee2e2', border: '1px solid #ef4444', color: '#b91c1c', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 생산 실적은 [확정/완료] 상태로 모든 수정/삭제가 제한됩니다.</span>
        </div>
      )}
      {header.status === 'draft' && !canEdit && (
        <div style={{ backgroundColor: '#fef3c7', border: '1px solid #f59e0b', color: '#92400e', padding: '12px', borderRadius: '6px', marginBottom: '20px', fontWeight: 'bold', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>⚠️ 본 실적은 타인이 작성한 [Draft] 상태로 읽기 전용 모드입니다. (작성자 외 수정 불가)</span>
        </div>
      )}

      <div className="flex-between mb-12">
        <h1 style={{ fontSize: '20px', fontWeight: 'bold' }}>
          {editId ? (canEdit ? 'Edit Production' : 'View Production') : 'Add Production Entry'}
        </h1>
        <div style={{ display: 'flex', gap: '8px' }}>
          <button className="btn btn-ghost" onClick={() => router.push('/production/list')} style={{ padding: '4px 12px', fontSize: '12px' }}>Back to List</button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-12" style={{ padding: '12px 16px' }}>
          <div className="grid-cols-2" style={{ gap: '12px' }}>
            <div className="grid-cols-2" style={{ gap: '12px' }}>
              <div className="form-group mb-0">
                <label className="form-label">Production No</label>
                <input type="text" className="form-control" value={header.production_no} onChange={(e) => setHeader({...header, production_no: e.target.value})} readOnly={!canEdit} />
              </div>
              <div className="form-group mb-0">
                <label className="form-label">Date *</label>
                <input type="date" className="form-control" value={header.production_date} onChange={(e) => setHeader({...header, production_date: e.target.value})} required readOnly={!canEdit} />
              </div>
            </div>
            <div className="form-group mb-0">
              <label className="form-label">Remark</label>
              <input type="text" className="form-control" value={header.remark} onChange={(e) => setHeader({...header, remark: e.target.value})} readOnly={!canEdit} />
            </div>
          </div>

          <div className="grid-cols-4 mt-8" style={{ gap: '12px', alignItems: 'end' }}>
            <div className="form-group mb-0">
              <label className="form-label">Type</label>
              <select className="form-control" value={header.production_type} onChange={(e) => setHeader({...header, production_type: e.target.value as any})} disabled={!canEdit}>
                <option value="INTERNAL">INTERNAL (사내)</option>
                <option value="SUBCON">SUBCON (외주)</option>
              </select>
            </div>
            <div className="form-group mb-0">
              <label className="form-label">Vendor (Subcon)</label>
              <select className="form-control" value={header.vendor_id} onChange={(e) => setHeader({...header, vendor_id: e.target.value})} disabled={!canEdit || header.production_type !== 'SUBCON'}>
                <option value="">Select Vendor</option>
                {customers.map(c => <option key={c.id} value={c.id}>[{c.customer_code}] {c.customer_name}</option>)}
              </select>
            </div>
            <div className="form-group mb-0">
              <label className="form-label">Processing Fee</label>
              <input type="number" className="form-control" value={header.processing_fee} onChange={(e) => setHeader({...header, processing_fee: parseFloat(e.target.value) || 0})} style={{ textAlign: 'right' }} readOnly={!canEdit || header.production_type !== 'SUBCON'} />
            </div>
            <div className="form-group mb-0">
              <label className="form-label">Addl Cost</label>
              <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                <input type="number" className="form-control" style={{ flex: 1, textAlign: 'right' }} value={header.additional_cost} onChange={(e) => setHeader({...header, additional_cost: parseFloat(e.target.value) || 0})} readOnly={!canEdit} />
                <label style={{ fontSize: '11px', display: 'flex', alignItems: 'center', gap: '2px' }}>
                  <input type="checkbox" checked={header.is_additional_cost_payable} onChange={(e) => setHeader({...header, is_additional_cost_payable: e.target.checked})} disabled={!canEdit} />
                  AP
                </label>
              </div>
            </div>
          </div>
        </div>

        <div className="grid-cols-2">
          <div className="card">
            <div className="flex-between mb-16">
              <h3 style={{ fontSize: '18px', color: 'var(--danger)' }}>1. Materials (Inputs)</h3>
              {canEdit && <button type="button" className="btn btn-ghost" onClick={() => setInputs([...inputs, { line_no: inputs.length + 1, product_code: '', qty: 0, remark: '', current_stock: 0, unit_cost: 0 }])}>+ Add</button>}
            </div>
            <div className="data-table-container" style={{ overflowX: 'auto' }}>
              <table className="data-table" style={{ minWidth: '700px', width: '100%' }}>
                <thead>
                  <tr>
                    <th style={{ minWidth: '350px' }}>Material Info</th>
                    <th style={{ width: '120px', minWidth: '120px' }}>Stock</th>
                    <th style={{ width: '140px', minWidth: '140px' }}>Qty</th>
                  </tr>
                </thead>
                <tbody>
                  {inputs.map((item, index) => (
                    <tr key={index}>
                      <td>
                        <ProductSelector 
                          products={products.filter(p => ['raw_material', 'sub_material'].includes(p.product_type))}
                          value={item.product_id || ''}
                          onChange={(val) => handleInputProductSelect(index, val)}
                          disabled={!canEdit}
                        />
                        <ProductDisplay 
                          product={products.find(p => p.id?.toString() === item.product_id?.toString())} 
                        />
                      </td>
                      <td style={{ fontSize: '12px' }}>{item.current_stock}</td>
                      <td>
                        <input 
                          type="number" 
                          className="form-control" 
                          value={item.qty === 0 ? '' : item.qty} 
                          onChange={(e) => {
                            const val = e.target.value;
                            handleInputChange(index, 'qty', val === '' ? '' : Number(val));
                          }} 
                          style={{ textAlign: 'right' }}
                          readOnly={!canEdit} 
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="card">
            <div className="flex-between mb-16">
              <h3 style={{ fontSize: '18px', color: 'var(--success)' }}>2. Products (Outputs)</h3>
              {canEdit && <button type="button" className="btn btn-ghost" onClick={() => setOutputs([...outputs, { line_no: outputs.length + 1, product_code: '', qty: 0, remark: '', unit_cost: 0 }])}>+ Add</button>}
            </div>
            <div className="data-table-container" style={{ overflowX: 'auto' }}>
              <table className="data-table" style={{ minWidth: '700px', width: '100%' }}>
                <thead>
                  <tr>
                    <th style={{ minWidth: '350px' }}>Product Info</th>
                    <th style={{ width: '140px', minWidth: '140px' }}>Qty</th>
                    {header.status === 'confirmed' && <th style={{ width: '150px', minWidth: '150px' }}>생산단가(Cost)</th>}
                  </tr>
                </thead>
                <tbody>
                  {outputs.map((item, index) => (
                    <tr key={index}>
                      <td>
                        <ProductSelector 
                          products={products.filter(p => ['finished_goods'].includes(p.product_type))}
                          value={item.product_id || ''}
                          onChange={(val) => handleOutputChange(index, 'product_code', val)}
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
                            handleOutputChange(index, 'qty', val === '' ? '' : Number(val));
                          }} 
                          style={{ textAlign: 'right' }}
                          readOnly={!canEdit} 
                        />
                      </td>
                      {header.status === 'confirmed' && (
                        <td style={{ textAlign: 'right', fontWeight: 'bold', color: 'var(--primary)' }}>
                          {item.unit_cost?.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div className="flex-between" style={{ marginTop: '32px' }}>
          <div style={{ display: 'flex', gap: '12px' }}>
            {canEdit && (
              <button type="submit" className="btn btn-primary" disabled={loading}>
                {loading ? 'Saving...' : (editId ? 'Update Draft' : 'Save Draft')}
              </button>
            )}
            
            {editId && header.status === 'draft' && (isAdmin || isManager) && (
              <button type="button" className="btn btn-primary" style={{ backgroundColor: '#10b981' }} onClick={handleConfirm} disabled={loading}>
                Confirm Production
              </button>
            )}

            {editId && header.status === 'confirmed' && isAdmin && (
              <button type="button" className="btn btn-ghost" style={{ color: '#ef4444', border: '1px solid #ef4444' }} onClick={handleUnconfirm} disabled={loading}>
                Unconfirm (Admin)
              </button>
            )}
          </div>
          <button type="button" className="btn btn-ghost" onClick={() => router.push('/production/list')}>Cancel</button>
        </div>
      </form>
    </Shell>
  );
}

export default function ProductionEntryPage() {
  return (
    <Suspense fallback={<Shell><div>Loading...</div></Shell>}>
      <ProductionEntryContent />
    </Suspense>
  );
}
