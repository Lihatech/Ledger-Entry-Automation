import React, { useEffect, useRef, useState } from 'react';
import { ClipboardCheck, RefreshCw, ChevronDown, ChevronUp } from 'lucide-react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { getPdiReport, getPdiReports } from '../api/analytics';

const statusLabels = {
  draft: 'Draft',
  in_progress: 'In Progress',
  submitted: 'Submitted',
  approved: 'Approved',
  rejected: 'Rejected',
};

export default function PDIReportsPage() {
  const [reports, setReports] = useState([]);
  const [date, setDate] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [expanded, setExpanded] = useState(null);
  const [detail, setDetail] = useState(null);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const requestVersion = useRef(0);

  const load = async () => {
    const version = ++requestVersion.current;
    setLoading(true);
    setError('');
    try {
      const response = await getPdiReports({ ...(date ? { date } : {}), page });
      if (version !== requestVersion.current) return;
      setReports(response.data?.results || response.data || []);
      setHasMore(Boolean(response.data?.has_more));
    } catch (err) {
      if (version !== requestVersion.current) return;
      setError(err.response?.data?.detail || err.response?.data?.error || 'Unable to load PDI reports.');
    } finally {
      if (version === requestVersion.current) setLoading(false);
    }
  };

  useEffect(() => { load(); }, [date, page]);

  const toggle = async (report) => {
    const version = ++requestVersion.current;
    if (expanded === report.report_id) {
      setExpanded(null);
      setDetail(null);
      return;
    }
    setExpanded(report.report_id);
    try {
      const response = await getPdiReport(report.report_id);
      if (version !== requestVersion.current) return;
      setDetail(response.data);
    } catch {
      setDetail(null);
    }
  };

  return (
    <>
      <Header title="PDI Reports" />
      <div className="page-content bg-gradient-animated" style={{ padding: '24px' }}>
        <div style={{ maxWidth: '1200px', margin: '0 auto' }}>
          <Breadcrumbs items={[{ label: 'Quality Analyzer', to: '/quality-analyzer' }, { label: 'PDI Reports' }]} />
          <div className="card" style={{ padding: 24, borderRadius: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
              <div>
                <h2 style={{ margin: 0, display: 'flex', gap: 8, alignItems: 'center' }}><ClipboardCheck size={22} /> Pre-Dispatch Inspection Reports</h2>
                <p style={{ color: '#64748B', marginBottom: 0 }}>Submitted mobile reports with five inspected jobs for every parameter.</p>
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                <input type="date" value={date} onChange={(event) => { setDate(event.target.value); setPage(1); }} style={{ padding: '10px 12px', border: '1px solid #CBD5E1', borderRadius: 8 }} />
                <button className="btn btn-secondary" onClick={load} disabled={loading}><RefreshCw size={16} /></button>
              </div>
            </div>
            {error && <div style={{ marginTop: 16, color: '#B91C1C' }}>{error}</div>}
            {loading ? <p style={{ marginTop: 24 }}>Loading PDI reports…</p> : reports.length === 0 ? <p style={{ marginTop: 24, color: '#64748B' }}>No PDI reports found.</p> : (
              <div style={{ marginTop: 24, display: 'grid', gap: 12 }}>
                {reports.map((report) => (
                  <div key={report.report_id} style={{ border: '1px solid #E2E8F0', borderRadius: 12, overflow: 'hidden' }}>
                    <button onClick={() => toggle(report)} style={{ width: '100%', textAlign: 'left', border: 0, background: '#fff', padding: 16, cursor: 'pointer' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, flexWrap: 'wrap' }}>
                        <div><strong>{report.report_number}</strong><div style={{ color: '#475569', marginTop: 6 }}>{report.machine_code} · {report.part_number} · {report.operation_name}</div></div>
                        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}><span>{report.report_date}</span><span style={{ color: report.overall_judgement === 'fail' ? '#B91C1C' : report.overall_judgement === 'pass' ? '#047857' : '#B45309', fontWeight: 700 }}>{report.overall_judgement?.toUpperCase()}</span><span>{statusLabels[report.status] || report.status}</span>{expanded === report.report_id ? <ChevronUp size={18} /> : <ChevronDown size={18} />}</div>
                      </div>
                    </button>
                    {expanded === report.report_id && detail && <div style={{ padding: '0 16px 16px', overflowX: 'auto' }}>
                      <div style={{ color: '#475569', marginBottom: 12 }}>Entered by: {detail.created_by || '—'} · Submitted by: {detail.submitted_by || '—'}</div>
                      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}><thead><tr><th style={{ textAlign: 'left', padding: 8, background: '#F1F5F9' }}>Parameter</th>{[1, 2, 3, 4, 5].map((sample) => <th key={sample} style={{ padding: 8, background: '#F1F5F9' }}>X{sample}</th>)}</tr></thead><tbody>
                        {(detail.parameter_snapshot || []).map((parameter) => <tr key={parameter.id}><td style={{ padding: 8, borderBottom: '1px solid #E2E8F0' }}>{parameter.parameter_code} — {parameter.parameter_name}<br /><small>{parameter.specification}</small></td>{[1, 2, 3, 4, 5].map((sample) => { const reading = (detail.readings || []).find((item) => item.parameter_id === parameter.id && item.sample_number === sample); return <td key={sample} style={{ padding: 8, borderBottom: '1px solid #E2E8F0', color: reading?.judgement === 'fail' ? '#B91C1C' : '#047857' }}>{reading ? `${reading.value_text || reading.judgement} (${reading.judgement})` : '—'}</td>; })}</tr>)}
                      </tbody></table>
                    </div>}
                  </div>
                ))}
              </div>
            )}
            {!loading && (page > 1 || hasMore) && <div style={{ marginTop: 16, display: 'flex', justifyContent: 'flex-end', gap: 8 }}><button className="btn btn-secondary" disabled={page === 1} onClick={() => setPage((value) => value - 1)}>Previous</button><span style={{ padding: '8px 4px' }}>Page {page}</span><button className="btn btn-secondary" disabled={!hasMore} onClick={() => setPage((value) => value + 1)}>Next</button></div>}
          </div>
        </div>
      </div>
    </>
  );
}
