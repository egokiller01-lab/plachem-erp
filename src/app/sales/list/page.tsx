import Shell from '@/components/Shell';
import Link from 'next/link';
import { useUserRole } from '@/hooks/useUserRole';

interface SalesHeader {
// ... (omitted same part)
export default function SalesListPage() {
  const [sales, setSales] = useState<SalesHeader[]>([]);
  const [loading, setLoading] = useState(true);
  const { isManager, loading: roleLoading } = useUserRole();

  const fetchSales = async () => {
// ... (omitted same part)
            <tbody>
              {loading || roleLoading ? (
                <tr><td colSpan={7} style={{ textAlign: 'center' }}>Loading...</td></tr>
              ) : sales.map((s) => (
                <tr key={s.id}>
                  <td>
                    <Link href={`/sales?id=${s.id}`} className="text-secondary" style={{ fontWeight: '600', textDecoration: 'underline' }}>
                      {s.sales_no || 'View Detail'}
                    </Link>
                  </td>
                  <td>{s.sales_date}</td>
                  <td>{s.customers?.customer_name} ({s.customer_code})</td>
                  <td style={{ fontWeight: 'bold' }}>{s.total_amount?.toLocaleString() || 0}</td>
                  <td>
                    {s.status === 'confirmed' ? (
                      <span className="badge badge-success">Confirmed</span>
                    ) : (
                      <span className="badge badge-warning">Draft</span>
                    )}
                  </td>
                  <td>{s.remark}</td>
                  <td>
                    {s.status !== 'confirmed' && isManager && (
                      <button className="btn btn-primary" style={{ padding: '4px 8px', fontSize: '12px' }} onClick={() => handleConfirm(s.id)}>
                        Confirm
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {sales.length === 0 && !loading && (
                <tr><td colSpan={6} style={{ textAlign: 'center' }}>No data available.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </Shell>
  );
}
