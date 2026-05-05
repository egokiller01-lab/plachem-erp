'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import ProductDisplay from '@/components/ProductDisplay';

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
  raw_material: 'Raw Material',
  sub_material: 'Sub Material',
  finished_goods: 'Finished Goods',
  trading_goods: 'Trading Goods',
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
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Products</h1>
        <button 
          className="btn btn-primary"
          onClick={() => {
            setEditingId(null);
            setShowForm(true);
          }}
        >
          Add Product
        </button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <input 
            type="text" 
            placeholder="Search product name or code..." 
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
              <option value="all">All Types</option>
              {Object.entries(productTypeLabels).map(([val, label]) => (
                <option key={val} value={val}>{label}</option>
              ))}
            </select>
          </div>
        </div>
      </div>

      {showForm && (
        <div className="card mb-24">
          <h3 style={{ marginBottom: '24px' }}>{editingId ? 'Edit Product' : 'New Product'}</h3>
          <form onSubmit={handleSubmit}>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Product Code *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.product_code} 
                  onChange={(e) => setFormData({...formData, product_code: e.target.value})} 
                  required 
                />
              </div>
              <div className="form-group">
                <label className="form-label">Product Name *</label>
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
                <label className="form-label">Type *</label>
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
                <label className="form-label">Unit</label>
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
                <label className="form-label">Spec</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.spec} 
                  onChange={(e) => setFormData({...formData, spec: e.target.value})} 
                />
              </div>
              <div className="form-group">
                <label className="form-label">Package</label>
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
                <label className="form-label">Status</label>
                <select 
                  className="form-control" 
                  value={formData.status} 
                  onChange={(e) => setFormData({...formData, status: e.target.value as any})}
                >
                  <option value="active">Active</option>
                  <option value="inactive">Inactive</option>
                </select>
              </div>
              <div className="form-group">
                {/* Space holder */}
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">Remark</label>
              <textarea 
                className="form-control" 
                value={formData.remark} 
                onChange={(e) => setFormData({...formData, remark: e.target.value})} 
              />
            </div>
            <div className="flex-between" style={{ marginTop: '32px' }}>
              <button type="button" className="btn btn-ghost" onClick={() => setShowForm(false)}>Cancel</button>
              <button type="submit" className="btn btn-primary" disabled={formLoading}>
                {formLoading ? 'Saving...' : 'Save'}
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
                <th>Code</th>
                <th>Product Info (Name / Type / Spec)</th>
                <th>Current Stock</th>
                <th>Status</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={5} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : filteredProducts.map((product) => (
                <tr key={product.id}>
                  <td>{product.product_code}</td>
                  <td><ProductDisplay product={product} /></td>
                  <td style={{ fontWeight: 'bold' }}>{product.stock_qty} {product.unit}</td>
                  <td>
                    <span className={`badge ${product.status === 'active' ? 'badge-success' : 'badge-danger'}`}>
                      {product.status === 'active' ? 'Active' : 'Inactive'}
                    </span>
                  </td>
                  <td>
                    <button className="btn btn-ghost" onClick={() => handleEdit(product)}>Edit</button>
                  </td>
                </tr>
              ))}
              {filteredProducts.length === 0 && !loading && (
                <tr><td colSpan={5} style={{ textAlign: 'center' }}>No results found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
