import React, { useState, useEffect, useCallback } from 'react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import { getSetupApprovalData } from '../api/inspections';
import api from '../api/axios';
import { useCompany } from '../context/CompanyContext';
import { formatDate } from '../utils/formatters';
import { Download, Calendar, Cpu, Search } from 'lucide-react';

export default function SetupApprovalReportsPage() {
  const { companyName, companyCode } = useCompany();
  const [machines, setMachines] = useState([]);
  const [selectedMachine, setSelectedMachine] = useState('');
  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().slice(0, 10));

  const [reportData, setReportData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [downloading, setDownloading] = useState(false);

  useEffect(() => {
    const fetchMachines = async () => {
      try {
        const res = await api.get('/api/machines/');
        const mList = res.data?.results ?? res.data ?? [];
        setMachines(mList);
        if (mList.length > 0 && !selectedMachine) {
          setSelectedMachine(mList[0].id);
        }
      } catch (err) {
        console.error(err);
      }
    };
    fetchMachines();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const loadReport = useCallback(async () => {
    setLoading(true);
    setError('');
    setReportData(null);
    try {
      // Pass null for templateId so the backend returns the latest setup approval for the machine
      const res = await getSetupApprovalData(null, selectedMachine, selectedDate);
      if (res.data) {
        setReportData(res.data);
      }
    } catch (err) {
      if (err.response?.status === 404) {
        // No report found - handled gracefully in UI
      } else {
        setError('Failed to load setup approval report.');
      }
    } finally {
      setLoading(false);
    }
  }, [selectedMachine, selectedDate]);

  useEffect(() => {
    if (selectedMachine && selectedDate) {
      loadReport();
    }
  }, [selectedMachine, selectedDate, loadReport]);


  const handleDownloadPDF = async () => {
    const reportId = reportData?.setup_approval_id || reportData?._id;
    if (!reportId) return;
    setDownloading(true);
    try {
      const res = await api.get(`/api/inspections/setup-approval/${reportId}/pdf/`, { responseType: 'blob' });
      const url = window.URL.createObjectURL(new Blob([res.data], { type: 'application/pdf' }));
      const link = document.createElement('a');
      link.href = url;
      const m = machines.find(mac => mac.id.toString() === selectedMachine.toString());
      const mCode = m?.machine_code || 'Machine';
      link.setAttribute('download', `Setup_Approval_${selectedDate}_${mCode}.pdf`);
      document.body.appendChild(link);
      link.click();
      link.parentNode.removeChild(link);
    } catch (err) {
      console.error(err);
      alert('Failed to download PDF');
    } finally {
      setDownloading(false);
    }
  };

  const paramEntries = reportData?.process_param_entries || [];
  const productParams = paramEntries.filter(p => p.parameter_code && !p.parameter_code.startsWith('PR'));
  const processParams = paramEntries.filter(p => p.parameter_code && p.parameter_code.startsWith('PR'));

  const entriesByKey = {};
  paramEntries.forEach(entry => {
    const c = entry.parameter_code || '';
    const n = entry.parameter_name || '';
    const vals = {
      '1': (entry.trial_1 !== null && String(entry.trial_1).trim() !== '') ? String(entry.trial_1) : '-',
      '2': (entry.trial_2 !== null && String(entry.trial_2).trim() !== '') ? String(entry.trial_2) : '-',
      '3': (entry.trial_3 !== null && String(entry.trial_3).trim() !== '') ? String(entry.trial_3) : '-',
    };
    if (c) entriesByKey[c] = vals;
    if (n) entriesByKey[n] = vals;
  });

  const mCode = reportData?.machine_code || machines.find(m => m.id.toString() === selectedMachine.toString())?.machine_code || '';
  const pNum = reportData?.part_number || '';
  const pName = reportData?.part_name || '';
  const shift = reportData?.shift || 'I';
  const insp = reportData?.operator_name || 'Inspector';
  const status = reportData?.status ? reportData.status.toUpperCase().replace('_', ' ') : 'APPROVED';

  return (
    <>
      <Header
        title="Set Up Approval Report"
        subtitle="Live F02 Setup Approval view based on inspector data entry"
      />

      <div className="page-content" style={{ padding: '24px', background: '#F1F5F9', minHeight: '100vh' }}>
        <Breadcrumbs items={[
          { label: 'Quality Analyzer', to: '/quality-analyzer' },
          { label: 'Set Up Approval Report' }
        ]} />

        {/* Filters & Actions Bar */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: '#FFFFFF', padding: '16px 20px', borderRadius: '12px', border: '1px solid #E2E8F0', marginBottom: '24px', boxShadow: '0 1px 3px rgba(0,0,0,0.05)' }}>
          <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontSize: 11, fontWeight: 700, color: '#64748B', textTransform: 'uppercase' }}>Select Date</label>
              <div style={{ display: 'flex', alignItems: 'center', border: '1px solid #CBD5E1', borderRadius: '6px', overflow: 'hidden', padding: '0 12px' }}>
                <Calendar size={14} color="#64748B" style={{ marginRight: 8 }} />
                <input
                  type="date"
                  value={selectedDate}
                  onChange={e => setSelectedDate(e.target.value)}
                  style={{ border: 'none', outline: 'none', padding: '8px 0', fontSize: 13, fontWeight: 600, color: '#1E293B', background: 'transparent' }}
                />
              </div>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <label style={{ fontSize: 11, fontWeight: 700, color: '#64748B', textTransform: 'uppercase' }}>Select Machine</label>
              <div style={{ display: 'flex', alignItems: 'center', border: '1px solid #CBD5E1', borderRadius: '6px', overflow: 'hidden', padding: '0 12px', background: '#FFFFFF' }}>
                <Cpu size={14} color="#64748B" style={{ marginRight: 8 }} />
                <select
                  value={selectedMachine}
                  onChange={e => setSelectedMachine(e.target.value)}
                  style={{ border: 'none', outline: 'none', padding: '9px 0', fontSize: 13, fontWeight: 600, color: '#1E293B', background: 'transparent', minWidth: '160px' }}
                >
                  <option value="" disabled>Select Machine...</option>
                  {machines.map(m => (
                    <option key={m.id} value={m.id}>{m.machine_code} {m.name ? `- ${m.name}` : ''}</option>
                  ))}
                </select>
              </div>
            </div>
          </div>

          <div>
            <button
              onClick={handleDownloadPDF}
              disabled={!reportData || downloading}
              style={{
                display: 'flex', alignItems: 'center', gap: 8, padding: '10px 16px', borderRadius: '8px',
                background: reportData ? '#FEF08A' : '#F1F5F9',
                color: reportData ? '#A16207' : '#94A3B8',
                fontWeight: 700, fontSize: 13, border: 'none', cursor: reportData && !downloading ? 'pointer' : 'not-allowed',
                boxShadow: reportData ? '0 1px 2px rgba(0,0,0,0.05)' : 'none', transition: 'all 0.2s'
              }}
            >
              <Download size={16} />
              <span>{downloading ? 'Exporting...' : 'EXPORT PDF'}</span>
            </button>
          </div>
        </div>

        {loading ? (
          <div style={{ padding: '60px 20px' }}>
            <LoadingSpinner message="Fetching Setup Approval Data..." />
          </div>
        ) : error ? (
          <div style={{ padding: '40px', textAlign: 'center', color: '#DC2626', background: '#FEF2F2', borderRadius: '12px', border: '1px solid #FCA5A5' }}>
            {error}
          </div>
        ) : !reportData ? (
          <div style={{ padding: '80px 24px', textAlign: 'center', background: '#FFFFFF', borderRadius: '12px', border: '1px solid #E2E8F0' }}>
            <Search size={48} color="#CBD5E1" style={{ marginBottom: 16 }} />
            <div style={{ fontSize: 16, fontWeight: 700, color: '#334155', marginBottom: 8 }}>No Setup Approval Report Found</div>
            <div style={{ fontSize: 13, color: '#64748B', maxWidth: '400px', margin: '0 auto' }}>
              No inspector data entry exists for <strong>{machines.find(m => m.id.toString() === selectedMachine.toString())?.machine_code || 'this machine'}</strong> on <strong>{formatDate(selectedDate)}</strong>.
            </div>
          </div>
        ) : (
          <div style={{ background: '#FFFFFF', padding: '16px', borderRadius: '12px', border: '1px solid #E2E8F0', boxShadow: '0 4px 6px -1px rgba(0,0,0,0.05)', overflowX: 'auto' }}>
            <div style={{ minWidth: '950px', border: '1.5px solid #000000', fontFamily: 'Arial, sans-serif' }}>

              {/* TOP HEADER */}
              <div style={{ display: 'flex', borderBottom: '1.5px solid #000000' }}>
                <div style={{ width: '12%', padding: '8px', background: '#000000', color: '#FFFFFF', display: 'flex', alignItems: 'center', justifyContent: 'center', borderRight: '1.5px solid #000000' }}>
                  <div style={{ fontSize: 18, fontWeight: 900, letterSpacing: 1 }}>{companyCode || 'LIHA-F1'}</div>
                </div>
                <div style={{ width: '73%', padding: '8px', textAlign: 'center', borderRight: '1.5px solid #000000' }}>
                  <div style={{ fontSize: 15, fontWeight: 900, color: '#333333' }}>{companyName?.toUpperCase() || 'LIHA TECH FACTORY 1'}</div>
                  <div style={{ fontSize: 12, fontWeight: 800, color: '#1E40AF', marginTop: 4 }}>FIRST PIECE SETUP APPROVAL REPORT — PROCESS NO. 10</div>
                </div>
                <div style={{ width: '15%', padding: '6px', textAlign: 'right', fontSize: 9, color: '#000000', display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
                  <div>DOC REF: {companyCode || 'LIHA-F1'}/PRD/F02</div>
                  <div>REV: 02 (15.0.2013)</div>
                  <div style={{ fontWeight: 800, marginTop: 2 }}>PAGE 1 OF 1</div>
                </div>
              </div>

              {/* SECOND HEADER ROW */}
              <div style={{ display: 'flex', borderBottom: '1px solid #000000', background: '#F8FAFC' }}>
                <div style={{ flex: 3, padding: '6px 8px', borderRight: '1px solid #000000', fontSize: 11 }}>
                  <span style={{ color: '#475569', fontWeight: 600 }}>PROCESS NO:</span> <strong style={{ color: '#000000' }}>10</strong>
                </div>
                <div style={{ flex: 7, padding: '6px 8px', borderRight: '1px solid #000000', fontSize: 11 }}>
                  <span style={{ color: '#475569', fontWeight: 600 }}>PART NAME & NO:</span> <strong style={{ color: '#000000' }}>{pNum} ({pName})</strong>
                </div>
                <div style={{ flex: 5, padding: '6px 8px', fontSize: 11 }}>
                  <span style={{ color: '#475569', fontWeight: 600 }}>INSPECTOR / OPERATOR:</span> <strong style={{ color: '#000000' }}>{insp}</strong>
                </div>
              </div>

              {/* THIRD HEADER ROW */}
              <div style={{ display: 'flex', borderBottom: '1.5px solid #000000', background: '#F8FAFC' }}>
                <div style={{ flex: 5, padding: '6px 8px', borderRight: '1px solid #000000', fontSize: 11 }}>
                  <span style={{ color: '#475569', fontWeight: 600 }}>MACHINE NO:</span> <strong style={{ color: '#000000' }}>{mCode}</strong>
                </div>
                <div style={{ flex: 6, padding: '6px 8px', borderRight: '1px solid #000000', fontSize: 11 }}>
                  <span style={{ color: '#475569', fontWeight: 600 }}>DATE & SHIFT:</span> <strong style={{ color: '#000000' }}>{formatDate(selectedDate)} | Shift {shift}</strong>
                </div>
                <div style={{ flex: 4, padding: '6px 8px', background: '#F0FDF4', fontSize: 11 }}>
                  <span style={{ color: '#166534', fontWeight: 600 }}>SETUP STATUS:</span> <strong style={{ color: '#166534' }}>{status}</strong>
                </div>
              </div>

              {/* MAIN TABLE */}
              <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'center', fontSize: 10 }}>
                <thead>
                  <tr style={{ background: '#E2E8F0', borderBottom: '1px solid #000000', color: '#334155' }}>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 2px', width: '3.5%' }}>P.N O</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 2px', width: '3.5%' }}>NO</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 8px', width: '22%', textAlign: 'left' }}>PARAMETER NAME & DESCRIPTION</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '6%' }}>CLASS</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '15%' }}>SPECIFICATION</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '15%' }}>EVALUATION TECHNIQUE</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '10%' }}>SAMPLE FREQ</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '8%', color: '#1E40AF', background: '#DBEAFE' }}>1ST #1</th>
                    <th style={{ borderRight: '1px solid #000000', padding: '6px 4px', width: '8%', color: '#B45309', background: '#FEF3C7' }}>1ST #2</th>
                    <th style={{ padding: '6px 4px', width: '8%', color: '#047857', background: '#D1FAE5' }}>1ST #3</th>
                  </tr>
                </thead>
                <tbody>
                  {/* PRODUCT PARAMETERS */}
                  {productParams.map((p, idx) => {
                    const c = p.parameter_code || '';
                    const n = p.parameter_name || '';
                    const t1 = entriesByKey[c]?.['1'] || entriesByKey[n]?.['1'] || '-';
                    const t2 = entriesByKey[c]?.['2'] || entriesByKey[n]?.['2'] || '-';
                    const t3 = entriesByKey[c]?.['3'] || entriesByKey[n]?.['3'] || '-';
                    const isCritical = p.is_critical || p.critical;
                    const method = p.evaluation_technique || p.method || 'VERNIER CALIPER';
                    const freq = p.sample_frequency || '5NOS/SHIFT';
                    const nom = p.nominal_value || p.nominal || 0;
                    const lLim = p.lower_tolerance || p.lower_limit || 0;
                    const uLim = p.upper_tolerance || p.upper_limit || 0;

                    return (
                      <tr key={`prod-${idx}`} style={{ borderBottom: '1px solid #CBD5E1', background: '#FFFFFF' }}>
                        {idx === 0 && (
                          <td rowSpan={productParams.length} style={{ borderRight: '1px solid #000000', background: '#F8FAFC' }}>
                            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: '25px', margin: '0 auto', wordBreak: 'break-all', fontSize: 10, fontWeight: 800, color: '#1E40AF', lineHeight: '1.2' }}>
                              PRODUCT<br /><br />PARAMETER
                            </div>
                          </td>
                        )}
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 800 }}>{(idx + 1).toString().padStart(2, '0')}</td>
                        <td style={{ borderRight: '1px solid #000000', textAlign: 'left', padding: '6px 8px', fontWeight: 700 }}>{n}</td>
                        <td style={{ borderRight: '1px solid #000000', color: isCritical ? '#DC2626' : '#000000', fontWeight: isCritical ? 800 : 400, fontSize: 9 }}>
                          {isCritical ? 'CRITICAL' : '—'}
                        </td>
                        <td style={{ borderRight: '1px solid #000000', padding: '4px' }}>
                          <div style={{ fontWeight: 800 }}>{nom} {p.unit || 'mm'}</div>
                          <div style={{ fontSize: 9, color: '#64748B', fontWeight: 600 }}>[{lLim} to {uLim}]</div>
                        </td>
                        <td style={{ borderRight: '1px solid #000000', fontSize: 9, color: '#475569', textTransform: 'uppercase' }}>{method}</td>
                        <td style={{ borderRight: '1px solid #000000', fontSize: 9, color: '#475569' }}>{freq}</td>
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 600 }}>{t1}</td>
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 600 }}>{t2}</td>
                        <td style={{ fontWeight: 600 }}>{t3}</td>
                      </tr>
                    );
                  })}

                  {/* PROCESS PARAMETERS */}
                  {processParams.map((p, idx) => {
                    const c = p.parameter_code || '';
                    const n = p.parameter_name || '';
                    const t1 = entriesByKey[c]?.['1'] || entriesByKey[n]?.['1'] || '-';
                    const t2 = entriesByKey[c]?.['2'] || entriesByKey[n]?.['2'] || '-';
                    const t3 = entriesByKey[c]?.['3'] || entriesByKey[n]?.['3'] || '-';

                    const rawSpec = p.specification || '-';
                    const rawUnit = p.unit || '';
                    const spec = rawSpec.replace('RPM RPM', 'RPM').replace('mm/rev mm/rev', 'mm/rev').replace('Bar Bar', 'Bar');
                    const unit = rawUnit.replace('RPM RPM', 'RPM').replace('mm/rev mm/rev', 'mm/rev').replace('Bar Bar', 'Bar');
                    const specDisplay = (unit && !spec.endsWith(unit)) ? `${spec} ${unit}` : spec;

                    return (
                      <tr key={`proc-${idx}`} style={{ borderBottom: '1px solid #CBD5E1', background: '#FFFFFF' }}>
                        {idx === 0 && (
                          <td rowSpan={processParams.length} style={{ borderRight: '1px solid #000000', background: '#F8FAFC' }}>
                            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: '25px', margin: '0 auto', wordBreak: 'break-all', fontSize: 10, fontWeight: 800, color: '#1E40AF', lineHeight: '1.2' }}>
                              PROCESS<br /><br />PARAMETER
                            </div>
                          </td>
                        )}
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 800 }}>{(idx + 1).toString().padStart(2, '0')}</td>
                        <td style={{ borderRight: '1px solid #000000', textAlign: 'left', padding: '6px 8px', fontWeight: 700, color: '#1E40AF' }}>[PROC] {n}</td>
                        <td style={{ borderRight: '1px solid #000000', color: '#1E40AF', fontWeight: 800, fontSize: 9 }}>PROC</td>
                        <td style={{ borderRight: '1px solid #000000', padding: '4px', fontWeight: 700 }}>{specDisplay}</td>
                        <td style={{ borderRight: '1px solid #000000', fontSize: 9, color: '#475569', textTransform: 'uppercase' }}>CHECKLIST / DISPLAY</td>
                        <td style={{ borderRight: '1px solid #000000', fontSize: 9, color: '#475569' }}>1ST PC ONLY</td>
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 600 }}>{t1}</td>
                        <td style={{ borderRight: '1px solid #000000', fontWeight: 600 }}>{t2}</td>
                        <td style={{ fontWeight: 600 }}>{t3}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>

              {/* FOOTER */}
              <div style={{ borderTop: '1.5px solid #000000', background: '#F8FAFC', padding: '6px 8px', fontSize: 9, fontWeight: 700, color: '#475569', textTransform: 'uppercase' }}>
                REACTION PLAN: REJECT, REWORK, SEGREGATE, INFORM SUPERVISOR OR READJUST THE PROCESS
              </div>
              <div style={{ borderTop: '1px solid #000000', padding: '16px 20px', display: 'flex', justifyContent: 'space-between', background: '#FFFFFF' }}>
                <div style={{ textAlign: 'center', width: '30%' }}>
                  <div style={{ borderBottom: '1px solid #000000', paddingBottom: '4px', marginBottom: '4px', minHeight: '24px', fontStyle: 'italic', fontSize: 11, fontWeight: 600 }}>
                    {insp}
                  </div>
                  <div style={{ fontSize: 9, fontWeight: 700, color: '#334155' }}>OPERATOR SIGNATURE</div>
                </div>
                <div style={{ textAlign: 'center', width: '30%' }}>
                  <div style={{ borderBottom: '1px solid #000000', paddingBottom: '4px', marginBottom: '4px', minHeight: '24px', fontStyle: 'italic', fontSize: 11, fontWeight: 600 }}>
                    {insp}
                  </div>
                  <div style={{ fontSize: 9, fontWeight: 700, color: '#334155' }}>QUALITY INSPECTOR SIGNATURE</div>
                </div>
                <div style={{ textAlign: 'center', width: '30%' }}>
                  <div style={{ borderBottom: '1px solid #000000', paddingBottom: '4px', marginBottom: '4px', minHeight: '24px', fontStyle: 'italic', fontSize: 11, fontWeight: 600 }}>
                    Supervisor Sign
                  </div>
                  <div style={{ fontSize: 9, fontWeight: 700, color: '#334155' }}>SUPERVISOR SIGNATURE</div>
                </div>
              </div>

            </div>
          </div>
        )}
      </div>
    </>
  );
}
