'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface PriceRecord {
  id: string;
  customer_id: number;
  product_id: number;
  price: number;
  valid_from: string;
  valid_to: string;
  remark: string;
  customers?: { customer_name: string; customer_code: string };
  products?: { product_name: string; unit: string; product_code: string };
}

export default function PriceManagementPage() {
  const [prices, setPrices] = useState<PriceRecord[]>([]);
  const [customers, setCustomers] = useState<any[]>([]);
  const [products, setProducts] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  const [formData, setFormData] = useState({
    customer_id: '',
    product_id: '',
    price: 0,
    valid_from: new Date().toISOString().split('T')[0],
    valid_to: '9999-12-31',
    remark: '',
  });

  const fetchData = async () => {
    setLoading(true);
    // Fetch master data for dropdowns
    const { data: custData } = await supabase.from('customers').select('id, customer_code, customer_name').eq('status', 'active');
    const { data: prodData } = await supabase.from('products').select('id, product_code, product_name, unit').eq('status', 'active');
    setCustomers(custData || []);
    setProducts(prodData || []);

    // Fetch price records with joins
    const { data: priceData, error } = await supabase
      .from('customer_product_prices')
      .select('*, customers(customer_name, customer_code), products(product_name, unit, product_code)')
      .order('customer_id')
      .order('valid_from', { ascending: false });

    if (error) {
      console.error('Failed to fetch prices:', error);
      alert('데이터를 불러오는데 실패했습니다: ' + error.message);
      setPrices([]);
    } else {
      setPrices(priceData || []);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchData();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const payload = { 
      customer_id: Number(formData.customer_id),
      product_id: Number(formData.product_id),
      price: formData.price,
      valid_from: formData.valid_from,
      valid_to: formData.valid_to,
      remark: formData.remark
    };

    const { error } = editingId
      ? await supabase.from('customer_product_prices').update(payload).eq('id', editingId)
      : await supabase.from('customer_product_prices').insert([payload]);

    if (error) {
      console.error('Save failed:', error);
      alert('저장 실패: ' + error.message);
      return;
    }

    setShowForm(false);
    setEditingId(null);
    fetchData();
  };

  const handleEdit = (rec: PriceRecord) => {
    setEditingId(rec.id);
    setFormData({
      customer_id: String(rec.customer_id),
      product_id: String(rec.product_id),
      price: rec.price,
      valid_from: rec.valid_from,
      valid_to: rec.valid_to,
      remark: rec.remark,
    });
    setShowForm(true);
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Price Management</h1>
        <button className="btn btn-primary" onClick={() => { setEditingId(null); setShowForm(true); }}>
          Add Price
        </button>
      </div>

      {showForm && (
        <div className="card mb-24">
          <h3 style={{ marginBottom: '24px' }}>{editingId ? 'Edit Price' : 'New Price Registration'}</h3>
          <form onSubmit={handleSubmit}>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Select Customer *</label>
                <select 
                  className="form-control" 
                  value={formData.customer_id} 
                  onChange={(e) => setFormData({...formData, customer_id: e.target.value})} 
                  required
                >
                  <option value="">Select Customer</option>
                  {customers.map(c => <option key={c.id} value={c.id}>{c.customer_name} ({c.customer_code})</option>)}
                </select>
              </div>
              <div className="form-group">
                <label className="form-label">Select Product *</label>
                <select 
                  className="form-control" 
                  value={formData.product_id} 
                  onChange={(e) => setFormData({...formData, product_id: e.target.value})} 
                  required
                >
                  <option value="">Select Product</option>
                  {products.map(p => <option key={p.id} value={p.id}>{p.product_name} ({p.product_code})</option>)}
                </select>
              </div>
            </div>

            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Unit Price *</label>
                <input 
                  type="number" 
                  className="form-control" 
                  value={formData.price} 
                  onChange={(e) => setFormData({...formData, price: parseFloat(e.target.value)})} 
                  required 
                  min="0"
                />
              </div>
              <div className="form-group">
                {/* Space holder */}
              </div>
            </div>

            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Valid From *</label>
                <input 
                  type="date" 
                  className="form-control" 
                  value={formData.valid_from} 
                  onChange={(e) => setFormData({...formData, valid_from: e.target.value})} 
                  required 
                />
              </div>
              <div className="form-group">
                <label className="form-label">Valid To *</label>
                <input 
                  type="date" 
                  className="form-control" 
                  value={formData.valid_to} 
                  onChange={(e) => setFormData({...formData, valid_to: e.target.value})} 
                  required 
                />
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
              <button type="submit" className="btn btn-primary">Save</button>
            </div>
          </form>
        </div>
      )}

      <div className="card">
        <div className="data-table-container">
          <table className="data-table">
            <thead>
              <tr>
                <th>Customer</th>
                <th>Product Name</th>
                <th>Price</th>
                <th>Valid Period</th>
                <th>Remark</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : prices.map((p) => (
                <tr key={p.id}>
                  <td>{p.customers?.customer_name} ({p.customers?.customer_code})</td>
                  <td>{p.products?.product_name} ({p.products?.product_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{p.price.toLocaleString()}</td>
                  <td style={{ fontSize: '13px' }}>{p.valid_from} ~ {p.valid_to}</td>
                  <td>{p.remark}</td>
                  <td>
                    <button className="btn btn-ghost" onClick={() => handleEdit(p)}>Edit</button>
                  </td>
                </tr>
              ))}
              {prices.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
