'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter } from 'next/navigation';

interface PurchaseItem {
  line_no: number;
  product_code: string;
  qty: number;
  unit_price: number;
  amount: number;
  remark: string;
}

export default function PurchaseEntryPage() {
  const router = useRouter();
  const [customers, setCustomers] = useState<any[]>([]);
  const [products, setProducts] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const [header, setHeader] = useState({
    purchase_no: '',
    purchase_date: new Date().toISOString().split('T')[0],
    customer_code: '',
    status: 'completed',
    remark: '',
  });

  const [items, setItems] = useState<PurchaseItem[]>([
    { line_no: 1, product_code: '', qty: 0, unit_price: 0, amount: 0, remark: '' }
  ]);

  useEffect(() => {
    const fetchMasters = async () => {
      const { data: custData } = await supabase.from('customers').select('*').eq('status', 'active');
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      setCustomers(custData || []);
      setProducts(prodData || []);
    };
    fetchMasters();
  }, []);

  const handleAddItem = () => {
    setItems([...items, { line_no: items.length + 1, product_code: '', qty: 0, unit_price: 0, amount: 0, remark: '' }]);
  };

  const handleRemoveItem = (index: number) => {
    const newItems = items.filter((_, i) => i !== index).map((item, idx) => ({ ...item, line_no: idx + 1 }));
    setItems(newItems);
  };

  const handleItemChange = (index: number, field: keyof PurchaseItem, value: any) => {
    const newItems = [...items];
    const item = { ...newItems[index], [field]: value };
    
    if (field === 'qty' || field === 'unit_price') {
      item.amount = item.qty * item.unit_price;
    }
    
    newItems[index] = item;
    setItems(newItems);
  };

  const totalAmount = items.reduce((sum, item) => sum + item.amount, 0);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!header.customer_code) return alert('거래처를 선택해주세요.');
    if (items.some(i => !i.product_code || i.qty <= 0)) return alert('제품 정보를 올바르게 입력해주세요.');

    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    // 1. Insert Header
    const { data: headData, error: headError } = await supabase
      .from('purchase_headers')
      .insert([{
        ...header,
        total_amount: totalAmount,
        created_by: userData.user?.id
      }])
      .select()
      .single();

    if (headError) {
      alert('Header 저장 실패: ' + headError.message);
      setLoading(false);
      return;
    }

    // 2. Insert Items
    const { error: itemError } = await supabase
      .from('purchase_items')
      .insert(items.map(item => ({
        purchase_header_id: headData.id,
        ...item,
        created_by: userData.user?.id
      })));

    if (itemError) {
      alert('Item 저장 실패: ' + itemError.message);
    } else {
      alert('저장 완료!');
      router.push('/purchase/list');
    }
    setLoading(false);
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>구매 입고 등록</h1>
        <button className="btn btn-ghost" onClick={() => router.push('/purchase/list')}>목록으로</button>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-24">
          <h3 style={{ marginBottom: '16px' }}>기본 정보</h3>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">관리 번호 (Purchase No)</label>
              <input 
                type="text" 
                className="form-control" 
                placeholder="자동 생성 또는 직접 입력"
                value={header.purchase_no}
                onChange={(e) => setHeader({...header, purchase_no: e.target.value})}
              />
            </div>
            <div className="form-group">
              <label className="form-label">입고 일자 *</label>
              <input 
                type="date" 
                className="form-control" 
                value={header.purchase_date}
                onChange={(e) => setHeader({...header, purchase_date: e.target.value})}
                required
              />
            </div>
          </div>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">공급처 (거래처) *</label>
              <select 
                className="form-control" 
                value={header.customer_code}
                onChange={(e) => setHeader({...header, customer_code: e.target.value})}
                required
              >
                <option value="">공급처 선택</option>
                {customers.map(c => <option key={c.customer_code} value={c.customer_code}>{c.customer_name}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label">비고</label>
              <input 
                type="text" 
                className="form-control" 
                value={header.remark}
                onChange={(e) => setHeader({...header, remark: e.target.value})}
              />
            </div>
          </div>
        </div>

        <div className="card">
          <div className="flex-between mb-24">
            <h3 style={{ fontSize: '18px', fontWeight: '600' }}>품목 상세</h3>
            <button type="button" className="btn btn-ghost" onClick={handleAddItem} style={{ color: 'var(--primary)' }}>
              + 품목 추가
            </button>
          </div>
          
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th style={{ width: '60px' }}>No</th>
                  <th>제품명 *</th>
                  <th style={{ width: '120px' }}>수량 *</th>
                  <th style={{ width: '150px' }}>단가 *</th>
                  <th style={{ width: '150px' }}>금액</th>
                  <th>비고</th>
                  <th style={{ width: '80px' }}>작업</th>
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
                      >
                        <option value="">제품 선택</option>
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
                      />
                    </td>
                    <td>
                      <input 
                        type="number" 
                        className="form-control" 
                        value={item.unit_price}
                        onChange={(e) => handleItemChange(index, 'unit_price', parseFloat(e.target.value))}
                        required
                        min="0"
                      />
                    </td>
                    <td style={{ fontWeight: 'bold' }}>{item.amount.toLocaleString()}</td>
                    <td>
                      <input 
                        type="text" 
                        className="form-control"
                        value={item.remark}
                        onChange={(e) => handleItemChange(index, 'remark', e.target.value)}
                      />
                    </td>
                    <td>
                      <button 
                        type="button" 
                        className="btn btn-ghost" 
                        style={{ color: 'var(--danger)' }}
                        onClick={() => handleRemoveItem(index)}
                        disabled={items.length === 1}
                      >
                        삭제
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex-between mt-24" style={{ padding: '0 16px' }}>
            <div style={{ fontSize: '18px', fontWeight: 'bold' }}>
              총 합계 금액: <span style={{ color: 'var(--primary)', marginLeft: '12px' }}>{totalAmount.toLocaleString()} 원</span>
            </div>
            <button type="submit" className="btn btn-primary" disabled={loading} style={{ padding: '12px 40px' }}>
              {loading ? '저장 중...' : '전체 저장'}
            </button>
          </div>
        </div>
      </form>
    </Shell>
  );
}
