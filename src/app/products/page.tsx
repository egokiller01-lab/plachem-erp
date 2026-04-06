'use client';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface Product {
  id: string;
  product_code: string;
  product_name: string;
  spec: string;
  unit: string;
  package: string;
  product_type: 'raw_material' | 'sub_material' | 'finished_goods' | 'trading_goods';
  status: 'active' | 'inactive';
  remark: string;
  stock_qty?: number;
}

const productTypeLabels = {
  raw_material: '원자재',
  sub_material: '부자재',
  finished_goods: '제품',
  trading_goods: '상품',
};

export default function ProductsPage() {
  const [products, setProducts] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);
  const [formLoading, setFormLoading] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [filterType, setFilterType] = useState<string>('all');
  const [searchQuery, setSearchQuery] = useState('');

  const [formData, setFormData] = useState({
    product_code: '',
    product_name: '',
    spec: '',
    unit: '',
    package: '',
    product_type: 'finished_goods' as Product['product_type'],
    status: 'active' as 'active' | 'inactive',
    remark: '',
  });

  const fetchProducts = async () => {
    setLoading(true);
    // Join with stock view
    const { data: productsData } = await supabase.from('products').select('*').order('product_code');
    const { data: stockData } = await supabase.from('v_product_stock').select('*');

    const mappedProducts = (productsData || []).map(p => ({
      ...p,
      stock_qty: stockData?.find(s => s.product_code === p.product_code)?.stock_qty || 0
    }));

    setProducts(mappedProducts);
    setLoading(false);
  };

  useEffect(() => {
    fetchProducts();
  }, []);

  const handleEdit = (product: Product) => {
    setEditingId(product.id);
    setFormData({
      product_code: product.product_code,
      product_name: product.product_name,
      spec: product.spec,
      unit: product.unit,
      package: product.package,
      product_type: product.product_type,
      status: product.status,
      remark: product.remark,
    });
    setShowForm(true);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFormLoading(true);

    const { data: userData } = await supabase.auth.getUser();
    const payload = {
      ...formData,
      created_by: userData.user?.id,
    };

    if (editingId) {
      await supabase.from('products').update(payload).eq('id', editingId);
    } else {
      await supabase.from('products').insert([payload]);
    }

    setFormLoading(false);
    setShowForm(false);
    setEditingId(null);
    setFormData({
      product_code: '',
      product_name: '',
      spec: '',
      unit: '',
      package: '',
      product_type: 'finished_goods',
      status: 'active',
      remark: '',
    });
    fetchProducts();
  };

  const filteredProducts = products.filter(p => {
    const matchesSearch = p.product_name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                          p.product_code.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesType = filterType === 'all' || p.product_type === filterType;
    return matchesSearch && matchesType;
  });

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>제품 관리</h1>
        <button 
          className="btn btn-primary"
          onClick={() => {
            setEditingId(null);
            setShowForm(true);
          }}
        >
          제품 등록
        </button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <input 
            type="text" 
            placeholder="제품명 또는 코드 검색..." 
            className="form-control"
            style={{ maxWidth: '300px' }}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
          <div style={{ display: 'flex', gap: '8px' }}>
            <select 
              className="form-control" 
              style={{ width: 'auto' }}
              value={filterType}
              onChange={(e) => setFilterType(e.target.value)}
            >
              <option value="all">전체 유형</option>
              {Object.entries(productTypeLabels).map(([val, label]) => (
                <option key={val} value={val}>{label}</option>
              ))}
            </select>
          </div>
        </div>
      </div>

      {showForm && (
        <div className="card mb-24">
          <h3 style={{ marginBottom: '24px' }}>{editingId ? '제품 수정' : '새 제품 등록'}</h3>
          <form onSubmit={handleSubmit}>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">제품 코드 *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.product_code} 
                  onChange={(e) => setFormData({...formData, product_code: e.target.value})} 
                  required 
                />
              </div>
              <div className="form-group">
                <label className="form-label">제품명 *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.product_name} 
                  onChange={(e) => setFormData({...formData, product_name: e.target.value})} 
                  required 
                />
              </div>
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">유형 *</label>
                <select 
                  className="form-control" 
                  value={formData.product_type} 
                  onChange={(e) => setFormData({...formData, product_type: e.target.value as any})}
                  required
                >
                  {Object.entries(productTypeLabels).map(([val, label]) => (
                    <option key={val} value={val}>{label}</option>
                  ))}
                </select>
              </div>
              <div className="form-group">
                <label className="form-label">단위</label>
                <input 
                  type="text" 
                  className="form-control" 
                  placeholder="kg, box, set..."
                  value={formData.unit} 
                  onChange={(e) => setFormData({...formData, unit: e.target.value})} 
                />
              </div>
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">기 규격 (Spec)</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.spec} 
                  onChange={(e) => setFormData({...formData, spec: e.target.value})} 
                />
              </div>
              <div className="form-group">
                <label className="form-label">포장 단위 (Package)</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.package} 
                  onChange={(e) => setFormData({...formData, package: e.target.value})} 
                />
              </div>
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">상태</label>
                <select 
                  className="form-control" 
                  value={formData.status} 
                  onChange={(e) => setFormData({...formData, status: e.target.value as any})}
                >
                  <option value="active">Active (사용)</option>
                  <option value="inactive">Inactive (미사용)</option>
                </select>
              </div>
              <div className="form-group">
                {/* Space holder */}
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">비고</label>
              <textarea 
                className="form-control" 
                value={formData.remark} 
                onChange={(e) => setFormData({...formData, remark: e.target.value})} 
              />
            </div>
            <div className="flex-between" style={{ marginTop: '32px' }}>
              <button type="button" className="btn btn-ghost" onClick={() => setShowForm(false)}>취소</button>
              <button type="submit" className="btn btn-primary" disabled={formLoading}>
                {formLoading ? '저장 중...' : '저장하기'}
              </button>
            </div>
          </form>
        </div>
      )}

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>코드</th>
                <th>제품명</th>
                <th>유형</th>
                <th>규격/포장</th>
                <th>현재 재고</th>
                <th>상태</th>
                <th>작업</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>로딩 중...</td></tr>
              ) : filteredProducts.map((product) => (
                <tr key={product.id}>
                  <td>{product.product_code}</td>
                  <td>{product.product_name}</td>
                  <td>{productTypeLabels[product.product_type]}</td>
                  <td>{product.spec} / {product.package}</td>
                  <td style={{ fontWeight: 'bold' }}>{product.stock_qty} {product.unit}</td>
                  <td>
                    <span className={`badge ${product.status === 'active' ? 'badge-success' : 'badge-danger'}`}>
                      {product.status === 'active' ? '사용중' : '미사용'}
                    </span>
                  </td>
                  <td>
                    <button className="btn btn-ghost" onClick={() => handleEdit(product)}>수정</button>
                  </td>
                </tr>
              ))}
              {filteredProducts.length === 0 && !loading && (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>검색 결과가 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
