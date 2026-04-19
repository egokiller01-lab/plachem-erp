'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';
import { useRouter } from 'next/navigation';

interface Product {
  id: number;
  product_code: string;
  product_name: string;
  moving_avg_cost: number;
}

interface AdjustmentRecord {
  id: number;
  adj_no: string;
  adj_date: string;
  adj_type: string;
  product_id: number;
  adj_qty: number;
  adj_value: number;
  reason: string;
  created_at: string;
  products: {
    product_name: string;
    product_code: string;
  };
}

export default function AdjustmentPage() {
  const router = useRouter();
  const { isAdmin, loading: roleLoading } = useUserRole();
  const [products, setProducts] = useState<Product[]>([]);
  const [history, setHistory] = useState<AdjustmentRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const [form, setForm] = useState({
    product_id: '',
    adj_type: 'STOCK', // STOCK, COST, BOTH
    adj_qty: 0,
    adj_value: 0,
    reason: '',
    adj_date: new Date().toISOString().split('T')[0]
  });

  const fetchData = async () => {
    setLoading(true);
    const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
    const { data: histData } = await supabase
      .from('inventory_adjustments')
      .select('*, products(product_name, product_code)')
      .order('created_at', { ascending: false })
      .limit(20);
    
    setProducts(prodData || []);
    setHistory(histData || []);
    setLoading(false);
  };

  useEffect(() => {
    fetchData();
  }, []);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.product_id || !form.reason) return alert('제품과 사유를 입력해주세요.');
    if (form.adj_qty === 0 && form.adj_value === 0) return alert('수정할 수량 또는 금액 중 하나는 0이 아니어야 합니다.');

    if (!confirm('조정 사항을 저장하시겠습니까? 저장 즉시 재고와 단가(MAC)에 반영됩니다.')) return;

    setSaving(true);
    const { data: userData } = await supabase.auth.getUser();
    
    // 1. Insert Adjustment
    const { data: adjData, error: adjError } = await supabase
      .from('inventory_adjustments')
      .insert([{
        adj_no: `ADJ-${Date.now()}`,
        adj_date: form.adj_date,
        adj_type: form.adj_type,
        product_id: Number(form.product_id),
        adj_qty: form.adj_qty,
        adj_value: form.adj_value,
        reason: form.reason,
        created_by: userData.user?.id
      }])
      .select()
      .single();

    if (adjError) {
      alert('저장 실패: ' + adjError.message);
      setSaving(false);
      return;
    }

    // 2. Trigger MAC Recalculation (RPC)
    const { error: rpcError } = await supabase.rpc('recalculate_mac_for_product', { 
      p_product_id: Number(form.product_id) 
    });

    if (rpcError) {
      alert('일부 로직 반영 실패: ' + rpcError.message);
    } else {
      alert('성공적으로 조정되었습니다!');
      setForm({
        product_id: '',
        adj_type: 'STOCK',
        adj_qty: 0,
        adj_value: 0,
        reason: '',
        adj_date: new Date().toISOString().split('T')[0]
      });
      fetchData();
    }
    setSaving(false);
  };

  if (roleLoading || loading) return <Shell><div>로딩 중...</div></Shell>;
  if (!isAdmin) return <Shell><div>권한이 없습니다. 관리자만 접근 가능합니다.</div></Shell>;

  const selectedProduct = products.find(p => p.id.toString() === form.product_id);

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Inventory Adjustment</h1>
        <button className="btn btn-ghost" onClick={() => router.push('/inventory')}>Back to Inventory</button>
      </div>

      <div className="grid-cols-2" style={{ alignItems: 'start', gap: '24px' }}>
        {/* 입력 폼 */}
        <div className="card">
          <h3 style={{ marginBottom: '16px' }}>New Adjustment</h3>
          <form onSubmit={handleSave}>
            <div className="form-group">
              <label className="form-label">Product *</label>
              <select 
                className="form-control" 
                value={form.product_id} 
                onChange={e => setForm({...form, product_id: e.target.value})}
              >
                <option value="">Select Product</option>
                {products.map(p => <option key={p.id} value={p.id}>[{p.product_code}] {p.product_name}</option>)}
              </select>
            </div>

            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Type</label>
                <select 
                  className="form-control" 
                  value={form.adj_type} 
                  onChange={e => setForm({...form, adj_type: e.target.value})}
                >
                  <option value="STOCK">STOCK Only</option>
                  <option value="COST">COST Only</option>
                  <option value="BOTH">STOCK + COST</option>
                </select>
              </div>
              <div className="form-group">
                <label className="form-label">Date</label>
                <input 
                  type="date" 
                  className="form-control" 
                  value={form.adj_date} 
                  onChange={e => setForm({...form, adj_date: e.target.value})}
                />
              </div>
            </div>

            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Qty Adjustment (+/-)</label>
                <input 
                  type="number" 
                  className="form-control" 
                  value={form.adj_qty} 
                  onChange={e => setForm({...form, adj_qty: parseFloat(e.target.value)})}
                  disabled={form.adj_type === 'COST'}
                />
              </div>
              <div className="form-group">
                <label className="form-label">Value Adjustment (+/-)</label>
                <input 
                  type="number" 
                  className="form-control" 
                  value={form.adj_value} 
                  onChange={e => setForm({...form, adj_value: parseFloat(e.target.value)})}
                  disabled={form.adj_type === 'STOCK'}
                />
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Reason *</label>
              <textarea 
                className="form-control" 
                rows={3} 
                value={form.reason}
                onChange={e => setForm({...form, reason: e.target.value})}
                placeholder="과거 단가 오기입, 수량 누락 등 구체적인 사유를 입력하세요."
              />
            </div>

            {selectedProduct && (
              <div style={{ backgroundColor: '#f8fafc', padding: '12px', borderRadius: '4px', marginBottom: '16px', fontSize: '14px' }}>
                <p>Current MAC: <strong>{selectedProduct.moving_avg_cost?.toLocaleString()}</strong></p>
                <p style={{ color: 'var(--text-muted)' }}>※ 조정 수량/금액이 반영되어 MAC가 실시간 재계산됩니다.</p>
              </div>
            )}

            <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={saving}>
              {saving ? 'Processing...' : 'Save Adjustment'}
            </button>
          </form>
        </div>

        {/* 최근 이력 */}
        <div className="card">
          <h3 style={{ marginBottom: '16px' }}>Recent History</h3>
          <div className="data-table-container">
            <table className="data-table" style={{ fontSize: '13px' }}>
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Product</th>
                  <th>Type</th>
                  <th style={{ textAlign: 'right' }}>Qty</th>
                  <th style={{ textAlign: 'right' }}>Value</th>
                  <th>Reason</th>
                </tr>
              </thead>
              <tbody>
                {history.map(h => (
                  <tr key={h.id}>
                    <td>{h.adj_date}</td>
                    <td>{h.products?.product_name}</td>
                    <td><span className="badge">{h.adj_type}</span></td>
                    <td style={{ textAlign: 'right', color: h.adj_qty >= 0 ? 'var(--primary)' : 'var(--danger)' }}>
                      {h.adj_qty > 0 ? '+' : ''}{h.adj_qty}
                    </td>
                    <td style={{ textAlign: 'right' }}>{h.adj_value.toLocaleString()}</td>
                    <td title={h.reason} style={{ maxWidth: '100px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {h.reason}
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
