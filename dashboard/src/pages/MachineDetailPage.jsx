import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import { showAccessDenied } from '../components/common/AccessDeniedModal';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import Badge from '../components/common/Badge';
import LiveSheetViewer from '../components/inspection/LiveSheetViewer';
import api from '../api/axios';
import { getSessionDetail, getSessions } from '../api/inspections';
import { useCompany } from '../context/CompanyContext';
import { getMachinePerformance } from '../api/analytics';
import { useWebSocket } from '../context/WebSocketContext';
import { fmt, formatDateTime, formatDate } from '../utils/formatters';

export default function MachineDetailPage() {
  const { machineId } = useParams();
  const { user } = useAuth();
  const canReview = can(user, 'quality.inspections.review');
  const requireReviewAccess = (action) => {
    if (canReview) return true;
    showAccessDenied(`You have view-only access to machine history. Review permission is required to ${action}.`);
    return false;
  };
  const [machine, setMachine]         = useState(null);
  const [performance, setPerformance] = useState(null);
  const [historySessions, setHistorySessions] = useState([]);
  const [activeSessionDocs, setActiveSessionDocs] = useState([]);
  const [loading, setLoading]         = useState(true);
  const [lastUpdatedCode, setLastUpdatedCode] = useState(null);
  const [selectedHistorySessionId, setSelectedHistorySessionId] = useState(null);
  const updateTimeoutRef = useRef(null);
  // Stable ref so WS effect can read current machine_code without depending on `machine` state
  const machineCodeRef = useRef(null);

  const ws = useWebSocket();
  const wsEvents = ws?.events ?? [];

  const { companyName, companyCode } = useCompany();

  // Fetch machine details, performance summary, and session history
  const fetchData = useCallback(async () => {
    try {
      // 1. Fetch machine details
      const mRes = await api.get(`/api/machines/${machineId}/`);
      const mData = mRes.data;
      setMachine(mData);
      machineCodeRef.current = mData.machine_code;

      // 2. Fetch performance stats
      const pRes = await getMachinePerformance(machineId, 30);
      setPerformance(pRes.data);

      // 3. Fetch all sessions for this machine
      const sRes = await getSessions({ machine: mData.machine_code });
      const sessionsList = sRes.data?.results ?? sRes.data ?? [];
      setHistorySessions(Array.isArray(sessionsList) ? sessionsList : []);

      // 4. Find today's active inspection sessions for this machine
      // Compare using local date (IST) : not raw UTC string slice
      const todayLocal = new Date().toLocaleDateString('en-CA'); // "YYYY-MM-DD" in local TZ

      const todaySessions = (Array.isArray(sessionsList) ? sessionsList : []).filter((s) => {
        if (!s.started_at) return false;
        const sDateLocal = new Date(s.started_at).toLocaleDateString('en-CA');
        return sDateLocal === todayLocal;
      });

      const activeOpsMap = {};
      todaySessions.forEach(s => {
        const opName = s.template_name || (s.template_version ? `Operation ${s.template_version}` : '-');
        const opKey = `${s.part_number}_${opName}`;
        // Keep the latest one for each operation
        if (!activeOpsMap[opKey]) {
          activeOpsMap[opKey] = s;
        }
      });
      
      let activeOrLatestOps = Object.values(activeOpsMap);
      if (activeOrLatestOps.length === 0 && sessionsList.length > 0) {
        activeOrLatestOps.push(sessionsList[0]);
      }

      if (activeOrLatestOps.length > 0) {
        const docs = await Promise.all(activeOrLatestOps.map(s => getSessionDetail(s.session_id)));
        setActiveSessionDocs(docs.map(res => res.data));
      } else {
        setActiveSessionDocs([]);
      }
    } catch {
      /* handle errors gracefully */
    } finally {
      setLoading(false);
    }
  }, [machineId]);

  const handleClearHistory = async () => {
    if (!requireReviewAccess('clear inspection history')) return;
    if (!machine) return;
    if (!window.confirm(`Are you sure you want to clear all test inspection history for machine ${machine.machine_code}? This will start machine history cleanly at 0.`)) {
      return;
    }
    try {
      await api.delete(`/api/inspections/clear-history/?machine_code=${machine.machine_code}`);
      alert(`✓ All test inspection history for ${machine.machine_code} cleared cleanly!`);
      await fetchData();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to clear machine history.');
    }
  };

  const handleDeleteSession = async (sId) => {
    if (!requireReviewAccess('delete an inspection session')) return;
    if (!window.confirm(`Delete test session ${sId.slice(0, 8).toUpperCase()}?`)) return;
    try {
      await api.delete(`/api/inspections/clear-history/?session_id=${sId}`);
      await fetchData();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to delete session.');
    }
  };

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Listen to WebSocket events for real-time measurement entries.
  // NOTE: We intentionally use machineCodeRef (not `machine` state) in this effect
  // to avoid an infinite loop: fetchData sets `machine` → effect re-runs → fetchData
  // called again → repeat. The ref is always kept in sync inside fetchData.
  useEffect(() => {
    if (!wsEvents.length || !machineCodeRef.current) return;
    const latest = wsEvents[0];
    const currentMachineCode = machineCodeRef.current;

    // If measurement recorded for this machine
    if (latest.event === 'measurement_recorded' && latest.machine_code === currentMachineCode) {
      setActiveSessionDocs((prevDocs) => {
        const sessionIndex = prevDocs.findIndex(d => d.session_id === latest.session_id);
        const base = sessionIndex >= 0 ? prevDocs[sessionIndex] : {
          session_id: latest.session_id,
          machine_code: latest.machine_code,
          part_number: latest.part_number,
          part_name: latest.part_name,
          template_name: latest.template_name,
          template_version: latest.template_version,
          operator_name: latest.operator_name,
          shift: latest.shift || 'A',
          measurements: [],
        };
        const updatedMeasurements = [...(base.measurements || [])];
        const trialNo = latest.trial_number || 1;
        const inspType = latest.inspection_type || (trialNo > 3 ? 'hourly' : 'first_piece');
        const slot = latest.hourly_slot || (inspType === 'hourly' ? trialNo : 1);

        const existingIdx = updatedMeasurements.findIndex(
          (m) => m.parameter_code === latest.parameter_code &&
                 (m.inspection_type || 'first_piece') === inspType &&
                 (inspType === 'hourly' ? (m.hourly_slot || 1) === slot : (m.trial_number || 1) === trialNo)
        );

        const newMeasurement = {
          parameter_code:  latest.parameter_code,
          parameter_name:  latest.parameter_name,
          nominal:         latest.nominal,
          lower_limit:     latest.lower_limit,
          upper_limit:     latest.upper_limit,
          unit:            latest.unit,
          measured_value:  latest.measured_value,
          status:          latest.status,
          is_critical:     latest.is_critical,
          voice_raw_text:  latest.voice_raw_text,
          method:          latest.method,
          inspection_type: inspType,
          trial_number:    trialNo,
          hourly_slot:     slot,
          recorded_at:     latest._receivedAt || new Date().toISOString(),
        };

        if (existingIdx >= 0) {
          updatedMeasurements[existingIdx] = newMeasurement;
        } else {
          updatedMeasurements.push(newMeasurement);
        }

        const newDoc = {
          ...base,
          measurements: updatedMeasurements,
          progress: latest.progress ?? base.progress,
        };
        
        if (sessionIndex >= 0) {
          const nextDocs = [...prevDocs];
          nextDocs[sessionIndex] = newDoc;
          return nextDocs;
        } else {
          return [newDoc, ...prevDocs];
        }
      });

      // Highlight updated cell briefly
      setLastUpdatedCode(latest.parameter_code);
      if (updateTimeoutRef.current) clearTimeout(updateTimeoutRef.current);
      updateTimeoutRef.current = setTimeout(() => setLastUpdatedCode(null), 3000);
    }

    // Refresh full data only on session lifecycle events (not on every measurement)
    if (['session_started', 'session_completed'].includes(latest.event) && latest.machine_code === currentMachineCode) {
      fetchData();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wsEvents[0]?._receivedAt]); // intentionally omit fetchData & machine : see note above

  if (loading) {
    return (
      <>
        <Header title="Machine Station Details" />
        <div className="page-content bg-gradient-animated">
          <LoadingSpinner message="Fetching machine details & live inspection sheet..." />
        </div>
      </>
    );
  }

  if (!machine) {
    return (
      <>
        <Header title="Machine Station Details" />
        <div className="page-content bg-gradient-animated">
          <div className="card text-center" style={{ padding: 40 }}>
            <h3>Machine Not Found</h3>
            <Link to="/machines" className="btn btn-primary mt-20">Back to Machines</Link>
          </div>
        </div>
      </>
    );
  }

  const isValOOC = (val, lower, upper, status) => {
    if (status === 'out_of_spec' || status === 'rejected' || status === 'ooc') return true;
    if (val === undefined || val === null || val === '') return false;
    const num = Number(val);
    if (isNaN(num)) return false;
    if (lower !== undefined && lower !== null && lower !== '' && num < Number(lower)) return true;
    if (upper !== undefined && upper !== null && upper !== '' && num > Number(upper)) return true;
    return false;
  };

  return (
    <>
      <Header
        title={`Station: ${machine.machine_code} (${machine.name})`}
        subtitle="Live Operator Voice Entry Sheet & Historical Inspection Logs"
      />

      <div className="page-content bg-gradient-animated">
        <Breadcrumbs items={[{ label: 'Machines', to: '/machines' }, { label: machine.machine_code }]} />

        {/* Station Profile Card */}
        <div className="card mb-20">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <h3 style={{ margin: 0 }}>Station Profile</h3>
            <span className={`badge badge-${machine.status?.toLowerCase() === 'active' ? 'ok' : 'pending'}`}>
              {machine.status}
            </span>
          </div>
          <div style={{ display: 'flex', gap: 32, flexWrap: 'wrap' }}>
            <div className="info-item">
              <span className="info-label">Code / Name</span>
              <span className="info-value font-bold">{machine.machine_code} · {machine.name}</span>
            </div>
            <div className="info-item">
              <span className="info-label">Location / Plant</span>
              <span className="info-value">{machine.plant_name ?? 'Main Plant #1'}</span>
            </div>
          </div>
        </div>

        {/* REAL-TIME EMBEDDED LIVE INSPECTION SHEET (FORM F02) */}
        <div className="card mb-20">
          <div className="section-header" style={{ marginBottom: 16 }}>
            <div className="section-title" style={{ fontSize: '1.05rem' }}>
              <span className="dot" style={{ background: activeSessionDocs.length > 0 ? 'var(--accent-purple)' : 'var(--accent-blue)' }} />
              Live Operator Inspection Sheet ({companyCode} Form F02)
              {activeSessionDocs.length > 0 && (
                <span className="badge badge-voice" style={{ marginLeft: 8, animation: 'pulse-badge 1s infinite' }}>
                  REAL-TIME LIVE UPDATES
                </span>
              )}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <div className="ws-indicator">
                <span className="ws-dot" />
                <span>WebSockets Connected</span>
              </div>
              <button className="btn btn-ghost btn-sm" onClick={fetchData}>↻ Refresh Sheet</button>
            </div>
          </div>

          {activeSessionDocs.length === 0 ? (
            <div className="empty-state" style={{ padding: '40px 20px', background: 'var(--bg-elevated)', borderRadius: 'var(--radius-md)' }}>
              <div className="empty-state-text" style={{ fontSize: '1rem', fontWeight: 600, color: 'var(--text-primary)' }}>
                No Live Inspection Started for Today ({machine.machine_code})
              </div>
              <p className="text-xs text-muted mt-6" style={{ maxWidth: 520, lineHeight: 1.5 }}>
                No live inspection has started for today. The live report will be created automatically when the Inspector starts today's First Piece Inspection.
              </p>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 32 }}>
              {activeSessionDocs.map((doc) => {
                const activeMeasurements = doc?.measurements || [];
                const paramMap = {};
                activeMeasurements.forEach((m) => {
                  const code = m.parameter_code;
                  const trialNo = m.trial_number || 1;
                  const isHourlyMeas = m.inspection_type === 'hourly';

                  if (!paramMap[code]) {
                    paramMap[code] = {
                      code: code,
                      name: m.parameter_name,
                      nominal: m.nominal,
                      lower_limit: m.lower_limit,
                      upper_limit: m.upper_limit,
                      unit: m.unit,
                      trials: {},
                      trialStatuses: {},
                      trialsOOC: {},
                      hourly: {},
                      hourlyStatuses: {},
                      hourlyOOC: {},
                      hasOOC: false,
                      lastVoiceText: m.voice_raw_text,
                    };
                  } else {
                    if (m.lower_limit !== undefined && m.lower_limit !== null) paramMap[code].lower_limit = m.lower_limit;
                    if (m.upper_limit !== undefined && m.upper_limit !== null) paramMap[code].upper_limit = m.upper_limit;
                  }

                  const isOOC = (m.status === 'out_of_spec' || m.status === 'rejected' || m.status === 'ooc') ||
                                isValOOC(m.measured_value, m.lower_limit ?? paramMap[code].lower_limit, m.upper_limit ?? paramMap[code].upper_limit);

                  if (isHourlyMeas) {
                    const slot = m.hourly_slot || 1;
                    paramMap[code].hourly[slot] = m.measured_value;
                    paramMap[code].hourlyStatuses[slot] = m.status;
                    paramMap[code].hourlyOOC[slot] = isOOC;
                  } else {
                    const tNo = (trialNo >= 1 && trialNo <= 3) ? trialNo : 1;
                    paramMap[code].trials[tNo] = m.measured_value;
                    paramMap[code].trialStatuses[tNo] = m.status;
                    paramMap[code].trialsOOC[tNo] = isOOC;
                  }

                  if (m.voice_raw_text) {
                    paramMap[code].lastVoiceText = m.voice_raw_text;
                  }
                });

                Object.values(paramMap).forEach((p) => {
                  const trialKeys = Object.keys(p.trials).map(Number).sort((a, b) => b - a);
                  const latestTrial = trialKeys[0];
                  const isLatestTrialOOC = latestTrial ? (p.trialsOOC[latestTrial] || p.trialStatuses[latestTrial] === 'out_of_spec') : false;
                  const isAnyHourlyOOC = Object.values(p.hourlyOOC).some(Boolean) || Object.values(p.hourlyStatuses).some((st) => st === 'out_of_spec');
                  p.hasOOC = isLatestTrialOOC || isAnyHourlyOOC;
                });

                const groupedParams = Object.values(paramMap);
                const opName = doc.template_name || (doc.template_version ? `Operation ${doc.template_version}` : '-');
                return (
                  <div key={doc.session_id}>
            <div>
              {/* Active Operator Banner */}
              <div
                style={{
                  background: 'rgba(139, 92, 246, 0.12)',
                  border: '1px solid rgba(139, 92, 246, 0.3)',
                  borderRadius: 'var(--radius-md)',
                  padding: '12px 16px',
                  marginBottom: 16,
                  display: 'flex',
                  justify: 'space-between',
                  alignItems: 'center',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                  <div>
                    <div style={{ fontSize: '0.95rem', fontWeight: 700, color: 'var(--text-primary)' }}>
                      Operator: {doc.operator_name || `Operator #${doc.operator_id}`}
                    </div>
                    <div style={{ fontSize: '0.8rem', color: 'var(--text-secondary)' }}>
                      Part: <strong>{doc.part_number}</strong> ({doc.part_name || ''}) · Operation: <strong>{opName}</strong> · Shift {doc.shift} · {doc.inspection_type === 'first_piece' ? '1st Piece Cum In-Process' : (doc.inspection_type?.replace('_', ' ') || 'Inspection')}
                    </div>
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <Badge type={doc.status} />
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--text-primary)', marginTop: 4 }}>
                    Progress: {doc.progress ?? 0}%
                  </div>
                </div>
              </div>

              {/* Form F02 Embedded Table */}
              <div
                className="official-report-sheet"
                style={{
                  background: '#ffffff',
                  color: '#000000',
                  padding: '14px 18px',
                  fontFamily: "Arial, 'Helvetica Neue', sans-serif",
                  fontSize: 10.5,
                  borderRadius: 8,
                  boxShadow: '0 4px 24px rgba(0,0,0,0.6)',
                }}
              >
                {/* Sheet Title */}
                <table style={{ width: '100%', borderCollapse: 'collapse', border: '1.5px solid #000000', marginBottom: 8 }}>
                  <tbody>
                    <tr style={{ borderBottom: '1.5px solid #000000' }}>
                      <td style={{ width: '12%', padding: '6px 4px', borderRight: '1.5px solid #000000', textAlign: 'center', background: '#000000', color: '#ffffff' }}>
                        <div style={{ fontSize: 16, fontWeight: 'bold', letterSpacing: 1 }}>{companyCode}</div>
                      </td>
                      <td style={{ width: '73%', padding: '4px 10px', borderRight: '1.5px solid #000000', textAlign: 'center' }}>
                        <div style={{ fontSize: 14, fontWeight: 'bold', letterSpacing: '0.5px', color: '#000000' }}>{companyName.toUpperCase()}</div>
                        <div style={{ fontSize: 12, fontWeight: 'bold', marginTop: 3, color: '#000000' }}>
                          {opName.toUpperCase()} - {doc.inspection_type === 'hourly' ? 'HOURLY IN-PROCESS INSPECTION REPORT' : '1ST PIECE CUM IN-PROCESS INSPECTION REPORT'}
                        </div>
                      </td>
                      <td style={{ width: '15%', padding: '4px 6px', textAlign: 'right', fontSize: 8.5, color: '#000000' }}>
                        <div><strong>DOC REF:</strong> {companyCode}/PRD/F02</div>
                        <div><strong>REV:</strong> 02 (15.8.2013)</div>
                        <div style={{ marginTop: 1, fontWeight: 'bold', color: '#7c3aed' }}>LIVE VIEW</div>
                      </td>
                    </tr>
                    <tr style={{ background: '#f8fafc' }}>
                      <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                        <span style={{ fontSize: 8, color: '#555555' }}>PART NO:</span>{' '}
                        <strong style={{ fontSize: 10, color: '#000000', fontFamily: 'Consolas, monospace' }}>{doc.part_number}</strong>
                      </td>
                      <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                        <span style={{ fontSize: 8, color: '#555555' }}>OPERATOR:</span>{' '}
                        <strong style={{ fontSize: 10, color: '#000000' }}>{doc.operator_name || `Operator #${doc.operator_id}`}</strong>
                        <span style={{ fontSize: 8, color: '#555555', marginLeft: 16 }}>OPERATION:</span>{' '}
                        <strong style={{ fontSize: 10, color: '#000000' }}>{opName}</strong>
                      </td>
                      <td style={{ padding: '3px 6px' }}>
                        <span style={{ fontSize: 8, color: '#555555' }}>MACHINE:</span>{' '}
                        <strong style={{ fontSize: 10, color: '#000000', fontFamily: 'Consolas, monospace' }}>{machine.machine_code}</strong>
                      </td>
                    </tr>
                  </tbody>
                </table>

                {/* Parameter Table */}
                <table style={{ width: '100%', borderCollapse: 'collapse', border: '1.5px solid #000000', textAlign: 'center', fontSize: 9.5 }}>
                  <thead>
                    <tr style={{ background: '#e2e8f0', borderBottom: '1.5px solid #000000', color: '#000000' }}>
                      <th style={{ border: '1px solid #000000', padding: '4px 4px', width: '16%', textAlign: 'left', fontWeight: 'bold' }}>Parameter</th>
                      <th style={{ border: '1px solid #000000', padding: '4px 4px', width: '18%', fontWeight: 'bold' }}>Specification</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '7%', fontWeight: 'bold', background: '#cbd5e1' }}>1st Pc #1</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '7%', fontWeight: 'bold', background: '#cbd5e1' }}>1st Pc #2</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '7%', fontWeight: 'bold', background: '#cbd5e1' }}>1st Pc #3</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>1/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>2/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>3/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>4/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>5/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>6/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>7/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', fontWeight: 'bold' }}>8/Hr</th>
                      <th style={{ border: '1px solid #000000', padding: '4px 2px', width: '7%', fontWeight: 'bold' }}>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {groupedParams.length === 0 ? (
                      <tr>
                        <td colSpan={14} style={{ padding: 20, textAlign: 'center', color: '#666' }}>
                          Waiting for first measurement entry...
                        </td>
                      </tr>
                    ) : (
                      groupedParams.map((p, i) => {
                        const r = p.readings;
                        const isJustUpdated = p.code === lastUpdatedCode;
                        const isAltRow = i % 2 === 1;

                        return (
                          <tr
                            key={i}
                            style={{
                              borderBottom: '1px solid #000000',
                              background: isJustUpdated
                                ? 'rgba(59, 130, 246, 0.3)'
                                : isAltRow
                                ? '#f8fafc'
                                : '#ffffff',
                              transition: 'background 0.5s ease',
                            }}
                          >
                            <td style={{ border: '1px solid #000000', padding: '3px 4px', textAlign: 'left' }}>
                              <div style={{ fontSize: 9.5, fontWeight: 'bold', color: '#000000' }}>{p.name}</div>
                              {p.lastVoiceText && (
                                <div style={{ fontSize: 7.5, color: '#7c3aed', fontStyle: 'italic', marginTop: 1 }}>
                                  🎙 "{p.lastVoiceText}"
                                </div>
                              )}
                            </td>
                            <td style={{ border: '1px solid #000000', padding: '3px 4px', fontFamily: 'Consolas, monospace', fontSize: 9 }}>
                              <div style={{ fontWeight: 'bold', color: '#000000' }}>{p.nominal} {p.unit}</div>
                              <div style={{ color: '#555555', fontSize: 8 }}>[{p.lower_limit} to {p.upper_limit}]</div>
                            </td>

                            {/* 1st Pc #1 */}
                            {(() => {
                              const v = p.trials[1];
                              const isOOC = p.trialsOOC?.[1] || isValOOC(v, p.lower_limit, p.upper_limit, p.trialStatuses?.[1]);
                              return (
                                <td style={{ border: '1px solid #000000', padding: '3px 1px', fontWeight: isOOC ? 'bold' : 'normal', fontSize: 10, fontFamily: 'Consolas, monospace', color: isOOC ? '#dc2626' : '#000000', background: isOOC ? 'rgba(254, 226, 226, 0.45)' : (isAltRow ? '#e2e8f0' : '#f1f5f9') }}>
                                  {v !== undefined ? fmt(v) : '-'}
                                </td>
                              );
                            })()}

                            {/* 1st Pc #2 */}
                            {(() => {
                              const v = p.trials[2];
                              const isOOC = p.trialsOOC?.[2] || isValOOC(v, p.lower_limit, p.upper_limit, p.trialStatuses?.[2]);
                              return (
                                <td style={{ border: '1px solid #000000', padding: '3px 1px', fontWeight: isOOC ? 'bold' : 'normal', fontSize: 10, fontFamily: 'Consolas, monospace', color: isOOC ? '#dc2626' : '#000000', background: isOOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                                  {v !== undefined ? fmt(v) : '-'}
                                </td>
                              );
                            })()}

                            {/* 1st Pc #3 */}
                            {(() => {
                              const v = p.trials[3];
                              const isOOC = p.trialsOOC?.[3] || isValOOC(v, p.lower_limit, p.upper_limit, p.trialStatuses?.[3]);
                              return (
                                <td style={{ border: '1px solid #000000', padding: '3px 1px', fontWeight: isOOC ? 'bold' : 'normal', fontSize: 10, fontFamily: 'Consolas, monospace', color: isOOC ? '#dc2626' : '#000000', background: isOOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                                  {v !== undefined ? fmt(v) : '-'}
                                </td>
                              );
                            })()}

                            {/* Hourly Slots 1..8 */}
                            {[1, 2, 3, 4, 5, 6, 7, 8].map((slot) => {
                              const v = p.hourly[slot];
                              const isOOC = p.hourlyOOC?.[slot] || isValOOC(v, p.lower_limit, p.upper_limit, p.hourlyStatuses?.[slot]);
                              return (
                                <td key={slot} style={{ border: '1px solid #000000', padding: '3px 1px', fontWeight: isOOC ? 'bold' : 'normal', fontSize: 10, fontFamily: 'Consolas, monospace', color: isOOC ? '#dc2626' : '#000000', background: isOOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                                  {v !== undefined ? fmt(v) : '-'}
                                </td>
                              );
                            })}

                            <td style={{ border: '1px solid #000000', padding: '3px 1px', fontWeight: 'bold' }}>
                              {p.hasOOC ? (
                                <span style={{ color: '#dc2626', fontWeight: 'bold', fontSize: 9 }}>OOC</span>
                              ) : (Object.keys(p.trials).length > 0 || Object.keys(p.hourly).length > 0) ? (
                                <span style={{ color: '#16a34a', fontWeight: 'bold', fontSize: 9 }}>OK</span>
                              ) : (
                                <span style={{ color: '#94a3b8', fontSize: 9 }}>-</span>
                              )}
                            </td>
                          </tr>
                        );
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  )}
</div>

{/* MACHINE INSPECTION HISTORY TABLE */}
        <div className="card">
          <div className="section-header" style={{ marginBottom: 16, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <h3 className="section-title" style={{ margin: 0 }}>
              <span className="dot" />
              Machine Inspection History ({historySessions.length})
            </h3>
            {historySessions.length > 0 && (
              <button
                className="btn btn-danger btn-sm"
                onClick={handleClearHistory}
                style={{ display: 'flex', gap: 6, alignItems: 'center', padding: '6px 12px', fontSize: 12 }}
              >
                <span>Clear History (Clean Slate)</span>
              </button>
            )}
          </div>

          {historySessions.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-text">No inspection history recorded for {machine.machine_code} yet. Clean slate active!</div>
            </div>
          ) : (
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Trial Tag</th>
                    <th>Session ID</th>
                    <th>Part Number</th>
                    <th>Operation Name</th>
                    <th>Operator</th>
                    <th>Shift</th>
                    <th>Date & Time</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {historySessions.map((s) => {
                    const opLabel = s.template_name?.trim() || 
                      (s.template_version ? `Operation ${s.template_version}` : 
                      ({ first_piece: '1st Piece Inspection', hourly: 'Hourly In-Process', final: 'Final Check', setup_approval: 'Setup Approval' }[s.inspection_type]
                        ?? s.inspection_type?.replace('_', ' ') ?? '-'));
                    return (
                      <tr key={s.session_id}>
                        <td>
                          <span className="badge badge-progress">
                            {s.inspection_type === 'hourly'
                              ? `Slot ${s.hourly_unlocked_slot || s.hourly_slot || 1}/HR`
                              : s.inspection_type === 'first_piece'
                              ? `1ST PC #${s.trial_number || 1}`
                              : s.inspection_type?.replace('_', ' ')?.toUpperCase() || '-'}
                          </span>
                        </td>
                        <td className="font-mono font-bold">
                          {s.session_id?.slice(0, 8)?.toUpperCase()}
                        </td>
                        <td className="font-mono">{s.part_number}</td>
                        <td>
                          <div style={{ fontWeight: 600, fontSize: '0.85rem', color: 'var(--text-primary)' }}>{opLabel}</div>
                          <div className="text-xs text-muted">{s.inspection_type?.replace('_', ' ')}</div>
                        </td>
                        <td>{s.operator_name || `Operator #${s.operator_id}`}</td>
                        <td>Shift {s.shift}</td>
                        <td className="text-xs text-muted">
                          {formatDateTime(s.started_at)}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', alignItems: 'center' }}>
                            <button
                              className="btn btn-ghost btn-sm"
                              onClick={() => setSelectedHistorySessionId(s.session_id)}
                            >
                              View Report Sheet
                            </button>
                            <button
                              className="btn btn-ghost btn-sm text-red"
                              onClick={() => handleDeleteSession(s.session_id)}
                              title="Delete test session"
                              style={{ color: '#ef4444', padding: '4px 8px' }}
                            >
                              Delete
                            </button>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {/* History Inspection Sheet Modal */}
      {selectedHistorySessionId && (
        <LiveSheetViewer
          sessionId={selectedHistorySessionId}
          onClose={() => setSelectedHistorySessionId(null)}
        />
      )}
    </>
  );
}
