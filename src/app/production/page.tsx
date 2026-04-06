'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useRouter } from 'next/navigation';

interface ProductionItem {
  line_no: number;
  product_code: string;
  qty: number;
  remark: string;
  current_stock?: number;
}

export default function ProductionEntryPage() {
  const router = useRouter();
  const [products, setProducts] = useState<any[]>([]);
  const [stocks, setStocks] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);

  const [header, setHeader] = useState({
    production_no: '',
    production_date: new Date().toISOString().split('T')[0],
    status: 'completed',
    remark: '',
  });

  const [inputs, setInputs] = useState<ProductionItem[]>([
    { line_no: 1, product_code: '', qty: 0, remark: '', current_stock: 0 }
  ]);

  const [outputs, setOutputs] = useState<ProductionItem[]>([
    { line_no: 1, product_code: '', qty: 0, remark: '' }
  ]);

  useEffect(() => {
    const fetchMasters = async () => {
      const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
      const { data: stockData } = await supabase.from('v_product_stock').select('*');
      setProducts(prodData || []);
      setStocks(stockData || []);
    };
    fetchMasters();
  }, []);

  const handleInputProductSelect = (index: number, productCode: string) => {
    const newInputs = [...inputs];
    const stock = stocks.find(s => s.product_code === productCode)?.stock_qty || 0;
    newInputs[index] = { ...newInputs[index], product_code: productCode, current_stock: stock };
    setInputs(newInputs);
  };

  const handleInputChange = (index: number, field: keyof ProductionItem, value: any) => {
    const newInputs = [...inputs];
    newInputs[index] = { ...newInputs[index], [field]: value };
    setInputs(newInputs);
  };

  const handleOutputChange = (index: number, field: keyof ProductionItem, value: any) => {
    const newOutputs = [...outputs];
    newOutputs[index] = { ...newOutputs[index], [field]: value };
    setOutputs(newOutputs);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    const { data: userData } = await supabase.auth.getUser();

    // 1. Insert Header
    const { data: headData, error: headError } = await supabase
      .from('production_headers')
      .insert([{ ...header, created_by: userData.user?.id }])
      .select().single();

    if (headError) {
      alert('Header 저장 실패: ' + headError.message);
      setLoading(false);
      return;
    }

    // 2. Insert Inputs
    if (inputs.some(i => i.product_code && i.qty > 0)) {
      await supabase.from('production_inputs').insert(
        inputs.filter(i => i.product_code && i.qty > 0).map(i => ({
          production_header_id: headData.id,
          line_no: i.line_no,
          product_code: i.product_code,
          qty: i.qty,
          remark: i.remark,
          created_by: userData.user?.id
        }))
      );
    }

    // 3. Insert Outputs
    if (outputs.some(o => o.product_code && o.qty > 0)) {
      await supabase.from('production_outputs').insert(
        outputs.filter(o => o.product_code && o.qty > 0).map(o => ({
          production_header_id: headData.id,
          line_no: o.line_no,
          product_code: o.product_code,
          qty: o.qty,
          remark: o.remark,
          created_by: userData.user?.id
        }))
      );
    }

    alert('저장 완료!');
    router.push('/production/list');
    setLoading(false);
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>생산 실적 등록</h1>
        <button className="btn btn-ghost" onClick={() => router.push('/production/list')}>목록으로</button>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="card mb-24">
          <h3 style={{ marginBottom: '16px' }}>생산 기본 정보</h3>
          <div className="grid-cols-2">
            <div className="form-group">
              <label className="form-label">관리 번호</label>
              <input type="text" className="form-control" value={header.production_no} onChange={(e) => setHeader({...header, production_no: e.target.value})} />
            </div>
            <div className="form-group">
              <label className="form-label">생산 일자 *</label>
              <input type="date" className="form-control" value={header.production_date} onChange={(e) => setHeader({...header, production_date: e.target.value})} required />
            </div>
          </div>
          <div className="form-group">
            <label className="form-label">비고</label>
            <input type="text" className="form-control" value={header.remark} onChange={(e) => setHeader({...header, remark: e.target.value})} />
          </div>
        </div>

        <div className="grid-cols-2">
          <div className="card">
            <div className="flex-between mb-16">
              <h3 style={{ fontSize: '18px', color: 'var(--danger)' }}>1. 투입 자재 (Inputs)</h3>
              <button type="button" className="btn btn-ghost" onClick={() => setInputs([...inputs, { line_no: inputs.length + 1, product_code: '', qty: 0, remark: '', current_stock: 0 }])}>+ 추가</button>
            </div>
            <div className="data-table-container">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>자재명</th>
                    <th style={{ width: '80px' }}>재고</th>
                    <th style={{ width: '100px' }}>수량</th>
                  </tr>
                </thead>
                <tbody>
                  {inputs.map((item, index) => (
                    <tr key={index}>
                      <td>
                        <select className="form-control" value={item.product_code} onChange={(e) => handleInputProductSelect(index, e.target.value)}>
                          <option value="">선택</option>
                          {products.filter(p => ['raw_material', 'sub_material'].includes(p.product_type)).map(p => <option key={p.product_code} value={p.product_code}>{p.product_name}</option>)}
                        </select>
                      </td>
                      <td style={{ fontSize: '12px' }}>{item.current_stock}</td>
                      <td>
                        <input type="number" className="form-control" value={item.qty} onChange={(e) => handleInputChange(index, 'qty', parseFloat(e.target.value))} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="card">
            <div className="flex-between mb-16">
              <h3 style={{ fontSize: '18px', color: 'var(--success)' }}>2. 생산 제품 (Outputs)</h3>
              <button type="button" className="btn btn-ghost" onClick={() => setOutputs([...outputs, { line_no: outputs.length + 1, product_code: '', qty: 0, remark: '' }])}>+ 추가</button>
            </div>
            <div className="data-table-container">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>제품명</th>
                    <th style={{ width: '100px' }}>생산수량</th>
                  </tr>
                </thead>
                <tbody>
                  {outputs.map((item, index) => (
                    <tr key={index}>
                      <td>
                        <select className="form-control" value={item.product_code} onChange={(e) => handleOutputChange(index, 'product_code', e.target.value)}>
                          <option value="">선택</option>
                          {products.filter(p => ['finished_goods'].includes(p.product_type)).map(p => <option key={p.product_code} value={p.product_code}>{p.product_name}</option>)}
                        </select>
                      </td>
                      <td>
                        <input type="number" className="form-control" value={item.qty} onChange={(e) => handleOutputChange(index, 'qty', parseFloat(e.target.value))} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div className="flex-between mt-24">
          <div style={{ color: 'var(--text-muted)', fontSize: '14px' }}>* 자재 투입 시 재고가 자동으로 차감되며, 제품 생산 시 재고가 자동으로 증가합니다.</div>
          <button type="submit" className="btn btn-primary" disabled={loading} style={{ padding: '12px 60px' }}>
            {loading ? '저장 중...' : '생산 실적 저장'}
          </button>
        </div>
      </form>
    </Shell>
  );
}
