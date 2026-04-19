'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';

interface Customer {
  id: string;
  customer_code: string;
  customer_name: string;
  business_no: string;
  phone: string;
  address: string;
  contact_person: string;
  status: 'active' | 'inactive';
  remark: string;
  credit_limit: number;
  is_credit_unlimited: boolean;
}

export default function CustomersPage() {
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [loading, setLoading] = useState(true);
  const [formLoading, setFormLoading] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [filterStatus, setFilterStatus] = useState<'all' | 'active' | 'inactive'>('active');
  const [searchQuery, setSearchQuery] = useState('');

  const [formData, setFormData] = useState({
    customer_code: '',
    customer_name: '',
    business_no: '',
    phone: '',
    address: '',
    contact_person: '',
    status: 'active' as 'active' | 'inactive',
    remark: '',
    credit_limit: 0,
    is_credit_unlimited: false,
  });

  const fetchCustomers = async () => {
    setLoading(true);
    let query = supabase.from('customers').select('*');
    if (filterStatus !== 'all') {
      query = query.eq('status', filterStatus);
    }
    const { data } = await query.order('customer_name');
    setCustomers(data || []);
    setLoading(false);
  };

  useEffect(() => {
    fetchCustomers();
  }, [filterStatus]);

  const handleEdit = (customer: Customer) => {
    setEditingId(customer.id);
    setFormData({
      customer_code: customer.customer_code,
      customer_name: customer.customer_name,
      business_no: customer.business_no,
      phone: customer.phone,
      address: customer.address,
      contact_person: customer.contact_person,
      status: customer.status,
      remark: customer.remark,
      credit_limit: customer.credit_limit || 0,
      is_credit_unlimited: customer.is_credit_unlimited || false,
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
      await supabase.from('customers').update(payload).eq('id', editingId);
    } else {
      await supabase.from('customers').insert([payload]);
    }

    setFormLoading(false);
    setShowForm(false);
    setEditingId(null);
    setFormData({
      customer_code: '',
      customer_name: '',
      business_no: '',
      phone: '',
      address: '',
      contact_person: '',
      status: 'active',
      remark: '',
      credit_limit: 0,
      is_credit_unlimited: false,
    });
    fetchCustomers();
  };

  const filteredCustomers = customers.filter(c => 
    c.customer_name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    c.customer_code.toLowerCase().includes(searchQuery.toLowerCase())
  );

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>Customers</h1>
        <button 
          className="btn btn-primary"
          onClick={() => {
            setEditingId(null);
            setShowForm(true);
          }}
        >
          Add Customer
        </button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <input 
            type="text" 
            placeholder="Search customer name or code..." 
            className="form-control"
            style={{ maxWidth: '300px' }}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
          <div style={{ display: 'flex', gap: '8px' }}>
            <button 
              className={`btn ${filterStatus === 'all' ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setFilterStatus('all')}
            >
              All
            </button>
            <button 
              className={`btn ${filterStatus === 'active' ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setFilterStatus('active')}
            >
              Active
            </button>
            <button 
              className={`btn ${filterStatus === 'inactive' ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setFilterStatus('inactive')}
            >
              Inactive
            </button>
          </div>
        </div>
      </div>

      {showForm && (
        <div className="card mb-24">
          <h3 style={{ marginBottom: '24px' }}>{editingId ? 'Edit Customer' : 'New Customer'}</h3>
          <form onSubmit={handleSubmit}>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Customer Code *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.customer_code} 
                  onChange={(e) => setFormData({...formData, customer_code: e.target.value})} 
                  required 
                />
              </div>
              <div className="form-group">
                <label className="form-label">Customer Name *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.customer_name} 
                  onChange={(e) => setFormData({...formData, customer_name: e.target.value})} 
                  required 
                />
              </div>
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Business No</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.business_no} 
                  onChange={(e) => setFormData({...formData, business_no: e.target.value})} 
                />
              </div>
              <div className="form-group">
                <label className="form-label">Phone</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.phone} 
                  onChange={(e) => setFormData({...formData, phone: e.target.value})} 
                />
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">Address</label>
              <input 
                type="text" 
                className="form-control" 
                value={formData.address} 
                onChange={(e) => setFormData({...formData, address: e.target.value})} 
              />
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Credit Limit (여신한도)</label>
                <input 
                  type="number" 
                  className="form-control" 
                  value={formData.credit_limit} 
                  onChange={(e) => setFormData({...formData, credit_limit: Number(e.target.value)})}
                  placeholder="0 = Cash Only"
                />
              </div>
              <div className="form-group" style={{ display: 'flex', alignItems: 'center', gap: '8px', paddingTop: '32px' }}>
                <input 
                  type="checkbox" 
                  checked={formData.is_credit_unlimited} 
                  onChange={(e) => setFormData({...formData, is_credit_unlimited: e.target.checked})}
                />
                <label className="form-label" style={{ marginBottom: 0 }}>Unlimited Credit (무제한)</label>
              </div>
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">Contact Person</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.contact_person} 
                  onChange={(e) => setFormData({...formData, contact_person: e.target.value})} 
                />
              </div>
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
                <th>Customer Name</th>
                <th>Contact</th>
                <th>Phone</th>
                <th>Status</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : filteredCustomers.map((customer) => (
                <tr key={customer.id}>
                  <td>{customer.customer_code}</td>
                  <td>{customer.customer_name}</td>
                  <td>{customer.contact_person}</td>
                  <td>{customer.phone}</td>
                  <td>
                    <span className={`badge ${customer.status === 'active' ? 'badge-success' : 'badge-danger'}`}>
                      {customer.status === 'active' ? 'Active' : 'Inactive'}
                    </span>
                  </td>
                  <td>
                    <button className="btn btn-ghost" onClick={() => handleEdit(customer)}>Edit</button>
                  </td>
                </tr>
              ))}
              {filteredCustomers.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No results found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
