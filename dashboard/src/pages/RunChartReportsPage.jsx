import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import api from '../api/axios';

const fmt = (value, digits = 4) => {
  const n = Number(value);
  return Number.isFinite(n) ? n.toFixed(digits).replace(/0+$/, '').replace(/\.$/, '') : '—';
};

function RunChartGraph({ report }) {
  const readings = report.readings || [];
  const lower = Number(report.lower_limit);
  const nominal = Number(report.nominal_value);
  const upper = Number(report.upper_limit);
  const lowerWarning = Number(report.lower_warning_boundary);
  const upperWarning = Number(report.upper_warning_boundary);
  const width = 820;
  const height = 300;
  const pad = { left: 58, right: 20, top: 20, bottom: 42 };
  const min = Math.min(lower, ...readings.map((r) => Number(r.measured_value)));
  const max = Math.max(upper, ...readings.map((r) => Number(r.measured_value)));
  const span = Math.max(max - min, 0.000001);
  const y = (value) => pad.top + ((max - value) / span) * (height - pad.top - pad.bottom);
  const x = (index) => pad.left + ((index + 0.5) / Math.max(readings.length, 1)) * (width - pad.left - pad.right);
  const points = readings.map((r, i) => `${x(i)},${y(Number(r.measured_value))}`).join(' ');
  const band = (from, to, color) => (
    <rect x={pad.left} y={y(to)} width={width - pad.left - pad.right} height={Math.max(0, y(from) - y(to))} fill={color} />
  );
  return (
    <div style={{ overflowX: 'auto', border: '1px solid #E2E8F0', borderRadius: 12, padding: 8, background: '#fff' }}>
      <svg viewBox={`0 0 ${width} ${height}`} style={{ minWidth: 680, width: '100%', height: 300 }} role="img" aria-label="Saved run chart graph">
        {band(min, lower, '#FECACA')}
        {band(lower, lowerWarning, '#FEF08A')}
        {band(lowerWarning, upperWarning, '#BBF7D0')}
        {band(upperWarning, upper, '#FEF08A')}
        {band(upper, max, '#FECACA')}
        {[lower, lowerWarning, nominal, upperWarning, upper].map((value) => (
          <g key={value}>
            <line x1={pad.left} x2={width - pad.right} y1={y(value)} y2={y(value)} stroke={value === nominal ? '#0F172A' : '#64748B'} strokeDasharray={value === nominal ? undefined : '4 4'} strokeWidth={value === nominal ? 2 : 1} />
            <text x={pad.left - 8} y={y(value) + 4} textAnchor="end" fontSize="11" fill="#334155">{fmt(value)}</text>
          </g>
        ))}
        <line x1={pad.left} x2={pad.left} y1={pad.top} y2={height - pad.bottom} stroke="#334155" />
        <line x1={pad.left} x2={width - pad.right} y1={height - pad.bottom} y2={height - pad.bottom} stroke="#334155" />
        {readings.length > 0 && <polyline points={points} fill="none" stroke="#0F172A" strokeWidth="2" />}
        {readings.map((reading, index) => (
          <circle key={reading.reading_id || index} cx={x(index)} cy={y(Number(reading.measured_value))} r="4" fill={reading.zone === 'red' ? '#DC2626' : reading.zone === 'yellow' ? '#D97706' : '#059669'} stroke="#fff" strokeWidth="1.5" />
        ))}
        <text x={pad.left} y={height - 12} fontSize="11" fill="#64748B">Piece number</text>
        <text x={width - pad.right} y={height - 12} textAnchor="end" fontSize="11" fill="#64748B">{readings.length ? `${readings.length} saved readings` : 'No readings'}</text>
      </svg>
    </div>
  );
}

