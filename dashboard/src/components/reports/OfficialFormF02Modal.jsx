import React, { useState, useEffect } from 'react';
import Modal from '../common/Modal';
import { formatDate, fmt } from '../../utils/formatters';
import { useCompany } from '../../context/CompanyContext';
import api from '../../api/axios';

const isValOOC = (val, lower, upper, status) => {
  if (status === 'out_of_spec' || status === 'rejected' || status === 'ooc') return true;
  if (val === undefined || val === null || val === '') return false;
  const num = Number(val);
  if (isNaN(num)) return false;
  if (lower !== undefined && lower !== null && lower !== '' && num < Number(lower)) return true;
  if (upper !== undefined && upper !== null && upper !== '' && num > Number(upper)) return true;
  return false;
};

export default function OfficialFormF02Modal({ session, onClose, autoDownload = false }) {
  const { companyName, companyCode } = useCompany();
  const [downloading, setDownloading] = useState(false);

  const dateStr = session?.started_at ? session.started_at.slice(0, 10) : new Date().toISOString().slice(0, 10);
  const cleanMachine = (session?.machine_code || 'MCH').replace(/[^a-zA-Z0-9_-]/g, '_');
  const cleanPart = (session?.part_number || 'PART').replace(/[^a-zA-Z0-9_-]/g, '_');
  const shiftStr = session?.shift || 'A';
  const isSetupReport = session?.is_setup_approval_only === true;
  const shiftHours = session?.factory_shift_hours || session?.shift_hours || session?.shift_duration_hours || session?.total_hourly_slots || 8;
  const shiftSlots = Array.from({ length: shiftHours }, (_, i) => i + 1);

  const reportPrefix = isSetupReport ? 'Setup_Approval_Report' : 'Form_F02_Report';
  const fileName = `${reportPrefix}_${dateStr}_Shift_${shiftStr}_${cleanMachine}_${cleanPart}.pdf`;

  const handleDownloadPDF = async () => {
    const sessionId = session?.session_id;
    if (!sessionId) {
      alert('This report does not have a valid inspection session ID.');
      return;
    }

    setDownloading(true);
    try {
      // Use the same server-generated PDF as the mobile app. This keeps the
      // dashboard and mobile reports on one layout and avoids cropping caused
      // by html2pdf capturing the scrollable report container.
      const response = await api.get(`/api/inspections/${sessionId}/pdf/`, {
        responseType: 'blob',
      });
      const blobUrl = window.URL.createObjectURL(response.data);
      const link = document.createElement('a');
      link.href = blobUrl;
      link.download = response.headers['content-disposition']?.match(/filename="?([^";]+)"?/i)?.[1] || fileName;
      document.body.appendChild(link);
      link.click();
      link.remove();
      // Some browsers start consuming the download asynchronously.
      // Keep the object URL alive briefly so the download is not cancelled.
      window.setTimeout(() => window.URL.revokeObjectURL(blobUrl), 1000);
    } catch (error) {
      console.error('Failed to download official PDF report:', error);
      alert('Failed to download the official PDF report. Please try again.');
    } finally {
      setDownloading(false);
    }
  };

  useEffect(() => {
    if (autoDownload) {
      const timer = setTimeout(() => {
        handleDownloadPDF();
      }, 400);
      return () => clearTimeout(timer);
    }
  }, [autoDownload, session?.session_id]);

  // Master Data & Measurements
  const masterProductParams = session?.parameter_summary || session?.parameters || session?.template_parameters || [];
  const masterProcessParams = session?.process_parameter_summary || session?.process_parameters || [];
  const measurements = session?.measurements || [];

  const productMap = {};
  const processMap = {};

  // 1. Populate Product Parameters
  masterProductParams.forEach((p, idx) => {
    const code = p.parameter_code || `P${idx + 1}`;
    const nom = p.nominal ?? p.nominal_value ?? 0;
    const ll = p.lower_limit;
    const ul = p.upper_limit;
    const unit = p.unit || 'mm';

    let specStr = `${nom} ${unit}`;
    if (ll !== undefined && ul !== undefined && ll !== null && ul !== null) {
      specStr = `${nom} ${unit} [${ll} to ${ul}]`;
    }

    productMap[code] = {
      code: code,
      no: String(idx + 1).padStart(2, '0'),
      name: p.parameter_name || code,
      nominal: nom,
      lower_limit: ll,
      upper_limit: ul,
      unit: unit,
      spec: p.specification || specStr,
      critical: p.is_critical || false,
      method: p.measurement_technique || p.evaluation_technique || p.gauge_used || 'VERNIER CALIPER',
      sample: p.sample_size || p.sample_frequency || '5NOS/SHIFT',
      trials: {},
      trialsOOC: {},
      hourly: {},
      hourlyOOC: {},
    };
  });

  // 2. Populate Process Parameters
  masterProcessParams.forEach((pp, idx) => {
    const code = pp.parameter_code || `PR${idx + 1}`;
    processMap[code] = {
      code: code,
      no: String(idx + 1).padStart(2, '0'),
      name: pp.parameter_name || code,
      spec: pp.specification || 'CHECKLIST / DISPLAY',
      method: pp.measurement_technique || 'CHECKLIST',
      sample: pp.sample_frequency || '1ST PC ONLY',
      trials: {},
      trialsOOC: {},
    };
  });

  // 3. Map Actual Measurements & Setup Process Entries
  measurements.forEach((m) => {
    const pCode = m.parameter_code;
    const isProd = productMap[pCode];
    const isProc = processMap[pCode];
    const targetMap = isProd || isProc;

    if (!targetMap) return;

    const val = m.measured_value ?? m.value ?? m.val;

    if (m.inspection_type === 'first_piece' || m.inspection_type === 'setup') {
      const trialNum = m.trial_number || 1;
      targetMap.trials[trialNum] = val;
      if (m.status === 'out_of_spec' || m.status === 'rejected') {
        targetMap.trialsOOC[trialNum] = true;
      }
    } else if (m.inspection_type === 'hourly' && isProd) {
      const slotNum = m.hourly_slot;
      if (slotNum) {
        targetMap.hourly[slotNum] = val;
        if (m.status === 'out_of_spec' || m.status === 'rejected') {
          targetMap.hourlyOOC[slotNum] = true;
        }
      }
    }
  });

  const processParamEntries = session?.process_param_entries || [];
  processParamEntries.forEach((entry) => {
    const code = entry.parameter_code;
    const name = entry.parameter_name;
    const target = (code && processMap[code]) || Object.values(processMap).find(p => p.name === name);
    if (target) {
      if (entry.trial_1 !== undefined && entry.trial_1 !== null && String(entry.trial_1).trim() !== '') target.trials[1] = entry.trial_1;
      if (entry.trial_2 !== undefined && entry.trial_2 !== null && String(entry.trial_2).trim() !== '') target.trials[2] = entry.trial_2;
      if (entry.trial_3 !== undefined && entry.trial_3 !== null && String(entry.trial_3).trim() !== '') target.trials[3] = entry.trial_3;
    }
  });

  const productList = Object.values(productMap);
  const processList = Object.values(processMap);

  return (
    <Modal
      isOpen={true}
      onClose={onClose}
      title={isSetupReport ? "Official First Piece Setup Approval Report (Form F02)" : "Official 1st Piece Cum In-Process Inspection Report (Form F02)"}
      size="2xl"
      footer={
        <div style={{ display: 'flex', justifyContent: 'space-between', width: '100%', alignItems: 'center' }}>
          <div style={{ fontSize: '0.85rem', color: '#64748b' }}>
            📋 Shift Hours: {shiftHours} Hours Mode
          </div>
          <div style={{ display: 'flex', gap: '8px' }}>
            <button
              className="btn btn-primary"
              onClick={handleDownloadPDF}
              disabled={downloading}
            >
              {downloading ? 'Generating PDF...' : 'Download PDF Copy'}
            </button>
            <button className="btn btn-ghost" onClick={onClose}>Close</button>
          </div>
        </div>
      }
    >
      <div
        id="official-form-f02-report"
        style={{
          background: '#ffffff',
          color: '#000000',
          padding: '12px 14px',
          boxSizing: 'border-box',
          width: '100%',
          minWidth: shiftHours > 8 ? '1060px' : '900px',
          fontFamily: "Arial, 'Helvetica Neue', sans-serif",
          fontSize: 9.5,
          lineHeight: 1.2,
        }}
      >
        {/* TOP HEADER */}
        <table style={{ width: '100%', borderCollapse: 'collapse', border: '1.5px solid #000000', marginBottom: 6 }}>
          <tbody>
            <tr style={{ borderBottom: '1.5px solid #000000' }}>
              <td style={{ width: '12%', padding: '6px 4px', borderRight: '1.5px solid #000000', textAlign: 'center', background: '#000000', color: '#ffffff' }}>
                <div style={{ fontSize: 16, fontWeight: 'bold', letterSpacing: 1 }}>{companyCode}</div>
              </td>
              <td style={{ width: '73%', padding: '4px 10px', borderRight: '1.5px solid #000000', textAlign: 'center' }}>
                <div style={{ fontSize: 14, fontWeight: 'bold', letterSpacing: '0.5px', color: '#000000' }}>{companyName.toUpperCase()}</div>
                <div style={{ fontSize: 11, fontWeight: 'bold', marginTop: 1, color: '#000000' }}>
                  {isSetupReport ? 'FIRST PIECE SETUP APPROVAL REPORT : PROCESS NO. 10' : '1ST PIECE CUM IN-PROCESS INSPECTION REPORT : PROCESS NO. 10'}
                </div>
              </td>
              <td style={{ width: '15%', padding: '4px 6px', textAlign: 'right', fontSize: 8.5, color: '#000000' }}>
                <div><strong>DOC REF:</strong> {companyCode}/PRD/F02</div>
                <div><strong>REV:</strong> 02 (15.8.2013)</div>
                <div style={{ marginTop: 1, fontWeight: 'bold' }}>PAGE 1 OF 1</div>
              </td>
            </tr>
            <tr style={{ borderBottom: '1px solid #000000', background: '#ffffff' }}>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>PROCESS NO:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>10.</strong>
              </td>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>PART NAME & NO:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>{session?.part_number} ({session?.part_name || 'POLY V PULLEY'})</strong>
              </td>
              <td style={{ padding: '3px 6px' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>INSPECTOR / OPERATOR:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>{session?.operator_name || `Inspector #${session?.operator_id || ''}`}</strong>
              </td>
            </tr>
            <tr style={{ background: '#ffffff' }}>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>MACHINE NO:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000', fontFamily: 'Consolas, monospace' }}>{session?.machine_code}</strong>
              </td>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>DATE & SHIFT:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>{formatDate(session?.started_at || session?.created_at)} &nbsp;|&nbsp; Shift {session?.shift || 'A'}</strong>
              </td>
              <td style={{ padding: '3px 6px' }}>
                <span style={{ fontSize: 8, color: '#555555', textTransform: 'uppercase' }}>SETUP STATUS:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>{session?.status ? session.status.toUpperCase().replace('_', ' ') : 'APPROVED'}</strong>
              </td>
            </tr>
          </tbody>
        </table>

        {/* MAIN DATA TABLE */}
        <div style={{ overflowX: 'auto', width: '100%' }}>
          <table style={{ width: '100%', minWidth: shiftHours > 8 ? '1080px' : '900px', borderCollapse: 'collapse', border: '1.5px solid #000000', textAlign: 'center', fontSize: 8.2 }}>
            <thead>
              <tr style={{ background: '#e2e8f0', borderBottom: '1.5px solid #000000', color: '#000000' }}>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '2.5%' }}>P.No</th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '2.5%' }}>No</th>
                <th style={{ border: '1px solid #000000', padding: '3px 2px', width: isSetupReport ? '23%' : '14%', textAlign: 'left' }}>
                  Parameter Name
                </th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '3.5%' }}>Class</th>
                <th style={{ border: '1px solid #000000', padding: '3px 2px', width: isSetupReport ? '17%' : '10.5%' }}>Specification</th>
                <th style={{ border: '1px solid #000000', padding: '3px 2px', width: isSetupReport ? '17%' : '10.5%' }}>Evaluation Technique</th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: isSetupReport ? '12%' : '7.5%' }}>Sample Freq</th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: isSetupReport ? '7%' : '3.5%', background: '#cbd5e1' }}>1st #1</th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: isSetupReport ? '7%' : '3.5%', background: '#cbd5e1' }}>1st #2</th>
                <th style={{ border: '1px solid #000000', padding: '3px 1px', width: isSetupReport ? '7%' : '3.5%', background: '#cbd5e1' }}>1st #3</th>
                
                {!isSetupReport && (
                  <>
                    {Array.from({ length: shiftHours }, (_, i) => i + 1).map((sNum) => (
                      <th key={sNum} style={{ border: '1px solid #000000', padding: '3px 1px', width: `${38 / shiftHours}%`, background: '#dcfce7' }}>
                        {sNum}/Hr
                      </th>
                    ))}
                  </>
                )}
              </tr>
            </thead>
            <tbody>
              {/* SECTION 1 BANNER: PRODUCT PARAMETERS */}
              {processList.length > 0 && (
                <tr style={{ background: '#e2e8f0', fontWeight: 'bold' }}>
                  <td colSpan={isSetupReport ? 10 : 10 + shiftHours} style={{ border: '1px solid #000000', padding: '3px 6px', textAlign: 'left', color: '#1e3a8a', fontSize: 9 }}>
                    SECTION 1: PRODUCT PARAMETER (QUALITY CHARACTERISTICS & DIMENSIONS)
                  </td>
                </tr>
              )}

              {productList.map((p, i) => {
                const tr1 = p.trials[1];
                const tr2 = p.trials[2];
                const tr3 = p.trials[3];
                const hr  = p.hourly || {};

                const tr1OOC = p.trialsOOC?.[1] || isValOOC(tr1, p.lower_limit, p.upper_limit);
                const tr2OOC = p.trialsOOC?.[2] || isValOOC(tr2, p.lower_limit, p.upper_limit);
                const tr3OOC = p.trialsOOC?.[3] || isValOOC(tr3, p.lower_limit, p.upper_limit);

                const isAltRow = i % 2 === 1;

                return (
                  <tr key={`prod-${i}`} style={{ borderBottom: '1px solid #000000', background: isAltRow ? '#f8fafc' : '#ffffff' }}>
                    <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold' }}>10.</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold', fontFamily: 'Consolas, monospace' }}>{p.no}</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 4px', textAlign: 'left', fontWeight: 'bold' }}>{p.name}</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 1px' }}>{p.critical ? <span style={{ color: '#dc2626', fontSize: 8, fontWeight: 'bold' }}>CRITICAL</span> : '-'}</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 4px', fontFamily: 'Consolas, monospace', fontWeight: 'bold' }}>{p.spec}</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 4px', fontSize: 7.5, textTransform: 'uppercase' }}>{p.method}</td>
                    <td style={{ border: '1px solid #000000', padding: '2px 2px', fontSize: 7.5 }}>{p.sample}</td>
                    
                    <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr1OOC ? 'bold' : 'normal', fontSize: 9, fontFamily: 'Consolas, monospace', color: tr1OOC ? '#dc2626' : '#000000', background: tr1OOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                      {tr1 !== undefined ? tr1 : '-'}
                    </td>
                    <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr2OOC ? 'bold' : 'normal', fontSize: 9, fontFamily: 'Consolas, monospace', color: tr2OOC ? '#dc2626' : '#000000', background: tr2OOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                      {tr2 !== undefined ? tr2 : '-'}
                    </td>
                    <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr3OOC ? 'bold' : 'normal', fontSize: 9, fontFamily: 'Consolas, monospace', color: tr3OOC ? '#dc2626' : '#000000', background: tr3OOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                      {tr3 !== undefined ? tr3 : '-'}
                    </td>

                    {!isSetupReport && Array.from({ length: shiftHours }, (_, i) => i + 1).map((slot) => {
                      const hVal = hr[slot];
                      const hOOC = p.hourlyOOC?.[slot] || isValOOC(hVal, p.lower_limit, p.upper_limit);
                      return (
                        <td key={slot} style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: hOOC ? 'bold' : 'normal', fontSize: 9, fontFamily: 'Consolas, monospace', color: hOOC ? '#dc2626' : '#000000', background: hOOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                          {hVal !== undefined ? hVal : '-'}
                        </td>
                      );
                    })}
                  </tr>
                );
              })}

              {/* SECTION 2 BANNER & ROWS: PROCESS PARAMETERS */}
              {processList.length > 0 && (
                <>
                  <tr style={{ background: '#e2e8f0', fontWeight: 'bold' }}>
                    <td colSpan={isSetupReport ? 10 : 10 + shiftHours} style={{ border: '1px solid #000000', padding: '3px 6px', textAlign: 'left', color: '#1e3a8a', fontSize: 9 }}>
                      SECTION 2: PROCESS PARAMETER (FIRST PIECE SETUP APPROVAL CHECKS)
                    </td>
                  </tr>
                  {processList.map((pp, i) => {
                    const tr1 = pp.trials[1];
                    const tr2 = pp.trials[2];
                    const tr3 = pp.trials[3];
                    const isAltRow = i % 2 === 1;

                    return (
                      <tr key={`proc-${i}`} style={{ borderBottom: '1px solid #000000', background: isAltRow ? '#f8fafc' : '#ffffff' }}>
                        <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold' }}>10.</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold', fontFamily: 'Consolas, monospace' }}>{pp.no}</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 4px', textAlign: 'left', fontWeight: 'bold' }}>{pp.name}</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 1px' }}>-</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 4px', fontFamily: 'Consolas, monospace', fontWeight: 'bold' }}>{pp.spec}</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 4px', fontSize: 7.5, textTransform: 'uppercase' }}>{pp.method}</td>
                        <td style={{ border: '1px solid #000000', padding: '2px 2px', fontSize: 7.5 }}>{pp.sample}</td>
                        
                        <td style={{ border: '1px solid #000000', padding: '2px 1px', fontSize: 9, fontFamily: 'Consolas, monospace', fontWeight: 'bold' }}>
                          {tr1 !== undefined ? tr1 : '-'}
                        </td>
                        <td style={{ border: '1px solid #000000', padding: '2px 1px', fontSize: 9, fontFamily: 'Consolas, monospace', fontWeight: 'bold' }}>
                          {tr2 !== undefined ? tr2 : '-'}
                        </td>
                        <td style={{ border: '1px solid #000000', padding: '2px 1px', fontSize: 9, fontFamily: 'Consolas, monospace', fontWeight: 'bold' }}>
                          {tr3 !== undefined ? tr3 : '-'}
                        </td>

                        {!isSetupReport && Array.from({ length: shiftHours }, (_, i) => i + 1).map((slot) => (
                          <td key={slot} style={{ border: '1px solid #000000', padding: '2px 1px', fontSize: 9, fontFamily: 'Consolas, monospace', color: '#94a3b8' }}>
                            -
                          </td>
                        ))}
                      </tr>
                    );
                  })}
                </>
              )}
            </tbody>
          </table>
        </div>

        {/* REACTION PLAN */}
        <div style={{ marginTop: 6, padding: '4px 8px', border: '1px solid #000000', background: '#f8fafc', fontSize: 7.5, color: '#334155' }}>
          <strong>REACTION PLAN:</strong> REJECT, REWORK, SEGREGATE, INFORM SUPERVISOR OR READJUST THE PROCESS
        </div>

        {/* SIGNATURE BLOCK */}
        <div style={{ marginTop: 10, display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16, textAlign: 'center', borderTop: '1.5px solid #000000', paddingTop: 8 }}>
          <div>
            <div style={{ borderBottom: '1px dashed #000000', paddingBottom: 10, marginBottom: 3, fontStyle: 'italic', color: '#000000', fontSize: 9.5 }}>
              {session?.operator_name || 'Operator Sign'}
            </div>
            <strong style={{ fontSize: 9, letterSpacing: '0.5px' }}>OPERATOR SIGNATURE</strong>
          </div>
          <div>
            <div style={{ borderBottom: '1px dashed #000000', paddingBottom: 10, marginBottom: 3, fontStyle: 'italic', color: '#000000', fontSize: 9.5 }}>
              {session?.inspector_name || session?.finalized_by_name || 'Quality Inspector'}
            </div>
            <strong style={{ fontSize: 9, letterSpacing: '0.5px' }}>QUALITY INSPECTOR SIGNATURE</strong>
          </div>
          <div>
            <div style={{ borderBottom: '1px dashed #000000', paddingBottom: 10, marginBottom: 3, fontStyle: 'italic', color: '#000000', fontSize: 9.5 }}>
              {session?.supervisor_name || 'Supervisor Sign'}
            </div>
            <strong style={{ fontSize: 9, letterSpacing: '0.5px' }}>SUPERVISOR SIGNATURE</strong>
          </div>
        </div>
      </div>
    </Modal>
  );
}
