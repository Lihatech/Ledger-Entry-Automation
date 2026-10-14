import { useState, useEffect, useRef } from 'react';
import Modal from '../common/Modal';
import Badge from '../common/Badge';
import LoadingSpinner from '../common/LoadingSpinner';
import { getSessionDetail, reviewSession } from '../../api/inspections';
import { useWebSocket } from '../../context/WebSocketContext';
import { formatDateTime, formatDate, fmt } from '../../utils/formatters';
import { useCompany } from '../../context/CompanyContext';

const PROCESS_10_SPECS = {
  'TL-01':   { no: '01', name: 'TOTAL LENGTH',           spec: '105.1 ±0.2',    method: 'DEPTH VERNIER',      sample: '5NOS/SHIFT',        critical: false },
  'OD-01':   { no: '02', name: 'O.D.',                   spec: '25.4 ±0.1',     method: 'VERNIER CALIPER',    sample: '100%',              critical: true },
  'CHA-01':  { no: '03', name: 'CHA.',                   spec: '0.5x45°',       method: 'VISUALLY',           sample: '5NOS/SHIFT',        critical: false },
  'CHM-01':  { no: '04', name: 'CHAMFER',                spec: '1x45°',         method: 'VISUALLY',           sample: 'LAYOUT INSPECTION', critical: false },
  'DIA-01':  { no: '05', name: 'DIA',                    spec: 'ø15.0 ±0.2',    method: 'PLUG GAUGE',         sample: '5NOS/SHIFT',        critical: false },
  'OD-02':   { no: '06', name: 'O.D.',                   spec: 'ø101.0 ±0.3',   method: 'VERNIER CALIPER',    sample: '5NOS/SHIFT',        critical: false },
  'GA-01':   { no: '07', name: 'GROOVE ANGLE',           spec: '40 ±1°',        method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'GR-01':   { no: '08', name: 'GROOVE RADIUS',          spec: 'R0.50 ±0.15',   method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'GR-02':   { no: '09', name: 'GROOVE RADIUS',          spec: 'R0.38 ±0.1',    method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'GD-01':   { no: '10', name: 'GROOVE DISTANCE',        spec: '3.56 ±0.05',    method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: true },
  'DIST-01': { no: '11', name: 'DISTANCE',               spec: '11.08 ±0.1',    method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'DIST-02': { no: '12', name: 'DISTANCE MIN',           spec: '3.30 MIN.',     method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'DIST-03': { no: '13', name: 'DISTANCE',               spec: '31.52',         method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'GDIA-01': { no: '14', name: 'GROOVE DIA',             spec: 'ø131.93 ±0.5',  method: 'PROFILE PROJECTOR',  sample: '1st PIECE/SHIFT',   critical: false },
  'GDB-01':  { no: '15', name: 'GROOVE DIA OVER BALL',   spec: 'ø133.42 ±0.5',  method: 'VERNIER CALIPER',    sample: '100%',              critical: true },
  'CHA-02':  { no: '16', name: 'CHA.',                   spec: '2x45°',         method: 'VISUALLY',           sample: 'LAYOUT INSPECTION', critical: false },
  'OD-03':   { no: '17', name: 'O.D.',                   spec: 'ø138.0 ±0.3',   method: 'VERNIER CALIPER',    sample: '5NOS/SHIFT',        critical: false },
  'SF-01':   { no: '18', name: 'SURFACE FINISH',         spec: 'Ra( 3.2 )',     method: 'COMPARE WITH MASTER',sample: 'LAYOUT INSPECTION', critical: false },
};

const isValOOC = (val, lower, upper, status) => {
  if (status === 'out_of_spec' || status === 'rejected' || status === 'ooc') return true;
  if (status === 'ok' || status === 'pass') return false;
  if (val === undefined || val === null || val === '') return false;
  const num = Number(val);
  if (isNaN(num)) return false;
  if (lower !== undefined && lower !== null && lower !== '' && num < Number(lower)) return true;
  if (upper !== undefined && upper !== null && upper !== '' && num > Number(upper)) return true;
  return false;
};

export default function LiveSheetViewer({ sessionId, onClose }) {
  const { companyName, companyCode } = useCompany();
  const [session, setSession]                 = useState(null);
  const [loading, setLoading]                 = useState(true);
  const [error, setError]                     = useState('');
  const [lastUpdatedCode, setLastUpdatedCode] = useState(null);
  const [approving, setApproving]             = useState(false);
  const [supervisorRemark, setSupervisorRemark] = useState('');
  const updateTimeoutRef = useRef(null);

  const ws = useWebSocket();
  const wsEvents = ws?.events ?? [];

  const fetchSession = async () => {
    try {
      const res = await getSessionDetail(sessionId);
      setSession(res.data);
    } catch (err) {
      setError('Failed to load session details.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchSession();
  }, [sessionId]);

  const handleApproveSetup = async () => {
    setApproving(true);
    try {
      await reviewSession(sessionId, 'approve', supervisorRemark);
      alert('✓ Process No. 10 1st Piece Inspection Checked & Approved! Hourly Measurements Unlocked for Operator.');
      await fetchSession();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to approve 1st Piece inspection.');
    } finally {
      setApproving(false);
    }
  };

  const handleRejectSetup = async () => {
    setApproving(true);
    try {
      await reviewSession(sessionId, 'reject', supervisorRemark || 'Out-of-spec dimensions detected in 1ST PC #1. Corrective retrial 1ST PC #2 requested.');
      alert('Process No. 10 Flagged for 1ST PC #2 Correction! A targeted re-entry request has been sent to the inspector/operator terminal.');
      await fetchSession();
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to flag session for retrial.');
    } finally {
      setApproving(false);
    }
  };

  useEffect(() => {
    if (!wsEvents.length || !session) return;
    const latest = wsEvents[0];
    
    const sameReportGroup = Boolean(
      latest.report_group_id &&
      session.report_group_id &&
      latest.report_group_id === session.report_group_id
    );

    if (
      latest.event === 'measurement_recorded' &&
      (latest.session_id === sessionId || latest.parent_session_id === sessionId || sameReportGroup)
    ) {
      setSession((prev) => {
        if (!prev) return prev;
        const updatedMeasurements = [...(prev.measurements || [])];
        // WebSocket events carry the canonical owner/session classification.
        // Do not infer hourly data from trial_number: hourly sessions use
        // trial_number=0 and belong to hourly_slot 1..N.
        const inspType = latest.inspection_type === 'hourly' ? 'hourly' : 'first_piece';
        const trialNo = inspType === 'first_piece' ? (latest.trial_number || 1) : 0;
        const slot = inspType === 'hourly' ? (latest.hourly_slot || 1) : 0;

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

        return {
          ...prev,
          measurements: updatedMeasurements,
          progress: latest.progress ?? prev.progress,
        };
      });

      setLastUpdatedCode(latest.parameter_code);
      if (updateTimeoutRef.current) clearTimeout(updateTimeoutRef.current);
      updateTimeoutRef.current = setTimeout(() => {
        setLastUpdatedCode(null);
      }, 3000);
    }

    if (latest.event === 'supervisor_action' && latest.session_id === sessionId) {
      fetchSession();
    }
  }, [wsEvents[0]?._receivedAt, sessionId]);

  if (loading) {
    return (
      <Modal title="Process No. 10 : Inspection Sheet (Form F02)" onClose={onClose}>
        <div style={{ padding: 40 }}>
          <LoadingSpinner message="Loading Process No. 10 live sheet..." />
        </div>
      </Modal>
    );
  }

  if (error || !session) {
    return (
      <Modal title="Error Loading Sheet" onClose={onClose}>
        <div className="card text-center" style={{ padding: 30 }}>
          <p>{error || 'Session not found.'}</p>
          <button className="btn btn-ghost mt-16" onClick={onClose}>Close</button>
        </div>
      </Modal>
    );
  }

  const measurements = session.measurements || [];
  const isApproved = session.is_setup_approved || session.status === 'approved';
  const isRejected = session.status === 'rejected';

  const productParams = session.parameter_summary || session.parameters || session.template_parameters || [];
  const processParams = session.process_parameter_summary || session.process_parameters || [];
  const masterParams = [...processParams, ...productParams];
  const paramMap = {};

  // 1. Initialize with Master Database Parameters
  masterParams.forEach((p, idx) => {
    const code = p.parameter_code || `P${idx + 1}`;
    const nom = p.nominal ?? p.nominal_value ?? 0;
    const ll = p.lower_limit;
    const ul = p.upper_limit;
    const unit = p.unit || 'mm';

    let specStr = `${nom} ${unit}`;
    if (ll !== undefined && ul !== undefined && ll !== null && ul !== null) {
      specStr = `${nom} ${unit} [${ll} to ${ul}]`;
    }

    paramMap[code] = {
      code: code,
      no: String(idx + 1).padStart(2, '0'),
      name: p.parameter_name || code,
      nominal: nom,
      lower_limit: ll,
      upper_limit: ul,
      unit: unit,
      spec: p.specification || specStr,
      method: p.measurement_technique || p.evaluation_technique || p.gauge_used || p.method || 'VERNIER CALIPER',
      sample: p.sample_size || p.sample_frequency || p.sample || '5NOS/SHIFT',
      critical: !!p.is_critical,
      trials: {},
      hourly: {},
      trialsOOC: {},
      hourlyOOC: {},
      lastVoiceText: null,
      lastMethod: null,
    };
  });

  // 2. Populate actual Inspector & Operator measurements
  measurements.forEach((m) => {
    const code = m.parameter_code;
    if (!code) return;
    const trialNo = m.trial_number || 1;
    const isHourlyMeas = m.inspection_type === 'hourly';

    if (!paramMap[code]) {
      const nom = m.nominal ?? 0;
      const ll = m.lower_limit;
      const ul = m.upper_limit;
      const unit = m.unit || 'mm';
      let specStr = `${nom} ${unit}`;
      if (ll !== undefined && ul !== undefined && ll !== null && ul !== null) {
        specStr = `${nom} ${unit} [${ll} to ${ul}]`;
      }

      paramMap[code] = {
        code: code,
        no: String(Object.keys(paramMap).length + 1).padStart(2, '0'),
        name: m.parameter_name || code,
        nominal: nom,
        lower_limit: ll,
        upper_limit: ul,
        unit: unit,
        spec: m.specification || specStr,
        method: m.evaluation_technique || m.method || 'VERNIER CALIPER',
        sample: m.sample_frequency || '5NOS/SHIFT',
        critical: !!m.is_critical,
        trials: {},
        hourly: {},
        trialStatuses: {},
        hourlyStatuses: {},
        trialsOOC: {},
        hourlyOOC: {},
        lastVoiceText: m.voice_raw_text,
        lastMethod: m.method,
      };
    } else {
      if (m.lower_limit !== undefined && m.lower_limit !== null) paramMap[code].lower_limit = m.lower_limit;
      if (m.upper_limit !== undefined && m.upper_limit !== null) paramMap[code].upper_limit = m.upper_limit;
    }

    const isOOC = (m.status === 'ok' || m.status === 'pass')
      ? false
      : ((m.status === 'out_of_spec' || m.status === 'rejected' || m.status === 'ooc') ||
         isValOOC(m.measured_value, m.lower_limit ?? paramMap[code].lower_limit, m.upper_limit ?? paramMap[code].upper_limit, m.status));

    if (isHourlyMeas) {
      const slot = m.hourly_slot || 1;
      paramMap[code].hourly[slot] = m.measured_value;
      paramMap[code].hourlyStatuses = paramMap[code].hourlyStatuses || {};
      paramMap[code].hourlyStatuses[slot] = m.status;
      paramMap[code].hourlyOOC[slot] = isOOC;
    } else {
      const tNo = (trialNo >= 1 && trialNo <= 3) ? trialNo : 1;
      paramMap[code].trials[tNo] = m.measured_value;
      paramMap[code].trialStatuses = paramMap[code].trialStatuses || {};
      paramMap[code].trialStatuses[tNo] = m.status;
      paramMap[code].trialsOOC[tNo] = isOOC;
    }

    if (m.voice_raw_text) {
      paramMap[code].lastVoiceText = m.voice_raw_text;
    }
  });

  const groupedParams = Object.values(paramMap);

  return (
    <Modal
      size="xl"
      title={`PROCESS NO. 10 LIVE INSPECTION SHEET : Machine ${session.machine_code}`}
      onClose={onClose}
      footer={
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', width: '100%' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--text-muted)' }}>
            <span className="ws-dot" />
            <span>Process No. 10 · Live Stream Active</span>
          </div>
          <button className="btn btn-ghost" onClick={onClose}>Close Live Sheet</button>
        </div>
      }
    >
      {/* Live Header Notification */}
      <div
        style={{
          background: 'rgba(59, 130, 246, 0.12)',
          border: '1px solid rgba(59, 130, 246, 0.3)',
          borderRadius: 'var(--radius-md)',
          padding: '10px 14px',
          marginBottom: 12,
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div>
            <strong style={{ fontSize: 13, color: 'var(--text-primary)' }}>
              Process No. 10 : 1st Side Finish Turning (Operator: {session.operator_name || `Operator #${session.operator_id}`})
            </strong>
            <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
              Part: <strong>{session.part_number}</strong> (POLY V PULLEY) · Shift {session.shift}
            </div>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <Badge type={session.status} />
          <div style={{ fontSize: 11, color: 'var(--text-muted)', marginTop: 4 }}>
            Progress: {session.progress ?? 0}%
          </div>
        </div>
      </div>

      {/* READ-ONLY MONITORING BANNER (NO SUPERVISOR APPROVAL REQUIRED) */}
      <div
        style={{
          background: 'rgba(59, 130, 246, 0.12)',
          border: '1px solid rgba(59, 130, 246, 0.35)',
          borderRadius: 'var(--radius-md)',
          padding: '12px 16px',
          marginBottom: 16,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, color: 'var(--accent-blue)' }}>
          <div>
            <strong style={{ fontSize: 14 }}>Process No. 10 : Real-Time Live Inspection Sheet</strong>
            <div style={{ fontSize: 12, opacity: 0.9 }}>
              Quality Inspectors finalize First Piece inspections independently. Supervisors monitor live readings and download official PDF reports.
            </div>
          </div>
        </div>
      </div>

      {/* MMPL Form F02 Inspection Report Table */}
      <div
        className="official-report-sheet"
        style={{
          background: '#ffffff',
          color: '#000000',
          padding: '12px 16px',
          fontFamily: "Arial, 'Helvetica Neue', sans-serif",
          fontSize: 10,
          borderRadius: 8,
          boxShadow: '0 4px 20px rgba(0,0,0,0.5)',
          overflowX: 'auto',
        }}
      >
        {/* Header Title Block */}
        <table style={{ width: '100%', borderCollapse: 'collapse', border: '1.5px solid #000000', marginBottom: 8 }}>
          <tbody>
            <tr style={{ borderBottom: '1.5px solid #000000' }}>
              <td style={{ width: '12%', padding: '6px 4px', borderRight: '1.5px solid #000000', textAlign: 'center', background: '#000000', color: '#ffffff' }}>
                <div style={{ fontSize: 16, fontWeight: 'bold', letterSpacing: 1 }}>{companyCode}</div>
              </td>
              <td style={{ width: '73%', padding: '4px 10px', borderRight: '1.5px solid #000000', textAlign: 'center' }}>
                <div style={{ fontSize: 14, fontWeight: 'bold', letterSpacing: '0.5px', color: '#000000' }}>{companyName.toUpperCase()}</div>
                <div style={{ fontSize: 11, fontWeight: 'bold', marginTop: 1, color: '#000000' }}>1ST PIECE CUM IN-PROCESS INSPECTION REPORT : PROCESS NO. 10</div>
              </td>
              <td style={{ width: '15%', padding: '4px 6px', textAlign: 'right', fontSize: 8.5, color: '#000000' }}>
                <div><strong>DOC REF:</strong> {companyCode}/PRD/F02</div>
                <div><strong>REV:</strong> 02 (15.8.2013)</div>
                <div style={{ marginTop: 1, fontWeight: 'bold', color: isApproved ? '#16a34a' : isRejected ? '#dc2626' : '#d97706' }}>
                  {isApproved ? 'FINALIZED & PASSED' : isRejected ? 'FINALIZED & FAILED' : 'IN PROGRESS'}
                </div>
              </td>
            </tr>


            {/* Metadata Row */}
            <tr style={{ background: '#f8fafc' }}>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555' }}>PROCESS NO:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000', fontFamily: 'Consolas, monospace' }}>10.</strong>
              </td>
              <td style={{ padding: '3px 6px', borderRight: '1px solid #000000' }}>
                <span style={{ fontSize: 8, color: '#555555' }}>PART NO:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000', fontFamily: 'Consolas, monospace' }}>{session.part_number} (POLY V PULLEY)</strong>
              </td>
              <td style={{ padding: '3px 6px' }}>
                <span style={{ fontSize: 8, color: '#555555' }}>OPERATOR:</span>{' '}
                <strong style={{ fontSize: 10, color: '#000000' }}>{session.operator_name || `Operator #${session.operator_id}`}</strong>
              </td>
            </tr>
          </tbody>
        </table>

        {/* Official Process Control Plan Table (18 Characteristics) */}
        <table style={{ width: '100%', borderCollapse: 'collapse', border: '1.5px solid #000000', textAlign: 'center', fontSize: 9 }}>
          <thead>
            <tr style={{ background: '#e2e8f0', borderBottom: '1.5px solid #000000', color: '#000000' }}>
              <th style={{ border: '1px solid #000000', padding: '3px 2px', width: '3%' }}>P.No</th>
              <th style={{ border: '1px solid #000000', padding: '3px 2px', width: '3%' }}>No</th>
              <th style={{ border: '1px solid #000000', padding: '3px 4px', width: '12%', textAlign: 'left' }}>Product Characteristic</th>
              <th style={{ border: '1px solid #000000', padding: '3px 2px', width: '3%' }}>Class</th>
              <th style={{ border: '1px solid #000000', padding: '3px 4px', width: '11%' }}>Specification</th>
              <th style={{ border: '1px solid #000000', padding: '3px 4px', width: '11%' }}>Evaluation Technique</th>
              <th style={{ border: '1px solid #000000', padding: '3px 2px', width: '9%' }}>Sample Freq</th>
              <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', background: '#cbd5e1' }}>1st #1</th>
              <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', background: '#cbd5e1' }}>1st #2</th>
              <th style={{ border: '1px solid #000000', padding: '3px 1px', width: '5%', background: '#cbd5e1' }}>1st #3</th>
              {Array.from({ length: session.shift_hours || session.total_hourly_slots || 8 }, (_, i) => i + 1).map((sNum) => (
                <th key={sNum} style={{ border: '1px solid #000000', padding: '3px 1px', width: `${34 / (session.shift_hours || session.total_hourly_slots || 8)}%`, background: isApproved ? '#dcfce7' : '#f1f5f9' }}>
                  {sNum}/Hr
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {groupedParams.map((p, i) => {
              const tr1 = p.trials[1];
              const tr2 = p.trials[2];
              const tr3 = p.trials[3];
              const hr  = p.hourly;

              const tr1OOC = p.trialsOOC?.[1] || isValOOC(tr1, p.lower_limit, p.upper_limit, p.trialStatuses?.[1]);
              const tr2OOC = p.trialsOOC?.[2] || isValOOC(tr2, p.lower_limit, p.upper_limit, p.trialStatuses?.[2]);
              const tr3OOC = p.trialsOOC?.[3] || isValOOC(tr3, p.lower_limit, p.upper_limit, p.trialStatuses?.[3]);

              const isJustUpdated = p.code === lastUpdatedCode;
              const isAltRow = i % 2 === 1;
              const specMeta = {
                no: p.no || String(i + 1).padStart(2, '0'),
                name: p.name || p.code,
                spec: p.spec || `${p.nominal} ${p.unit}`,
                method: p.method || p.lastMethod || 'VERNIER CALIPER',
                sample: p.sample || '5NOS/SHIFT',
                critical: !!p.critical,
              };

              return (
                <tr
                  key={i}
                  style={{
                    borderBottom: '1px solid #000000',
                    background: isJustUpdated
                      ? 'rgba(59, 130, 246, 0.25)'
                      : isAltRow
                      ? '#f8fafc'
                      : '#ffffff',
                    transition: 'background 0.5s ease',
                  }}
                >
                  {/* Process No */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold' }}>10.</td>
                  
                  {/* Characteristic No */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: 'bold', fontFamily: 'Consolas, monospace' }}>
                    {specMeta.no}
                  </td>

                  {/* Characteristic Name */}
                  <td style={{ border: '1px solid #000000', padding: '2px 4px', textAlign: 'left' }}>
                    <div style={{ fontSize: 9, fontWeight: 'bold', color: '#000000' }}>
                      {specMeta.name}
                    </div>
                    {p.lastVoiceText && (
                      <div style={{ fontSize: 7.5, color: '#7c3aed', fontStyle: 'italic' }}>
                        Voice: "{p.lastVoiceText}"
                      </div>
                    )}
                  </td>

                  {/* Special CharClass */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px' }}>
                    {specMeta.critical ? <span style={{ color: '#dc2626', fontSize: 8, fontWeight: 'bold' }}>CRITICAL</span> : <span style={{ color: '#94a3b8' }}>-</span>}
                  </td>

                  {/* Specification */}
                  <td style={{ border: '1px solid #000000', padding: '2px 4px', fontFamily: 'Consolas, monospace', fontSize: 8.5, fontWeight: 'bold' }}>
                    {specMeta.spec}
                  </td>

                  {/* Evaluation Technique */}
                  <td style={{ border: '1px solid #000000', padding: '2px 4px', fontSize: 8, color: '#1e293b', textTransform: 'uppercase' }}>
                    {specMeta.method}
                  </td>

                  {/* Sample Size & Freq */}
                  <td style={{ border: '1px solid #000000', padding: '2px 2px', fontSize: 7.5, color: '#334155' }}>
                    {specMeta.sample}
                  </td>

                  {/* 1st #1 Trial Column : OOC values in RED */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr1OOC ? 'bold' : 'normal', fontSize: 9.5, fontFamily: 'Consolas, monospace', color: tr1OOC ? '#dc2626' : '#000000', background: tr1OOC ? 'rgba(254, 226, 226, 0.45)' : (isAltRow ? '#f8fafc' : '#ffffff') }}>
                    {tr1 !== undefined ? fmt(tr1) : '-'}
                  </td>

                  {/* 1st #2 Trial Column : OOC values in RED */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr2OOC ? 'bold' : 'normal', fontSize: 9.5, fontFamily: 'Consolas, monospace', color: tr2OOC ? '#dc2626' : '#000000', background: tr2OOC ? 'rgba(254, 226, 226, 0.45)' : (isAltRow ? '#f8fafc' : '#ffffff') }}>
                    {tr2 !== undefined ? fmt(tr2) : '-'}
                  </td>

                  {/* 1st #3 Trial Column : OOC values in RED */}
                  <td style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: tr3OOC ? 'bold' : 'normal', fontSize: 9.5, fontFamily: 'Consolas, monospace', color: tr3OOC ? '#dc2626' : '#000000', background: tr3OOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                    {tr3 !== undefined ? fmt(tr3) : '-'}
                  </td>

                  {/* Hourly Readings (1/Hr .. 8/Hr or 12/Hr) : OOC values in RED */}
                  {Array.from({ length: session.shift_hours || session.total_hourly_slots || 8 }, (_, i) => i + 1).map((slot) => {
                    const hVal = hr[slot];
                    const hOOC = p.hourlyOOC?.[slot] || isValOOC(hVal, p.lower_limit, p.upper_limit, p.hourlyStatuses?.[slot]);
                    return (
                      <td key={slot} style={{ border: '1px solid #000000', padding: '2px 1px', fontWeight: hOOC ? 'bold' : 'normal', fontSize: 9.5, fontFamily: 'Consolas, monospace', color: hOOC ? '#dc2626' : '#000000', background: hOOC ? 'rgba(254, 226, 226, 0.45)' : undefined }}>
                        {hVal !== undefined ? fmt(hVal) : '-'}
                      </td>
                    );
                  })}
                </tr>
              );
            })}
          </tbody>
        </table>

        {/* Reaction Plan Footer Banner */}
        <div style={{ marginTop: 8, padding: '4px 8px', border: '1px solid #000000', background: '#f8fafc', fontSize: 7.5, color: '#334155' }}>
          <strong>REACTION PLAN:</strong> REJECT, REWORK, SEGREGATE, INFORM SUPERVISOR OR READJUST THE PROCESS
        </div>
      </div>
    </Modal>
  );
}