export default function RunChartReportsPage() {
  const [reports, setReports] = useState([]);
  const [selected, setSelected] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [filters, setFilters] = useState({ from_date: '', to_date: '', shift: '', search: '' });
  const [downloading, setDownloading] = useState(false);

  const loadReports = async () => {
    setLoading(true);
    setError('');
    try {
      const params = Object.fromEntries(Object.entries(filters).filter(([, value]) => value));
      const response = await api.get('/api/inspections/run-chart/reports/', { params });
      setReports(Array.isArray(response.data) ? response.data : []);
    } catch (err) {
      setError(err.response?.data?.detail || err.response?.data?.error || 'Unable to load completed run charts.');
      setReports([]);
    } finally { setLoading(false); }
  };

  useEffect(() => { loadReports(); }, []);

  const openReport = async (summary) => {
    try {
      const response = await api.get(`/api/inspections/run-chart/reports/${summary.report_id}/`);
      setSelected(response.data);
    } catch (err) {
      setError(err.response?.data?.error || 'Unable to load saved graph readings.');
    }
  };

  const downloadReport = async () => {
    if (!selected || downloading) return;
    setDownloading(true);
    try {
      const response = await api.get(`/api/inspections/run-chart/reports/${selected.report_id}/xlsx/`, { responseType: 'blob' });
      const url = window.URL.createObjectURL(response.data);
      const link = document.createElement('a');
      link.href = url;
      link.download = response.headers['content-disposition']?.match(/filename="?([^";]+)"?/i)?.[1]
        || `RunChart_${selected.machine_code}_${selected.report_date}.xlsx`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.setTimeout(() => window.URL.revokeObjectURL(url), 1000);
    } catch (err) {
      setError(err.response?.data?.error || 'Unable to download the run chart report.');
    } finally {
      setDownloading(false);
    }
  };

  const summaryText = useMemo(() => `${reports.length} completed run chart${reports.length === 1 ? '' : 's'}`, [reports.length]);
  return (
    <>
      <Header title="Run Chart Reports" subtitle="Completed shift-wise critical-parameter run charts saved from the mobile app" />
      <div className="page-content bg-gradient-animated" style={{ padding: 24 }}>
        <div style={{ maxWidth: 1200, margin: '0 auto' }}>
          <Breadcrumbs items={[{ label: 'Quality Analyzer', to: '/quality-analyzer' }, { label: 'Run Chart Reports' }]} />
          <section className="card" style={{ padding: 20, marginBottom: 18 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
              <div><h2 style={{ margin: 0, color: '#0F172A' }}>Completed Run Charts</h2><p style={{ color: '#64748B', margin: '6px 0 0' }}>{summaryText}. Historical readings are retained even if a machine is deactivated.</p></div>
              <button className="btn btn-outline" onClick={loadReports}>Refresh</button>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 10, marginTop: 16 }}>
              <input type="date" value={filters.from_date} onChange={(e) => setFilters({ ...filters, from_date: e.target.value })} />
              <input type="date" value={filters.to_date} onChange={(e) => setFilters({ ...filters, to_date: e.target.value })} />
              <select value={filters.shift} onChange={(e) => setFilters({ ...filters, shift: e.target.value })}><option value="">All shifts</option><option value="I">Shift I</option><option value="II">Shift II</option><option value="III">Shift III</option></select>
              <input placeholder="Machine, part, operation, parameter..." value={filters.search} onChange={(e) => setFilters({ ...filters, search: e.target.value })} />
              <button className="btn btn-primary" onClick={loadReports}>Apply filters</button>
            </div>
          </section>
          {error && <div className="alert alert-error" style={{ marginBottom: 16 }}>{error}</div>}
          <section className="card" style={{ overflowX: 'auto', padding: 0 }}>
            {loading ? <div style={{ padding: 28 }}>Loading completed run charts…</div> : reports.length === 0 ? <div style={{ padding: 36, textAlign: 'center', color: '#64748B' }}>No completed run charts found.</div> : (
              <table style={{ width: '100%', borderCollapse: 'collapse', minWidth: 900 }}>
                <thead><tr>{['Date / Shift', 'Machine', 'Part', 'Operation', 'Critical parameter', 'Operator', 'Readings', ''].map((heading) => <th key={heading} style={{ textAlign: 'left', padding: 14, borderBottom: '1px solid #E2E8F0', color: '#475569', fontSize: 12 }}>{heading}</th>)}</tr></thead>
                <tbody>{reports.map((report) => <tr key={report.report_id}>
                  <td style={{ padding: 14 }}>{report.report_date}<br /><small>Shift {report.shift}</small></td>
                  <td style={{ padding: 14 }}><strong>{report.machine_code}</strong><br /><small>{report.machine_name}</small></td>
                  <td style={{ padding: 14 }}>{report.part_number}<br /><small>{report.part_name}</small></td>
                  <td style={{ padding: 14 }}>{report.operation_name}</td>
                  <td style={{ padding: 14 }}><strong>{report.parameter_name}</strong><br /><small>{report.lower_limit} – {report.upper_limit} {report.unit}</small></td>
                  <td style={{ padding: 14 }}>{report.operator_name}</td>
                  <td style={{ padding: 14 }}>{report.reading_count}</td>
                  <td style={{ padding: 14 }}><button className="btn btn-outline" onClick={() => openReport(report)}>View graph</button></td>
                </tr>)}</tbody>
              </table>
            )}
          </section>
          {selected && <div
            role="presentation"
            onClick={() => setSelected(null)}
            style={{
              position: 'fixed',
              inset: 0,
              zIndex: 1000,
              background: 'rgba(15, 23, 42, 0.58)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: 24,
            }}
          >
            <section
              role="dialog"
              aria-modal="true"
              aria-labelledby="run-chart-dialog-title"
              className="card"
              onClick={(event) => event.stopPropagation()}
              style={{
                width: 'min(1100px, 100%)',
                maxHeight: 'calc(100vh - 48px)',
                overflowY: 'auto',
                padding: 20,
                boxShadow: '0 24px 80px rgba(15, 23, 42, 0.35)',
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'start', gap: 12 }}>
                <div>
                  <h2 id="run-chart-dialog-title" style={{ margin: 0 }}>{selected.machine_code} · {selected.parameter_name}</h2>
                  <p style={{ color: '#64748B', margin: '6px 0 0' }}>{selected.part_number} · {selected.operation_name} · Shift {selected.shift} · {selected.report_date} · {selected.operator_name}</p>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn btn-outline" onClick={downloadReport} disabled={downloading} title="Download complete Excel run chart report">
                    <Download size={16} /> {downloading ? 'Downloading…' : 'Download Excel'}
                  </button>
                  <button className="btn btn-outline" onClick={() => setSelected(null)}>Close</button>
                </div>
              </div>
              <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', margin: '18px 0 10px', color: '#475569', fontSize: 13 }}><span>Red: limits / outside limits</span><span>Yellow: limit to midpoint</span><span>Green: midpoint to midpoint</span></div>
              <RunChartGraph report={selected} />
            </section>
          </div>}
        </div>
      </div>
    </>
  );
}
