'use client';

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
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>거래처 관리</h1>
        <button 
          className="btn btn-primary"
          onClick={() => {
            setEditingId(null);
            setShowForm(true);
          }}
        >
          거래처 등록
        </button>
      </div>

      <div className="card mb-24">
        <div className="flex-between" style={{ gap: '16px' }}>
          <input 
            type="text" 
            placeholder="거래처명 또는 코드 검색..." 
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
              전체
            </button>
            <button 
              className={`btn ${filterStatus === 'active' ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setFilterStatus('active')}
            >
              사용중
            </button>
            <button 
              className={`btn ${filterStatus === 'inactive' ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setFilterStatus('inactive')}
            >
              미사용
            </button>
          </div>
        </div>
      </div>

      {showForm && (
        <div className="card mb-24">
          <h3 style={{ marginBottom: '24px' }}>{editingId ? '거래처 수정' : '새 거래처 등록'}</h3>
          <form onSubmit={handleSubmit}>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">거래처 코드 *</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.customer_code} 
                  onChange={(e) => setFormData({...formData, customer_code: e.target.value})} 
                  required 
                />
              </div>
              <div className="form-group">
                <label className="form-label">거래처명 *</label>
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
                <label className="form-label">사업자 번호</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.business_no} 
                  onChange={(e) => setFormData({...formData, business_no: e.target.value})} 
                />
              </div>
              <div className="form-group">
                <label className="form-label">전화번호</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.phone} 
                  onChange={(e) => setFormData({...formData, phone: e.target.value})} 
                />
              </div>
            </div>
            <div className="form-group">
              <label className="form-label">주소</label>
              <input 
                type="text" 
                className="form-control" 
                value={formData.address} 
                onChange={(e) => setFormData({...formData, address: e.target.value})} 
              />
            </div>
            <div className="grid-cols-2">
              <div className="form-group">
                <label className="form-label">담당자</label>
                <input 
                  type="text" 
                  className="form-control" 
                  value={formData.contact_person} 
                  onChange={(e) => setFormData({...formData, contact_person: e.target.value})} 
                />
              </div>
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
                <th>거래처명</th>
                <th>담당자</th>
                <th>전화번호</th>
                <th>상태</th>
                <th>작업</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>로딩 중...</td></tr>
              ) : filteredCustomers.map((customer) => (
                <tr key={customer.id}>
                  <td>{customer.customer_code}</td>
                  <td>{customer.customer_name}</td>
                  <td>{customer.contact_person}</td>
                  <td>{customer.phone}</td>
                  <td>
                    <span className={`badge ${customer.status === 'active' ? 'badge-success' : 'badge-danger'}`}>
                      {customer.status === 'active' ? '사용중' : '미사용'}
                    </span>
                  </td>
                  <td>
                    <button className="btn btn-ghost" onClick={() => handleEdit(customer)}>수정</button>
                  </td>
                </tr>
              ))}
              {filteredCustomers.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>검색 결과가 없습니다.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
