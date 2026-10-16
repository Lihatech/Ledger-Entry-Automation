import { useState, useEffect } from 'react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import { getReport, getDailyCompletedReports } from '../api/analytics';
import { getSessionDetail } from '../api/inspections';
import { getCompanyDetails } from '../api/company';
import OfficialFormF02Modal from '../components/reports/OfficialFormF02Modal';
import api from '../api/axios';

export default function AnalyticsPage() {
  const [report, setReport]               = useState(null);
  const [loadingReport, setLoadingReport] = useState(true);

  // Filters
  const [fromConfig, setFromConfig]           = useState('');
  const [toConfig, setToConfig]               = useState('');
  const [machineCode, setMachineCode]         = useState('');
  const [partFilter, setPartFilter]           = useState('');
  const [shiftFilter, setShiftFilter]         = useState('');
  const [operatorFilter, setOperatorFilter]   = useState('');
  const [inspectorFilter, setInspectorFilter] = useState('');

  // Daily Completed Reports list & PDF loading state
  const [reportsList, setReportsList]         = useState([]);
  const [loadingReports, setLoadingReports]   = useState(true);
  const [shiftCount, setShiftCount]           = useState(3);
  const [pdfLoadingId, setPdfLoadingId]       = useState(null);
  const [pdfError, setPdfError]               = useState(null);
  const [selectedSessionDetail, setSelectedSessionDetail] = useState(null);
  const [autoDownload, setAutoDownload]       = useState(false);

  const fetchAnalytics = async () => {
    setLoadingReport(true);
    try {
      const res = await getReport(fromConfig, toConfig, machineCode);
      setReport(res.data?.statistics);
    } catch { /* ignore */ } finally {
      setLoadingReport(false);
    }
  };

  useEffect(() => {
    const fetchCompanyData = async () => {
      try {
        const res = await getCompanyDetails();
        const compData = res?.data?.results || res?.data;
        if (compData && compData.length > 0) {
          setShiftCount(compData[0].total_shifts_per_day || 3);
        }
      } catch (err) {
        console.error("Failed to load shift config", err);
      }
    };
    fetchCompanyData();
  }, []);

  const fetchDailyCompletedReports = async () => {
    setLoadingReports(true);
    try {
      const params = {};
      if (fromConfig) params.start_date = fromConfig;
      if (toConfig) params.end_date = toConfig;
      if (machineCode.trim()) params.machine = machineCode.trim();
      if (partFilter.trim()) params.part = partFilter.trim();
      if (shiftFilter.trim()) params.shift = shiftFilter.trim();
      if (operatorFilter.trim()) params.operator = operatorFilter.trim();
      if (inspectorFilter.trim()) params.inspector = inspectorFilter.trim();

      const res = await getDailyCompletedReports(params);
      const list = res.data?.reports ?? [];
      setReportsList(list);
    } catch {
      setReportsList([]);
    } finally {
      setLoadingReports(false);
    }
  };

  useEffect(() => {
    fetchAnalytics();
    fetchDailyCompletedReports();
  }, [fromConfig, toConfig, machineCode, partFilter, shiftFilter, operatorFilter, inspectorFilter]);

  const handleDownloadPdf = async (item) => {
    const sId = item.session_id || item.report_id;
    setPdfLoadingId(sId);
    setPdfError(null);
    try {
      // Download directly from the backend. Do not open the report modal first:
      // browser capture of that popup can crop the inspection columns.
      const res = await api.get(`/api/inspections/${sId}/pdf/`, {
        responseType: 'blob',
      });
      const blobUrl = window.URL.createObjectURL(res.data);
      const link = document.createElement('a');
      link.href = blobUrl;
      link.download = res.headers['content-disposition']?.match(/filename="?([^";]+)"?/i)?.[1]
        || `Inspection_Report_${sId}.pdf`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.setTimeout(() => window.URL.revokeObjectURL(blobUrl), 1000);
    } catch (err) {
      console.error('PDF download error:', err);
      let detail = '';
      if (err?.response?.data instanceof Blob) {
        try {
          const payload = JSON.parse(await err.response.data.text());
          detail = payload?.error ? `: ${payload.error}` : '';
        } catch { /* keep the generic message for non-JSON responses */ }
      } else if (err?.response?.data?.error) {
        detail = `: ${err.response.data.error}`;
      }
      setPdfError(`Failed to download PDF for report ${sId.slice(0, 8)}${detail}`);
      setTimeout(() => setPdfError(null), 4000);
    } finally {
      setPdfLoadingId(null);
    }
  };

  const handleOpenPdf = async (item) => {
    const sId = item.session_id || item.report_id;
    setPdfLoadingId(sId);
    setPdfError(null);
    try {
      const res = await getSessionDetail(sId);
      setAutoDownload(false);
      setSelectedSessionDetail(res.data);
    } catch (err) {
      console.error('Failed to load session details:', err);
      setPdfError(`Failed to load report details for ${sId.slice(0, 8)}`);
      setTimeout(() => setPdfError(null), 4000);
    } finally {
      setPdfLoadingId(null);
    }
  };

  const handleResetFilters = () => {
    setFromConfig('');
    setToConfig('');
    setMachineCode('');
    setPartFilter('');
    setShiftFilter('');
    setOperatorFilter('');
    setInspectorFilter('');
  };

  // Group completed reports by date
  const groupedReports = reportsList.reduce((acc, r) => {
    const d = r.date || 'Unspecified Date';
    if (!acc[d]) acc[d] = [];
    acc[d].push(r);
    return acc;
  }, {});

  const datesGrouped = Object.keys(groupedReports);

  return (
    <>
      <Header title="First PC Inspection & In process Reports" subtitle="Historical archive of 100% completed daily inspection reports" />

      <div className="page-content bg-gradient-animated">
        <Breadcrumbs items={[{ label: 'Quality Analyzer', to: '/quality-analyzer' }, { label: 'First PC & In-Process Reports' }]} />
        {/* Filter Card */}
        <div className="card mb-20">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
            <h3 style={{ fontSize: '1rem', fontWeight: 600, margin: 0 }}>
              Daily Completed Report Filters & Search
            </h3>
            <span style={{ fontSize: '0.82rem', color: 'var(--text-secondary)' }}>
              Showing {reportsList.length} completed daily {reportsList.length === 1 ? 'report' : 'reports'}
            </span>
          </div>

          <div className="filter-bar" style={{ display: 'flex', flexWrap: 'wrap', gap: '12px', alignItems: 'flex-end' }}>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 140px' }}>
              <label className="form-label" htmlFor="analytics-from">From Date</label>
              <input
                id="analytics-from"
                type="date"
                className="form-input"
                value={fromConfig}
                onChange={(e) => setFromConfig(e.target.value)}
              />
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 140px' }}>
              <label className="form-label" htmlFor="analytics-to">To Date</label>
              <input
                id="analytics-to"
                type="date"
                className="form-input"
                value={toConfig}
                onChange={(e) => setToConfig(e.target.value)}
              />
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 130px' }}>
              <label className="form-label" htmlFor="analytics-machine">Machine</label>
              <input
                id="analytics-machine"
                type="text"
                className="form-input"
                placeholder="e.g. BAL-01"
                value={machineCode}
                onChange={(e) => setMachineCode(e.target.value)}
              />
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 130px' }}>
              <label className="form-label" htmlFor="analytics-part">Part Number</label>
              <input
                id="analytics-part"
                type="text"
                className="form-input"
                placeholder="e.g. PN001"
                value={partFilter}
                onChange={(e) => setPartFilter(e.target.value)}
              />
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 100px' }}>
              <label className="form-label" htmlFor="analytics-shift">Shift</label>
              <select
                id="analytics-shift"
                className="form-input"
                value={shiftFilter}
                onChange={(e) => setShiftFilter(e.target.value)}
              >
                <option value="">All Shifts</option>
                <option value="A">Shift A</option>
                <option value="B">Shift B</option>
                {shiftCount >= 3 && <option value="C">Shift C</option>}
              </select>
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 130px' }}>
              <label className="form-label" htmlFor="analytics-operator">Operator</label>
              <input
                id="analytics-operator"
                type="text"
                className="form-input"
                placeholder="e.g. Samruddhi"
                value={operatorFilter}
                onChange={(e) => setOperatorFilter(e.target.value)}
              />
            </div>
            <div className="form-group" style={{ marginBottom: 0, flex: '1 1 130px' }}>
              <label className="form-label" htmlFor="analytics-inspector">Inspector</label>
              <input
                id="analytics-inspector"
                type="text"
                className="form-input"
                placeholder="e.g. Inspector"
                value={inspectorFilter}
                onChange={(e) => setInspectorFilter(e.target.value)}
              />
            </div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flex: '0 0 auto' }}>
              <button
                id="reset-analytics"
                className="btn btn-ghost"
                style={{ padding: '8px 14px', height: 38 }}
                onClick={handleResetFilters}
              >
                Reset
              </button>
            </div>
          </div>
        </div>

        {pdfError && (
          <div className="alert alert-danger mb-20" style={{ padding: '10px 14px', borderRadius: 8, background: '#FFF5F5', color: '#C53030', border: '1px solid #FEB2B2' }}>
            {pdfError}
          </div>
        )}

        {/* Daily Completed Reports Section */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16, borderBottom: '1px solid var(--border-color, #E2E8F0)', paddingBottom: 12 }}>
            <div>
              <h3 className="section-title" style={{ margin: 0, fontSize: '1.1rem' }}>
                <span className="dot" style={{ background: 'var(--accent-green)' }} />
                Daily Completed Reports
              </h3>
              <p style={{ margin: '4px 0 0 0', fontSize: '0.82rem', color: 'var(--text-secondary)' }}>
                Historical archive of 100% completed daily reports (1PC #1..#3 + 1..8/HR). Incomplete, draft, or in-progress reports are excluded.
              </p>
            </div>
          </div>

          {loadingReports ? (
            <LoadingSpinner message="Loading daily completed inspection reports..." />
          ) : reportsList.length === 0 ? (
            <div className="empty-state" style={{ padding: '40px 20px', textAlign: 'center' }}>
              <div className="empty-state-text" style={{ fontSize: '1rem', fontWeight: 500 }}>No 100% completed daily reports match the selected filters.</div>
              <p style={{ color: 'var(--text-secondary)', fontSize: '0.85rem', marginTop: 4 }}>
                Only fully completed reports (1PC#1 to 8HR) appear in Analytics. Draft, pending, or in-progress reports are hidden.
              </p>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
              {datesGrouped.map((dateStr) => {
                const dateItems = groupedReports[dateStr];
                return (
                  <div key={dateStr} style={{ background: 'var(--bg-secondary, #F8FAFC)', borderRadius: 10, padding: 16, border: '1px solid var(--border-color, #E2E8F0)' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12, paddingBottom: 8, borderBottom: '2px solid var(--accent-blue, #3B82F6)' }}>
                      <h4 style={{ margin: 0, fontSize: '1rem', fontWeight: 700, color: 'var(--text-primary)' }}>
                        {dateStr}
                      </h4>
                      <span style={{ fontSize: '0.75rem', background: '#E2E8F0', padding: '2px 8px', borderRadius: 12, fontWeight: 600 }}>
                        {dateItems.length} {dateItems.length === 1 ? 'Report' : 'Reports'}
                      </span>
                    </div>

                    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))', gap: 14 }}>
                      {dateItems.map((r) => {
                        const sId = r.session_id || r.report_id;
                        const isDownloading = pdfLoadingId === sId;

                        return (
                          <div
                            key={sId}
                            style={{
                              background: '#ffffff',
                              borderRadius: 8,
                              border: '1px solid var(--border-color, #E2E8F0)',
                              padding: 14,
                              boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                              display: 'flex',
                              flexDirection: 'column',
                              justify: 'space-between',
                              gap: 12,
                            }}
                          >
                            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                                <span style={{ fontWeight: 700, fontSize: '0.92rem', color: '#1E293B', fontFamily: 'monospace' }}>
                                  Machine: <span style={{ color: '#2563EB', background: '#EFF6FF', padding: '2px 6px', borderRadius: 4 }}>{r.machine}</span>
                                </span>
                                <span style={{ fontSize: '0.75rem', fontWeight: 700, color: '#15803D', background: '#DCFCE7', padding: '3px 8px', borderRadius: 4 }}>
                                  Status: {r.status}
                                </span>
                              </div>

                              <div style={{ fontSize: '0.85rem', color: '#334155' }}>
                                <strong>Part:</strong> {r.part}
                              </div>
                              <div style={{ fontSize: '0.82rem', color: '#475569', display: 'flex', gap: 12 }}>
                                <span><strong>Shift:</strong> Shift {r.shift}</span>
                              </div>
                              <div style={{ fontSize: '0.82rem', color: '#475569' }}>
                                <strong>Operator:</strong> {r.operator}
                              </div>
                              <div style={{ fontSize: '0.82rem', color: '#475569' }}>
                                <strong>Inspector:</strong> {r.inspector}
                              </div>
                            </div>

                            <div style={{ display: 'flex', gap: 8, marginTop: 4, paddingTop: 8, borderTop: '1px dashed #E2E8F0' }}>
                              <button
                                className="btn btn-outline"
                                disabled={isDownloading}
                                style={{
                                  flex: 1,
                                  padding: '6px 12px',
                                  fontSize: '0.82rem',
                                  display: 'inline-flex',
                                  alignItems: 'center',
                                  justifyContent: 'center',
                                  gap: 6,
                                  borderRadius: 6,
                                  cursor: isDownloading ? 'not-allowed' : 'pointer'
                                }}
                                onClick={() => handleOpenPdf(r)}
                              >
                                {isDownloading ? 'Loading...' : 'View Report'}
                              </button>

                              <button
                                className="btn btn-primary"
                                disabled={isDownloading}
                                style={{
                                  flex: 1,
                                  padding: '6px 12px',
                                  fontSize: '0.82rem',
                                  display: 'inline-flex',
                                  alignItems: 'center',
                                  justifyContent: 'center',
                                  gap: 6,
                                  background: isDownloading ? '#A0AEC0' : 'var(--accent-red, #E53E3E)',
                                  border: 'none',
                                  color: '#FFF',
                                  borderRadius: 6,
                                  cursor: isDownloading ? 'not-allowed' : 'pointer'
                                }}
                                onClick={() => handleDownloadPdf(r)}
                              >
                                {isDownloading ? 'Downloading...' : 'Download PDF'}
                              </button>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {selectedSessionDetail && (
        <OfficialFormF02Modal
          session={selectedSessionDetail}
          autoDownload={autoDownload}
          onClose={() => {
            setSelectedSessionDetail(null);
            setAutoDownload(false);
          }}
        />
      )}
    </>
  );
}
