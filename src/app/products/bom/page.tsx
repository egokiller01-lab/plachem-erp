'use client';
export const dynamic = 'force-dynamic';

import { useEffect, useState, useMemo } from 'react';
import { supabase } from '@/lib/supabase';
import Shell from '@/components/Shell';
import { useUserRole } from '@/hooks/useUserRole';

interface Product {
  id: bigint;
  product_code: string;
  product_name: string;
  product_type: string;
  unit: string;
}

interface BOMHeader {
  id: bigint;
  product_id: bigint;
  bom_no: string;
  version: number;
  is_active: boolean;
  remark: string;
  created_at: string;
}

interface BOMItem {
  id?: bigint;
  bom_header_id?: bigint;
  component_product_id: bigint;
  standard_qty: number;
  remark: string;
}

export default function BOMManagementPage() {
  const { isAdmin, isManager } = useUserRole();
  const [products, setProducts] = useState<Product[]>([]);
  const [materials, setMaterials] = useState<Product[]>([]);
  const [selectedProduct, setSelectedProduct] = useState<Product | null>(null);
  const [bomHeaders, setBomHeaders] = useState<BOMHeader[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [editingHeaderId, setEditingHeaderId] = useState<bigint | null>(null);
  
  const [headerForm, setHeaderForm] = useState({
    bom_no: '',
    version: 1,
    is_active: false,
    remark: '',
  });

  const [itemForm, setItemForm] = useState<BOMItem[]>([]);
  const [formLoading, setFormLoading] = useState(false);

  const fetchMasters = async () => {
    setLoading(true);
    const { data: prodData } = await supabase.from('products').select('*').eq('status', 'active');
    if (prodData) {
      setProducts(prodData.filter(p => p.product_type === 'finished_goods'));
      setMaterials(prodData.filter(p => ['raw_material', 'sub_material'].includes(p.product_type)));
    }
    setLoading(false);
  };

  const fetchBOMs = async (productId: bigint) => {
    const { data } = await supabase.from('bom_headers').select('*').eq('product_id', productId).order('version', { ascending: false });
    setBomHeaders(data || []);
  };

  useEffect(() => {
    fetchMasters();
  }, []);

  const handleProductSelect = (product: Product) => {
    setSelectedProduct(product);
    fetchBOMs(product.id);
    setShowForm(false);
  };

  const handleNewBOM = () => {
    if (!selectedProduct) return;
    const nextVersion = bomHeaders.length > 0 ? Math.max(...bomHeaders.map(h => h.version)) + 1 : 1;
    setEditingHeaderId(null);
    setHeaderForm({
      bom_no: `${selectedProduct.product_code}-V${nextVersion}`,
      version: nextVersion,
      is_active: bomHeaders.length === 0,
      remark: '',
    });
    setItemForm([{ component_product_id: BigInt(0), standard_qty: 0, remark: '' }]);
    setShowForm(true);
  };

  const handleEditBOM = async (header: BOMHeader) => {
    setEditingHeaderId(header.id);
    setHeaderForm({
      bom_no: header.bom_no,
      version: header.version,
      is_active: header.is_active,
      remark: header.remark,
    });
    
    const { data: itemData } = await supabase.from('bom_items').select('*').eq('bom_header_id', header.id);
    if (itemData) {
      setItemForm(itemData.map(i => ({
        id: i.id,
        bom_header_id: i.bom_header_id,
        component_product_id: BigInt(i.component_product_id),
        standard_qty: i.standard_qty,
        remark: i.remark || '',
      })));
    }
    setShowForm(true);
  };

  const handleAddItem = () => {
    setItemForm([...itemForm, { component_product_id: BigInt(0), standard_qty: 0, remark: '' }]);
  };

  const handleRemoveItem = (index: number) => {
    const newList = [...itemForm];
    newList.splice(index, 1);
    setItemForm(newList);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedProduct || !isAdmin && !isManager) return;
    setFormLoading(true);

    const { data: userData } = await supabase.auth.getUser();

    try {
      if (headerForm.is_active) {
        // Deactivate other BOMs for this product if setting this one to active
        await supabase.from('bom_headers').update({ is_active: false }).eq('product_id', selectedProduct.id);
      }

      let headerId = editingHeaderId;

      if (editingHeaderId) {
        // Update Header
        await supabase.from('bom_headers').update({
          bom_no: headerForm.bom_no,
          version: headerForm.version,
          is_active: headerForm.is_active,
          remark: headerForm.remark,
        }).eq('id', editingHeaderId);

        // Simple approach: Delete old items and insert new ones
        await supabase.from('bom_items').delete().eq('bom_header_id', editingHeaderId);
      } else {
        // Insert Header
        const { data: headData, error: headError } = await supabase.from('bom_headers').insert([{
          product_id: selectedProduct.id,
          bom_no: headerForm.bom_no,
          version: headerForm.version,
          is_active: headerForm.is_active,
          remark: headerForm.remark,
          created_by: userData.user?.id
        }]).select().single();
        
        if (headError) throw headError;
        headerId = headData.id;
      }

      // Insert Items
      const validItems = itemForm.filter(i => i.component_product_id !== BigInt(0) && i.standard_qty > 0);
      if (validItems.length > 0) {
        await supabase.from('bom_items').insert(validItems.map(i => ({
          bom_header_id: headerId,
          component_product_id: i.component_product_id.toString(), // Supabase BigInt handling
          standard_qty: i.standard_qty,
          remark: i.remark
        })));
      }

      alert('BOM saved successfully!');
      setShowForm(false);
      fetchBOMs(selectedProduct.id);
    } catch (err: any) {
      alert('Error saving BOM: ' + err.message);
    } finally {
      setFormLoading(false);
    }
  };

  return (
    <Shell>
      <div className="flex-between mb-24">
        <h1 style={{ fontSize: '28px', fontWeight: 'bold' }}>BOM Management</h1>
      </div>

      <div className="grid-cols-2" style={{ gridTemplateColumns: '1fr 2fr' }}>
        {/* Product Selection List */}
        <div className="card">
          <h3 style={{ marginBottom: '16px' }}>Finished Goods</h3>
          <div className="data-table-container">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Product</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <tr><td>Loading...</td></tr>
                ) : products.map(p => (
                  <tr 
                    key={p.product_code} 
                    onClick={() => handleProductSelect(p)}
                    style={{ cursor: 'pointer', backgroundColor: selectedProduct?.id === p.id ? 'var(--sidebar-active)' : 'transparent' }}
                  >
                    <td>
                      <div style={{ fontWeight: 'bold' }}>{p.product_name}</div>
                      <div style={{ fontSize: '12px', color: 'var(--text-muted)' }}>{p.product_code}</div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        {/* BOM Details Area */}
        <div>
          {selectedProduct ? (
            <>
              {/* Header Info */}
              <div className="card mb-24">
                <div className="flex-between">
                  <div>
                    <h2 style={{ fontSize: '20px', fontWeight: 'bold' }}>{selectedProduct.product_name}</h2>
                    <p style={{ color: 'var(--text-muted)' }}>BOM History & Configuration</p>
                  </div>
                  {(isAdmin || isManager) && !showForm && (
                    <button className="btn btn-primary" onClick={handleNewBOM}>+ New BOM Version</button>
                  )}
                </div>
              </div>

              {showForm ? (
                <div className="card">
                  <h3 style={{ marginBottom: '24px' }}>{editingHeaderId ? 'Edit BOM' : 'Create New BOM'}</h3>
                  <form onSubmit={handleSubmit}>
                    <div className="grid-cols-2">
                      <div className="form-group">
                        <label className="form-label">BOM No *</label>
                        <input type="text" className="form-control" value={headerForm.bom_no} onChange={(e) => setHeaderForm({...headerForm, bom_no: e.target.value})} required readOnly={editingHeaderId !== null} />
                      </div>
                      <div className="form-group">
                        <label className="form-label">Version</label>
                        <input type="number" className="form-control" value={headerForm.version} readOnly />
                      </div>
                    </div>
                    <div className="form-group">
                      <label style={{ display: 'flex', alignItems: 'center', gap: '8px', cursor: 'pointer' }}>
                        <input type="checkbox" checked={headerForm.is_active} onChange={(e) => setHeaderForm({...headerForm, is_active: e.target.checked})} />
                        Set as Active (Primary) BOM
                      </label>
                    </div>
                    <div className="form-group">
                      <label className="form-label">Remark</label>
                      <input type="text" className="form-control" value={headerForm.remark} onChange={(e) => setHeaderForm({...headerForm, remark: e.target.value})} />
                    </div>

                    <h4 style={{ marginTop: '24px', marginBottom: '16px', color: 'var(--primary)' }}>Component Materials</h4>
                    <div className="data-table-container mb-24">
                      <table className="data-table">
                        <thead>
                          <tr>
                            <th>Material</th>
                            <th style={{ width: '120px' }}>Std Qty</th>
                            <th style={{ width: '50px' }}></th>
                          </tr>
                        </thead>
                        <tbody>
                          {itemForm.map((item, index) => (
                            <tr key={index}>
                              <td>
                                <select 
                                  className="form-control" 
                                  value={item.component_product_id.toString()} 
                                  onChange={(e) => {
                                    const newList = [...itemForm];
                                    newList[index].component_product_id = BigInt(e.target.value);
                                    setItemForm(newList);
                                  }}
                                  required
                                >
                                  <option value="0">Select Material</option>
                                  {materials.map(m => <option key={m.id.toString()} value={m.id.toString()}>{m.product_name} ({m.product_code})</option>)}
                                </select>
                              </td>
                              <td>
                                <input 
                                  type="number" 
                                  step="0.0001" 
                                  className="form-control" 
                                  value={item.standard_qty} 
                                  onChange={(e) => {
                                    const newList = [...itemForm];
                                    newList[index].standard_qty = parseFloat(e.target.value);
                                    setItemForm(newList);
                                  }}
                                  required
                                />
                              </td>
                              <td>
                                <button type="button" className="btn btn-ghost" style={{ color: 'var(--danger)' }} onClick={() => handleRemoveItem(index)}>×</button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                      <button type="button" className="btn btn-ghost" style={{ marginTop: '8px' }} onClick={handleAddItem}>+ Add Material</button>
                    </div>

                    <div className="flex-between">
                      <button type="button" className="btn btn-ghost" onClick={() => setShowForm(false)}>Cancel</button>
                      <button type="submit" className="btn btn-primary" disabled={formLoading}>{formLoading ? 'Saving...' : 'Save BOM'}</button>
                    </div>
                  </form>
                </div>
              ) : (
                <div className="card">
                  <div className="data-table-container">
                    <table className="data-table">
                      <thead>
                        <tr>
                          <th>Version</th>
                          <th>BOM No</th>
                          <th>Status</th>
                          <th>Created</th>
                          <th>Action</th>
                        </tr>
                      </thead>
                      <tbody>
                        {bomHeaders.length === 0 ? (
                          <tr><td colSpan={5} style={{ textAlign: 'center' }}>No BOM defined yet.</td></tr>
                        ) : bomHeaders.map(h => (
                          <tr key={h.id.toString()}>
                            <td>v{h.version}</td>
                            <td>{h.bom_no}</td>
                            <td>
                              {h.is_active ? (
                                <span className="badge badge-success">Active</span>
                              ) : (
                                <span className="badge" style={{ backgroundColor: '#e2e8f0', color: '#475569' }}>Inactive</span>
                              )}
                            </td>
                            <td style={{ fontSize: '12px' }}>{new Date(h.created_at).toLocaleDateString()}</td>
                            <td>
                              <button className="btn btn-ghost" onClick={() => handleEditBOM(h)}>View/Edit</button>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </>
          ) : (
            <div className="card" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '200px', color: 'var(--text-muted)' }}>
              Select a product from the left to manage its BOM.
            </div>
          )}
        </div>
      </div>
    </Shell>
  );
}
