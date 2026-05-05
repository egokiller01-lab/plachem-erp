import React, { useState, useRef, useEffect } from 'react';

interface Product {
  id?: string | number;
  product_code: string;
  product_name: string;
  product_type: string;
  spec: string;
  package: string;
}

interface ProductSelectorProps {
  products: Product[];
  value?: string | number; // product_id
  onChange: (productId: string | number) => void;
  disabled?: boolean;
}

export default function ProductSelector({ products, value, onChange, disabled }: ProductSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [search, setSearch] = useState('');
  const wrapperRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (wrapperRef.current && !wrapperRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const selectedProduct = products.find(p => p.id?.toString() === value?.toString()) || null;

  const filtered = products.filter(p => 
    p.product_name.toLowerCase().includes(search.toLowerCase()) || 
    p.product_code.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div ref={wrapperRef} style={{ position: 'relative', width: '100%' }}>
      {/* 단순화된 입력창 */}
      <div 
        className="form-control"
        style={{ 
          cursor: disabled ? 'not-allowed' : 'pointer', 
          padding: '6px 10px',
          height: '32px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          backgroundColor: disabled ? '#f3f4f6' : '#fff',
          fontSize: '13px'
        }}
        onClick={() => !disabled && setIsOpen(!isOpen)}
      >
        <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1, color: selectedProduct ? 'var(--text-main)' : '#9ca3af' }}>
          {selectedProduct ? `[${selectedProduct.product_code}] ${selectedProduct.product_name}` : 'Select Product...'}
        </div>
        <div style={{ fontSize: '10px', color: '#9ca3af', marginLeft: '4px' }}>▼</div>
      </div>

      {isOpen && (
        <div style={{
          position: 'absolute',
          top: '100%',
          left: 0,
          right: 0,
          zIndex: 1000,
          backgroundColor: '#fff',
          border: '1px solid var(--border-color)',
          boxShadow: '0 4px 12px rgba(0,0,0,0.1)',
          borderRadius: '4px',
          marginTop: '4px',
          maxHeight: '250px',
          display: 'flex',
          flexDirection: 'column',
          width: '400px' // 테이블 셀보다 넓게 표시하여 가독성 확보
        }}>
          <div style={{ padding: '6px', borderBottom: '1px solid var(--border-color)' }}>
            <input 
              type="text" 
              className="form-control" 
              placeholder="Search..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              autoFocus
              style={{ height: '30px', fontSize: '12px' }}
              onClick={e => e.stopPropagation()}
            />
          </div>
          <div style={{ overflowY: 'auto', flex: 1 }}>
            {filtered.length === 0 ? (
              <div style={{ padding: '10px', textAlign: 'center', color: '#9ca3af', fontSize: '12px' }}>No results</div>
            ) : (
              filtered.map((p) => (
                <div 
                  key={p.id}
                  style={{ 
                    padding: '8px 10px', 
                    borderBottom: '1px solid #f3f4f6',
                    cursor: 'pointer',
                    fontSize: '12px'
                  }}
                  onMouseEnter={e => e.currentTarget.style.backgroundColor = '#f3f4f6'}
                  onMouseLeave={e => e.currentTarget.style.backgroundColor = 'transparent'}
                  onClick={() => {
                    onChange(p.id!);
                    setIsOpen(false);
                    setSearch('');
                  }}
                >
                  <div style={{ fontWeight: '600' }}>[{p.product_code}] {p.product_name}</div>
                  <div style={{ fontSize: '11px', color: '#666' }}>{p.product_type} | {p.spec} | {p.package}</div>
                </div>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  );
}
