import React from 'react';

const productTypeLabels: Record<string, string> = {
  raw_material: 'Raw Material',
  sub_material: 'Sub Material',
  finished_goods: 'Finished Goods',
  trading_goods: 'Trading Goods',
};

// 범용적으로 사용할 수 있도록 인터페이스를 느슨하게 설정
interface ProductInfo {
  product_name?: string;
  product_type?: string;
  spec?: string;
  package?: string;
  product_code?: string; // 추가적으로 코드가 필요할 수도 있으므로
}

interface ProductDisplayProps {
  product: ProductInfo | null;
  className?: string;
}

export default function ProductDisplay({ product, className = '' }: ProductDisplayProps) {
  if (!product) return <span style={{ color: '#888' }}>Select a product...</span>;

  return (
    <div className={`flex flex-col text-left ${className}`} style={{ padding: '4px 0', lineHeight: '1.4' }}>
      <span style={{ fontWeight: '600', fontSize: '14px', color: 'var(--text-color, #111)' }}>
        {product.product_name || 'No Name'} {product.product_code && <span style={{fontSize: '11px', color: '#888', fontWeight: 'normal'}}>[{product.product_code}]</span>}
      </span>
      <span style={{ fontSize: '12px', color: 'var(--text-muted, #666)' }}>
        {productTypeLabels[product.product_type || ''] || product.product_type || '-'}
      </span>
      <span style={{ fontSize: '12px', color: 'var(--text-muted, #888)' }}>
        {product.spec || 'No spec'} / {product.package || 'No pkg'}
      </span>
    </div>
  );
}
