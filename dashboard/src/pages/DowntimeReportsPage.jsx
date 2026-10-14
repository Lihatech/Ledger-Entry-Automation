import React, { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import api from '../api/axios';
import {
  Calendar,
  RefreshCw,
  FileSpreadsheet,
  Printer,
  CheckCircle2,
  AlertCircle,
  Clock,
  Cog,
  History,
  FileText,
  Search,
} from 'lucide-react';

export default function DowntimeReportsPage() {
  const { user } = useAuth();
  const canManageDowntime = can(user, 'production.downtime.manage');
  const [searchParams] = useSearchParams();
  const viewMode = searchParams.get('view'); // 'history' | 'full' (default: 'full')

  // Navigation Tabs: 'active' | 'history'
  const [activeTab, setActiveTab] = useState(viewMode === 'history' ? 'history' : 'active');

  const [reports, setReports] = useState([]);
  const [historyList, setHistoryList] = useState([]);
  const [machines, setMachines] = useState([]);
  const [loading, setLoading] = useState(true);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [successMsg, setSuccessMsg] = useState(null);

  // Filters for active view
  const [dateFilter, setDateFilter] = useState('');
  const [shiftFilter, setShiftFilter] = useState('');
  const [machineFilter, setMachineFilter] = useState('');

  // Search filter for history tab
  const [historySearch, setHistorySearch] = useState('');

  // Keep the optional history deep-link, while using the same screen for every role.
  useEffect(() => {
    setActiveTab(viewMode === 'history' ? 'history' : 'active');
  }, [viewMode]);

  // Load Machines metadata
  useEffect(() => {
    async function loadMachines() {
      try {
        const res = await api.get('/api/machines/').catch(() => ({ data: [] }));
        setMachines(Array.isArray(res.data) ? res.data : []);
      } catch (err) {
        console.error('Failed to load machines', err);
      }
    }
    loadMachines();
  }, []);

  // Fetch Downtime Reports matching active filters
  const fetchDowntimeReports = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const params = {};
      if (dateFilter) params.date = dateFilter;
      if (shiftFilter) params.shift = shiftFilter;
      if (machineFilter) params.machine = machineFilter;

      const res = await api.get('/api/inspections/downtime-reports/', { params });
      const data = Array.isArray(res.data) ? res.data : (res.data?.results || []);
      setReports(data);
    } catch (err) {
      console.error('Failed to fetch Downtime Reports', err);
      setError('Failed to load Downtime Reports. Please check server connection.');
    } finally {
      setLoading(false);
    }
  }, [dateFilter, shiftFilter, machineFilter]);

  // Fetch Date-Wise Downtime History
  const fetchDowntimeHistory = useCallback(async () => {
    setHistoryLoading(true);
    try {
      const res = await api.get('/api/inspections/downtime-reports/history/');
      const data = Array.isArray(res.data)
        ? res.data
        : (res.data?.history || res.data?.results || []);
      setHistoryList(data);
    } catch (err) {
      console.error('Failed to fetch downtime history', err);
      setError('Failed to load Downtime Reports history. Please check server connection.');
    } finally {
      setHistoryLoading(false);
    }
  }, []);

  useEffect(() => {
    if (activeTab === 'active') {
      fetchDowntimeReports();
    }
  }, [activeTab, fetchDowntimeReports]);

  useEffect(() => {
    if (activeTab === 'history' || viewMode === 'history') {
      fetchDowntimeHistory();
    }
  }, [activeTab, viewMode, fetchDowntimeHistory]);

  // Handle cell edit for downtime fields
  const handleCellChange = (index, field, val) => {
    setReports((prev) => {
      const updated = [...prev];
      updated[index] = {
        ...updated[index],
        [field]: val,
      };
      return updated;
    });
  };

  // Compute mathematical expected downtime
  const getExpectedTotal = (r) => {
    if (r.expected_downtime !== undefined && r.expected_downtime !== null) {
      return Number(r.expected_downtime);
    }
    const target = Number(r.target) || 0;
    const produced = Number(r.produced) || 0;
    const cycleTime = Number(r.cycle_time_mins) || 0;
    return Math.max(0, Math.round((target - produced) * cycleTime));
  };

  const getAccountedTotal = (r) => {
    return (Number(r.no_load) || 0) +
      (Number(r.no_operator) || 0) +
      (Number(r.um) || 0) +
      (Number(r.setting) || 0) +
      (Number(r.inspection_wait) || 0) +
      (Number(r.tool_change) || 0) +
      (Number(r.power_off) || 0) +
      (Number(r.rework) || 0) +
      (Number(r.tool_problem) || 0);
  };
  const getRowTotal = getAccountedTotal;

  const getAutoRemark = (r) => {
    const expected = getExpectedTotal(r);
    const accounted = getAccountedTotal(r);
    if (expected === accounted) return "All OK";
    const diff = accounted - expected;
    return diff > 0 ? `Excess ${diff} mins` : `Missing ${Math.abs(diff)} mins`;
  };

  // SUBMIT & Save Date-Wise Downtime Report
  const handleSubmitDowntimeReport = async () => {
    if (!canManageDowntime) {
      setError('You have view access only. Manage access is required to submit downtime reports.');
      return;
    }
    if (reports.length === 0) {
      setError('No downtime entries available to submit.');
      return;
    }
    const downtimeFields = ['no_load', 'no_operator', 'um', 'setting', 'inspection_wait', 'tool_change', 'power_off', 'rework', 'tool_problem'];
    const invalidRow = reports.findIndex((r) => downtimeFields.some((field) => {
      const value = Number(r[field] ?? 0);
      return !Number.isInteger(value) || value < 0;
    }));
    if (invalidRow !== -1) {
      setError(`Row ${invalidRow + 1}: Downtime minutes must be non-negative whole numbers.`);
      return;
    }
    setSaving(true);
    setError(null);
    setSuccessMsg(null);

    // Validation Check for mismatches
    const mismatches = [];
    reports.forEach((r, idx) => {
      const expected = getExpectedTotal(r);
      const accounted = getAccountedTotal(r);
      if (expected !== accounted) {
        mismatches.push(`Row ${idx + 1} (${r.machine_code || r.machine}): Total Down Time is ${expected} mins, but justified reasons sum to ${accounted} mins.`);
      }
    });

    if (mismatches.length > 0) {
      setSaving(false);
      alert(`Mismatch Detected:\n\n${mismatches.join('\n')}\n\nPlease adjust to match.`);
      return;
    }

    try {
      const payload = reports.map((r) => ({
        id: r.id,
        production_report_id: r.production_report_id || r.production_report,
        no_load: Number(r.no_load) || 0,
        no_operator: Number(r.no_operator) || 0,
        um: Number(r.um) || 0,
        setting: Number(r.setting) || 0,
        inspection_wait: Number(r.inspection_wait) || 0,
        tool_change: Number(r.tool_change) || 0,
        power_off: Number(r.power_off) || 0,
        rework: Number(r.rework) || 0,
        tool_problem: Number(r.tool_problem) || 0,
        expected_downtime: getExpectedTotal(r),
        total_downtime: getAccountedTotal(r),
        remarks: r.remarks || '',
        mark_completed: true,
      }));

      await api.post('/api/inspections/downtime-reports/bulk_save/', payload);

      setSuccessMsg(`Downtime Report for ${dateFilter || 'selected entries'} successfully SUBMITTED! Saved to Date-Wise History.`);
      fetchDowntimeReports();
      await fetchDowntimeHistory();

      // Auto-switch to History tab
      setActiveTab('history');
    } catch (err) {
      console.error('Failed to submit Downtime Report', err);
      setError('Failed to submit downtime report. Please verify all entries.');
    } finally {
      setSaving(false);
    }
  };

  // Export Excel (.xlsx) for specified date & shift
  const handleExportExcel = async (targetDate = dateFilter, targetShift = shiftFilter) => {
    try {
      setSaving(true);
      const params = new URLSearchParams();
      if (targetDate) params.append('date', targetDate);
      if (targetShift) params.append('shift', targetShift);
      if (machineFilter && activeTab === 'active') params.append('machine', machineFilter);

      const res = await api.get(`/api/inspections/downtime-reports/export_excel/?${params.toString()}`, {
        responseType: 'blob',
      });

      const blob = new Blob([res.data], {
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      });
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      const mcSuffix = machineFilter && machineFilter !== 'All' ? `_${machineFilter.replace(/[^a-zA-Z0-9_-]/g, '_')}` : '';
      link.setAttribute('download', `Downtime_Report_${targetDate || 'All'}_Shift_${targetShift || 'All'}${mcSuffix}.xlsx`);
      document.body.appendChild(link);
      link.click();
      link.parentNode.removeChild(link);
      window.URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Export Excel failed', err);
      setError('Failed to export Excel file. Please try again.');
    } finally {
      setSaving(false);
    }
  };

  // Export PDF for specified date & shift
  const handleExportPDF = async (targetDate = dateFilter, targetShift = shiftFilter) => {
    try {
      setSaving(true);
      const params = new URLSearchParams();
      if (targetDate) params.append('date', targetDate);
      if (targetShift) params.append('shift', targetShift);
      if (machineFilter && activeTab === 'active') params.append('machine', machineFilter);

      const res = await api.get(`/api/inspections/downtime-reports/export_pdf/?${params.toString()}`, {
        responseType: 'blob',
      });

      const blob = new Blob([res.data], { type: 'application/pdf' });
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      const mcSuffix = machineFilter && machineFilter !== 'All' ? `_${machineFilter.replace(/[^a-zA-Z0-9_-]/g, '_')}` : '';
      link.setAttribute('download', `Downtime_Report_${targetDate || 'All'}_Shift_${targetShift || 'All'}${mcSuffix}.pdf`);
      document.body.appendChild(link);
      link.click();
      link.parentNode.removeChild(link);
      window.URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Export PDF failed', err);
      setError('Failed to export PDF file. Please try again.');
    } finally {
      setSaving(false);
    }
  };

  // Filtered history list
  const filteredHistory = historyList.filter((item) => {
    if (!historySearch) return true;
    const term = historySearch.toLowerCase();
    return (
      item.date.includes(term) ||
      item.shift.toLowerCase().includes(term) ||
      item.submitted_by.toLowerCase().includes(term) ||
      item.machines.some((m) => m.toLowerCase().includes(term))
    );
  });

  const allCompleted = reports.length > 0 && reports.every((r) => r.status === 'COMPLETED');

  // Shared downtime screen for both view and manage access.
  return (
    <>
      <Header
        title="Downtime Report"
        subtitle="Form QF/MF-06 : Supervisor Downtime Logging & Date-Wise Submissions"
      />

      <div className="page-content" style={{ padding: '14px 16px', backgroundColor: '#F8FAFC', minHeight: '100vh', width: '100%', overflowX: 'hidden' }}>
        <Breadcrumbs />

        {/* Navigation Tabs */}
        <div style={{ display: 'flex', gap: '8px', marginBottom: '14px', borderBottom: '2px solid #E2E8F0', paddingBottom: '6px' }}>
          <button
            onClick={() => setActiveTab('active')}
            style={{
              padding: '8px 16px',
              borderRadius: '6px',
              fontWeight: '800',
              fontSize: '12px',
              border: 'none',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              backgroundColor: activeTab === 'active' ? '#0284C7' : '#E2E8F0',
              color: activeTab === 'active' ? '#FFFFFF' : '#475569',
              transition: 'all 0.2s ease',
            }}
          >
            <FileText size={15} />
            {canManageDowntime ? 'Fill / Edit Downtime Report' : 'View Downtime Report'}
          </button>

          <button
            onClick={() => setActiveTab('history')}
            style={{
              padding: '8px 16px',
              borderRadius: '6px',
              fontWeight: '800',
              fontSize: '12px',
              border: 'none',
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              backgroundColor: activeTab === 'history' ? '#0284C7' : '#E2E8F0',
              color: activeTab === 'history' ? '#FFFFFF' : '#475569',
              transition: 'all 0.2s ease',
            }}
          >
            <History size={15} />
            Downtime Report History (Date-Wise)
            {historyList.length > 0 && (
              <span
                style={{
                  backgroundColor: activeTab === 'history' ? '#0369A1' : '#94A3B8',
                  color: '#FFFFFF',
                  fontSize: '10px',
                  fontWeight: '800',
                  padding: '2px 6px',
                  borderRadius: '10px',
                }}
              >
                {historyList.length}
              </span>
            )}
          </button>
        </div>

        {!canManageDowntime && activeTab === 'active' && (
          <div style={{ backgroundColor: '#EFF6FF', border: '1px solid #BFDBFE', color: '#1D4ED8', padding: '9px 12px', borderRadius: '8px', marginBottom: '12px', fontSize: '12px', fontWeight: '600' }}>
            View-only access: downtime values and submission are locked. Use the history tab to review submitted reports.
          </div>
        )}

        {/* Global Alert Messages */}
        {error && (
          <div style={{ backgroundColor: '#FEF2F2', border: '1px solid #FCA5A5', color: '#991B1B', padding: '10px 14px', borderRadius: '8px', marginBottom: '12px', display: 'flex', alignItems: 'center', gap: '8px', fontSize: '12px', fontWeight: '600' }}>
            <AlertCircle size={15} />
            <span>{error}</span>
          </div>
        )}

        {successMsg && (
          <div style={{ backgroundColor: '#F0FDF4', border: '1px solid #86EFAC', color: '#166534', padding: '10px 14px', borderRadius: '8px', marginBottom: '12px', display: 'flex', alignItems: 'center', gap: '8px', fontSize: '12px', fontWeight: '600' }}>
            <CheckCircle2 size={15} />
            <span>{successMsg}</span>
          </div>
        )}

        {/* ── TAB 1: FILL / EDIT DOWNTIME REPORT ────────────────────── */}
        {activeTab === 'active' && (
          <>
            {/* Header & Filter Card */}
            <div style={{ backgroundColor: '#ffffff', borderRadius: '10px', padding: '14px', border: '1px solid #E2E8F0', boxShadow: '0 1px 3px rgba(0,0,0,0.05)', marginBottom: '14px' }}>

              {/* Filter Toolbar */}
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px', alignItems: 'center', justifyContent: 'space-between' }}>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px', alignItems: 'center' }}>

                  {/* Date Filter */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px', backgroundColor: '#F8FAFC', padding: '4px 8px', borderRadius: '6px', border: '1px solid #CBD5E1' }}>
                    <Calendar size={14} color="#475569" />
                    <span style={{ fontSize: '11px', fontWeight: '700', color: '#475569' }}>Date:</span>
                    <input
                      type="date"
                      value={dateFilter}
                      onChange={(e) => setDateFilter(e.target.value)}
                      style={{ border: 'none', background: 'transparent', outline: 'none', fontSize: '11px', fontWeight: '600', color: '#0F172A' }}
                    />
                  </div>

                  {/* Shift Filter */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px', backgroundColor: '#F8FAFC', padding: '4px 8px', borderRadius: '6px', border: '1px solid #CBD5E1' }}>
                    <Clock size={14} color="#475569" />
                    <span style={{ fontSize: '11px', fontWeight: '700', color: '#475569' }}>Shift:</span>
                    <select
                      value={shiftFilter}
                      onChange={(e) => setShiftFilter(e.target.value)}
                      style={{ border: 'none', background: 'transparent', outline: 'none', fontSize: '11px', fontWeight: '600', color: '#0F172A', cursor: 'pointer' }}
                    >
                      <option value="">All Shifts</option>
                      <option value="A">Shift A</option>
                      <option value="B">Shift B</option>
                      <option value="C">Shift C</option>
                      <option value="General">General Shift</option>
                    </select>
                  </div>

                  {/* Machine Filter */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px', backgroundColor: '#F8FAFC', padding: '4px 8px', borderRadius: '6px', border: '1px solid #CBD5E1' }}>
                    <Cog size={14} color="#475569" />
                    <select
                      value={machineFilter}
                      onChange={(e) => setMachineFilter(e.target.value)}
                      style={{ border: 'none', background: 'transparent', outline: 'none', fontSize: '11px', fontWeight: '600', color: '#0F172A', cursor: 'pointer' }}
                    >
                      <option value="">All Machines</option>
                      {machines.map((m) => (
                        <option key={m.id} value={m.id}>{m.machine_code} ({m.name})</option>
                      ))}
                    </select>
                  </div>

                  {/* Refresh Button */}
                  <button
                    onClick={fetchDowntimeReports}
                    className="btn btn-ghost"
                    style={{ padding: '4px 8px', borderRadius: '6px', display: 'flex', alignItems: 'center', gap: '4px', fontSize: '11px', fontWeight: '600', color: '#475569' }}
                  >
                    <RefreshCw size={13} className={loading ? 'spin' : ''} />
                    Refresh
                  </button>
                </div>

                {/* Main Action Buttons */}
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                  <button
                    onClick={() => handleExportExcel()}
                    className="btn btn-outline"
                    style={{ padding: '6px 10px', borderRadius: '6px', fontSize: '11px', fontWeight: '700', display: 'flex', alignItems: 'center', gap: '4px', backgroundColor: '#F0FDF4', color: '#166534', borderColor: '#86EFAC', cursor: 'pointer' }}
                  >
                    <FileSpreadsheet size={14} />
                    Export Excel (.xlsx)
                  </button>

                  <button
                    onClick={() => handleExportPDF()}
                    className="btn btn-outline"
                    style={{ padding: '6px 10px', borderRadius: '6px', fontSize: '11px', fontWeight: '700', display: 'flex', alignItems: 'center', gap: '4px', backgroundColor: '#FEF2F2', color: '#991B1B', borderColor: '#FECACA', cursor: 'pointer' }}
                  >
                    <Printer size={14} />
                    Export PDF
                  </button>
                </div>
              </div>
            </div>

            {/* MAIN DOWNTIME TABLE */}
            <div style={{ backgroundColor: '#ffffff', borderRadius: '10px', border: '1px solid #E2E8F0', boxShadow: '0 1px 3px rgba(0,0,0,0.05)', width: '100%', overflow: 'hidden' }}>

              {loading ? (
                <div style={{ padding: '40px', textAlign: 'center', color: '#64748B' }}>
                  <RefreshCw size={22} className="spin" style={{ marginBottom: '8px' }} />
                  <div style={{ fontSize: '12px', fontWeight: '600' }}>Loading submitted Daily Production Reports...</div>
                </div>
              ) : reports.length === 0 ? (
                <div style={{ padding: '40px', textAlign: 'center', color: '#64748B' }}>
                  <AlertCircle size={24} color="#94A3B8" style={{ marginBottom: '8px' }} />
                  <h3 style={{ fontSize: '14px', fontWeight: '700', color: '#334155', marginBottom: '4px' }}>No Submitted Production Reports Found</h3>
                  <p style={{ fontSize: '11px', color: '#64748B' }}>
                    There are no submitted Daily Production Reports matching the selected filters.
                  </p>
                </div>
              ) : (
                <div style={{ overflowX: 'auto', width: '100%' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px', textAlign: 'center', border: '1px solid #CBD5E1', tableLayout: 'auto' }}>

                    {/* EXCEL MERGED HEADER STRUCTURE */}
                    <thead style={{ backgroundColor: '#B0E0E6', color: '#0F172A', fontWeight: '700' }}>
                      <tr>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '28px' }}>SR. NO.</th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '58px' }}>MACHINE NO.</th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '85px' }}>OPERATOR NAME</th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '42px' }}>TARGET</th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '42px' }}>PRODUCED</th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '58px' }}>ACCEPTED / ACTUAL</th>

                        <th colSpan={3} style={{ padding: '4px 2px', border: '1px solid #94A3B8', backgroundColor: '#93C5FD', color: '#1E3A8A', fontSize: '10px' }}>
                          REJECTION SUMMARY
                        </th>

                        <th colSpan={9} style={{ padding: '4px 2px', border: '1px solid #94A3B8', backgroundColor: '#7DD3FC', color: '#0C4A6E', fontSize: '10px' }}>
                          DOWN TIME IN MINUTES
                        </th>

                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '65px', backgroundColor: '#E0F2FE', color: '#0369A1' }}>
                          TOTAL<br />DOWN TIME
                        </th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '80px' }}>
                          REMARKS
                        </th>
                        <th rowSpan={2} style={{ padding: '5px 2px', border: '1px solid #94A3B8', width: '75px' }}>
                          STATUS
                        </th>
                      </tr>

                      <tr>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '10px', backgroundColor: '#BFDBFE', width: '25px' }}>CR</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '10px', backgroundColor: '#BFDBFE', width: '25px' }}>MR</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '10px', backgroundColor: '#BFDBFE', width: '25px' }}>RW</th>

                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>NO LOAD</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>NO OPERATOR</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '30px' }}>U/M</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>SETTING</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>INSP. WAIT</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>TOOL CHANGE</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '28px' }}>P/O</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '28px' }}>R/W</th>
                        <th style={{ padding: '4px 1px', border: '1px solid #94A3B8', fontSize: '9.5px', backgroundColor: '#BAE6FD', width: '34px' }}>TOOL PROB</th>
                      </tr>
                    </thead>

                    {/* TABLE BODY */}
                    <tbody>
                      {reports.map((r, idx) => {
                        const rowTotal = getRowTotal(r);
                        const isSubmitted = r.status === 'COMPLETED';

                        const inputStyle = {
                          ...cellInputStyle,
                          backgroundColor: !canManageDowntime ? '#F1F5F9' : '#FFFFFF',
                          color: !canManageDowntime ? '#475569' : '#0F172A',
                          cursor: !canManageDowntime ? 'not-allowed' : 'text',
                          border: !canManageDowntime ? '1px solid #E2E8F0' : '1px solid #CBD5E1',
                        };

                        return (
                          <tr key={r.id || idx} style={{ backgroundColor: idx % 2 === 0 ? '#FFFFFF' : '#F8FAFC' }}>

                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '700', color: '#475569' }}>
                              {idx + 1}
                            </td>
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '800', color: '#0F172A' }}>
                              <div>{r.machine_code || r.machine}</div>
                              {Number(r.cycle_time_mins) > 0 && (
                                <div style={{ fontSize: '10px', color: '#64748B', fontWeight: '600', marginTop: '1px', letterSpacing: '0.2px' }}>
                                  {Number(r.cycle_time_mins)} min
                                </div>
                              )}
                            </td>
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '600', color: '#1E293B' }}>
                              {r.operator_name || r.operator}
                            </td>
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '800', color: '#0F172A' }} title="Target auto-calculated from available shift time and cycle time">
                              {r.target}
                            </td>
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '800', color: '#0F172A' }} title="Produced units submitted by operator">
                              {r.produced}
                            </td>
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1', backgroundColor: '#F1F5F9', fontWeight: '700', color: '#15803D' }}>
                              {r.accepted_actual}
                            </td>
                            <td style={{ padding: '4px 1px', border: '1px solid #CBD5E1', backgroundColor: '#F8FAFC', color: '#B91C1C' }}>
                              {r.cr || 0}
                            </td>
                            <td style={{ padding: '4px 1px', border: '1px solid #CBD5E1', backgroundColor: '#F8FAFC', color: '#B91C1C' }}>
                              {r.mr || 0}
                            </td>
                            <td style={{ padding: '4px 1px', border: '1px solid #CBD5E1', backgroundColor: '#F8FAFC', color: '#C2410C' }}>
                              {r.rw || 0}
                            </td>

                            {/* View users are read-only; Manage users can correct submitted rows. */}
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.no_load ?? 0} onChange={(e) => handleCellChange(idx, 'no_load', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.no_operator ?? 0} onChange={(e) => handleCellChange(idx, 'no_operator', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.um ?? 0} onChange={(e) => handleCellChange(idx, 'um', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.setting ?? 0} onChange={(e) => handleCellChange(idx, 'setting', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.inspection_wait ?? 0} onChange={(e) => handleCellChange(idx, 'inspection_wait', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.tool_change ?? 0} onChange={(e) => handleCellChange(idx, 'tool_change', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.power_off ?? 0} onChange={(e) => handleCellChange(idx, 'power_off', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.rework ?? 0} onChange={(e) => handleCellChange(idx, 'rework', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <input type="number" min="0" value={r.tool_problem ?? 0} onChange={(e) => handleCellChange(idx, 'tool_problem', e.target.value)} disabled={!canManageDowntime} style={inputStyle} />
                            </td>

                            {/* TOTAL DOWN TIME */}
                            <td
                              style={{ padding: '2px 1px', border: '1px solid #CBD5E1', backgroundColor: getExpectedTotal(r) === getAccountedTotal(r) ? '#DCFCE7' : '#FEE2E2' }}
                              title={`Total Down Time = (Target ${r.target || 0} - Produced ${r.produced || 0}) * ${r.cycle_time_mins || 0}m = ${getExpectedTotal(r)} mins`}
                            >
                              <div style={{ textAlign: 'center', fontWeight: '800', color: getExpectedTotal(r) === getAccountedTotal(r) ? '#166534' : '#991B1B', fontSize: '12px' }}>
                                {getExpectedTotal(r)} m
                              </div>
                            </td>

                            {/* REMARKS */}
                            <td style={{ padding: '2px 1px', border: '1px solid #CBD5E1' }}>
                              <div style={{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
                                <span style={{ fontSize: '9px', fontWeight: 'bold', color: getExpectedTotal(r) === getAccountedTotal(r) ? '#166534' : '#991B1B', padding: '0 4px' }}>
                                  {getAutoRemark(r)}
                                </span>
                                <input
                                  type="text"
                                  value={r.remarks || ''}
                                  onChange={(e) => handleCellChange(idx, 'remarks', e.target.value)}
                                  placeholder="Justify diff..."
                                  disabled={!canManageDowntime}
                                  style={{ ...inputStyle, width: '75px', textAlign: 'left', padding: '2px 4px' }}
                                />
                              </div>
                            </td>

                            {/* STATUS BADGE */}
                            <td style={{ padding: '4px 2px', border: '1px solid #CBD5E1' }}>
                              <span
                                style={{
                                  padding: '3px 8px',
                                  borderRadius: '4px',
                                  fontSize: '10px',
                                  fontWeight: '800',
                                  backgroundColor: isSubmitted ? '#F0FDF4' : '#FEF3C7',
                                  color: isSubmitted ? '#166534' : '#92400E',
                                  border: isSubmitted ? '1px solid #86EFAC' : '1px solid #FDE68A',
                                  display: 'inline-flex',
                                  alignItems: 'center',
                                  gap: '3px',
                                }}
                              >
                                {isSubmitted ? <CheckCircle2 size={11} /> : <Clock size={11} />}
                                {isSubmitted ? 'Submitted' : 'Pending'}
                              </span>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>

            {/* Bottom Submit Action Bar */}
            {canManageDowntime && reports.length > 0 && (
              <div style={{ marginTop: '12px', display: 'flex', justifyContent: 'flex-end', alignItems: 'center' }}>
                <button
                  onClick={handleSubmitDowntimeReport}
                  disabled={saving}
                  style={{
                    padding: '10px 24px',
                    borderRadius: '6px',
                    fontSize: '13px',
                    fontWeight: '900',
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    backgroundColor: saving ? '#64748B' : '#16A34A',
                    color: '#FFFFFF',
                    border: 'none',
                    cursor: saving ? 'not-allowed' : 'pointer',
                    boxShadow: saving ? 'none' : '0 3px 8px rgba(22, 163, 74, 0.3)',
                  }}
                >
                  <CheckCircle2 size={16} />
                  {saving ? 'Saving Report...' : (allCompleted ? 'SAVE DOWNTIME CHANGES' : 'SUBMIT DOWNTIME REPORT')}
                </button>
              </div>
            )}
          </>
        )}

        {/* ── TAB 2: DOWNTIME REPORT HISTORY (DATE-WISE) ────────────────────── */}
        {activeTab === 'history' && (
          <div style={{ backgroundColor: '#ffffff', borderRadius: '10px', padding: '16px', border: '1px solid #E2E8F0', boxShadow: '0 1px 3px rgba(0,0,0,0.05)' }}>

            {/* History Toolbar */}
            <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: 'space-between', alignItems: 'center', gap: '12px', marginBottom: '16px' }}>
              <div>
                <h3 style={{ fontSize: '15px', fontWeight: '800', color: '#0F172A', margin: 0 }}>
                  Date-Wise Submitted Downtime Reports History
                </h3>
                <p style={{ fontSize: '11px', color: '#64748B', margin: '2px 0 0 0' }}>
                  Browse, review, and download past submitted Downtime Reports grouped by Date & Shift
                </p>
              </div>

              <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '6px', backgroundColor: '#F8FAFC', padding: '6px 12px', borderRadius: '8px', border: '1px solid #CBD5E1' }}>
                  <Search size={15} color="#475569" />
                  <input
                    type="text"
                    placeholder="Search by date, shift, supervisor..."
                    value={historySearch}
                    onChange={(e) => setHistorySearch(e.target.value)}
                    style={{ border: 'none', background: 'transparent', outline: 'none', fontSize: '12px', color: '#0F172A', width: '220px' }}
                  />
                </div>

                <button
                  onClick={fetchDowntimeHistory}
                  className="btn btn-ghost"
                  style={{ padding: '6px 10px', borderRadius: '6px', display: 'flex', alignItems: 'center', gap: '4px', fontSize: '11px', fontWeight: '600', color: '#475569' }}
                >
                  <RefreshCw size={13} className={historyLoading ? 'spin' : ''} />
                  Refresh History
                </button>
              </div>
            </div>

            {/* History Table */}
            {historyLoading ? (
              <div style={{ padding: '30px', textAlign: 'center', color: '#64748B' }}>
                <RefreshCw size={22} className="spin" style={{ marginBottom: '8px' }} />
                <div style={{ fontSize: '12px', fontWeight: '600' }}>Loading Downtime History...</div>
              </div>
            ) : filteredHistory.length === 0 ? (
              <div style={{ padding: '30px', textAlign: 'center', color: '#64748B' }}>
                <AlertCircle size={24} color="#94A3B8" style={{ marginBottom: '8px' }} />
                <h3 style={{ fontSize: '14px', fontWeight: '700', color: '#334155' }}>No Historical Reports Found</h3>
                <p style={{ fontSize: '11px', color: '#64748B' }}>
                  No submitted downtime reports match your search criteria.
                </p>
              </div>
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '12px', border: '1px solid #E2E8F0' }}>
                  <thead>
                    <tr style={{ backgroundColor: '#F1F5F9', color: '#334155', fontWeight: '800', textAlign: 'left' }}>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Date</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Shift</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Machines Included</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Total Breakdown Time</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Submitted By</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1' }}>Status</th>
                      <th style={{ padding: '10px 12px', borderBottom: '2px solid #CBD5E1', textAlign: 'center' }}>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredHistory.map((item, idx) => (
                      <tr key={item.key || idx} style={{ borderBottom: '1px solid #E2E8F0', backgroundColor: idx % 2 === 0 ? '#FFFFFF' : '#F8FAFC' }}>

                        {/* DATE */}
                        <td style={{ padding: '10px 12px', fontWeight: '800', color: '#0F172A' }}>
                          {item.date}
                        </td>

                        {/* SHIFT */}
                        <td style={{ padding: '10px 12px', fontWeight: '700', color: '#0284C7' }}>
                          {item.shift === 'General' ? 'General Shift' : `Shift ${item.shift}`}
                        </td>

                        {/* MACHINES INCLUDED */}
                        <td style={{ padding: '10px 12px', color: '#334155' }}>
                          <span style={{ fontWeight: '700', color: '#0F172A' }}>{item.count} Machines: </span>
                          <span style={{ fontSize: '11px', color: '#64748B' }}>{item.machines.join(', ')}</span>
                        </td>

                        {/* TOTAL DOWNTIME */}
                        <td style={{ padding: '10px 12px', fontWeight: '800', color: '#0369A1' }}>
                          {item.total_downtime} Minutes
                        </td>

                        {/* SUBMITTED BY */}
                        <td style={{ padding: '10px 12px', color: '#475569', fontWeight: '600' }}>
                          {item.submitted_by}
                        </td>

                        {/* STATUS */}
                        <td style={{ padding: '10px 12px' }}>
                          <span
                            style={{
                              padding: '3px 8px',
                              borderRadius: '10px',
                              fontSize: '10px',
                              fontWeight: '800',
                              backgroundColor: item.status === 'COMPLETED' ? '#F0FDF4' : '#FEF3C7',
                              color: item.status === 'COMPLETED' ? '#166534' : '#92400E',
                              border: item.status === 'COMPLETED' ? '1px solid #86EFAC' : '1px solid #FDE68A',
                              display: 'inline-flex',
                              alignItems: 'center',
                              gap: '3px',
                            }}
                          >
                            <CheckCircle2 size={11} />
                            {item.status === 'COMPLETED' ? 'Submitted' : 'Pending'}
                          </span>
                        </td>

                        {/* ACTIONS (PDF & EXCEL FORMATS ONLY) */}
                        <td style={{ padding: '10px 12px', textAlign: 'center' }}>
                          <div style={{ display: 'flex', gap: '6px', justifyContent: 'center' }}>
                            <button
                              onClick={() => handleExportExcel(item.date, item.shift)}
                              title="Export Form QF/MF-06 Excel Sheet"
                              style={{
                                padding: '5px 10px',
                                borderRadius: '5px',
                                fontSize: '11px',
                                fontWeight: '700',
                                backgroundColor: '#F0FDF4',
                                color: '#166534',
                                border: '1px solid #86EFAC',
                                cursor: 'pointer',
                                display: 'flex',
                                alignItems: 'center',
                                gap: '4px',
                              }}
                            >
                              <FileSpreadsheet size={12} />
                              Download Excel (.xlsx)
                            </button>

                            <button
                              onClick={() => handleExportPDF(item.date, item.shift)}
                              title="Export Form QF/MF-06 PDF Report"
                              style={{
                                padding: '5px 10px',
                                borderRadius: '5px',
                                fontSize: '11px',
                                fontWeight: '700',
                                backgroundColor: '#FEF2F2',
                                color: '#991B1B',
                                border: '1px solid #FECACA',
                                cursor: 'pointer',
                                display: 'flex',
                                alignItems: 'center',
                                gap: '4px',
                              }}
                            >
                              <Printer size={12} />
                              Download PDF
                            </button>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </div>
    </>
  );
}

// Compact input cell styling
const cellInputStyle = {
  width: '32px',
  padding: '2px 1px',
  textAlign: 'center',
  border: '1px solid #CBD5E1',
  borderRadius: '3px',
  fontSize: '11px',
  fontWeight: '600',
  color: '#0F172A',
  backgroundColor: '#FFFFFF',
  outline: 'none',
  fontFamily: 'inherit',
};
