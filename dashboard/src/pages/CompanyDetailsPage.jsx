import { useState, useEffect, useRef } from 'react';
import { NavLink } from 'react-router-dom';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import { useCompany } from '../context/CompanyContext';
import {
  getCompanyDetails, updateCompanyDetails, getCompanyPlants,
  uploadCompanyLogo, removeCompanyLogo, createCompanyDetails, createCompanyPlant
} from '../api/company';
import {
  Building2, AlertCircle, CheckCircle2, User, Clock, ShieldCheck, Lock, Save, Loader2,
  Upload, Trash2
} from 'lucide-react';

export default function CompanyDetailsPage() {
  const { user } = useAuth();
  const { refreshCompany } = useCompany() || {};
  const isAdmin = can(user, 'quality.machines.manage');

  const [loading, setLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState('');
  const [successMsg, setSuccessMsg] = useState('');
  const [factoryId, setFactoryId] = useState(null);

  const fileInputRef = useRef(null);
  const [isUploadingLogo, setIsUploadingLogo] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [showManualUrl, setShowManualUrl] = useState(false);

  const [company, setCompany] = useState({
    name: '',
    code: '',
    location: '',
    contact_email: '',
    phone: '',
    address: '',
    gstin: '',
    logo_url: '',
    industry_type: '',
    shift_hours: 8,
    total_shifts_per_day: 3,
    lunch_break_minutes: 30,
    tea_break_minutes: 30,
    available_working_minutes: 420,
    shift_1_start: '08:00',
    shift_2_start: '16:00',
    shift_3_start: '00:00',
    is_active: true,
  });

  const [plants, setPlants] = useState([]);
  const [newPlantName, setNewPlantName] = useState('');

  // Fetch factory and plant details on mount
  useEffect(() => {
    fetchCompanyData();
  }, []);

  const fetchCompanyData = async () => {
    setLoading(true);
    setError('');
    try {
      const [compRes, plantRes] = await Promise.all([
        getCompanyDetails().catch((err) => { console.error('getCompanyDetails failed:', err); throw err; }),
        getCompanyPlants().catch(() => null),
      ]);

      const compData = compRes?.data?.results ?? compRes?.data;
      const dataArray = Array.isArray(compData) ? compData : (compData ? [compData] : []);

      if (dataArray.length === 0) {
        // No factory record exists in the DB yet or the API failed
        setError('No factory record found. Please create a factory record first or contact your administrator.');
      } else {
        const primary = dataArray[0];
        setFactoryId(primary.id);

        const shiftHrs = primary.shift_hours || 8;
        const shiftsPerDay = primary.total_shifts_per_day || (shiftHrs === 12 ? 2 : 3);
        const lunchMins = primary.lunch_break_minutes ?? 30;
        const teaMins = primary.tea_break_minutes ?? 30;
        const grossMins = shiftHrs * 60;
        const availMins = Math.max(0, grossMins - (lunchMins + teaMins));

        setCompany({
          name: primary.name || '',
          code: primary.code || '',
          location: primary.location || '',
          contact_email: primary.contact_email || '',
          phone: primary.phone || '',
          address: primary.address || '',
          gstin: primary.gstin || '',
          logo_url: primary.logo_url || '',
          industry_type: primary.industry_type || '',
          shift_hours: shiftHrs,
          total_shifts_per_day: shiftsPerDay,
          lunch_break_minutes: lunchMins,
          tea_break_minutes: teaMins,
          available_working_minutes: availMins,
          shift_1_start: (primary.shift_1_start || '08:00:00').substring(0, 5),
          shift_2_start: (primary.shift_2_start || '16:00:00').substring(0, 5),
          shift_3_start: (primary.shift_3_start || '00:00:00').substring(0, 5),
          is_active: primary.is_active !== false,
        });
      }

      const plantData = plantRes?.data?.results ?? plantRes?.data;
      if (plantData) {
        setPlants(Array.isArray(plantData) ? plantData : []);
      }
    } catch (err) {
      console.error('Failed to load company details', err);
      setError('Failed to fetch company details. Please refresh or contact your administrator.');
    } finally {
      setLoading(false);
    }
  };

  const handleChange = (e) => {
    if (!isAdmin) return;
    const { name, value } = e.target;
    setCompany((prev) => ({
      ...prev,
      [name]: value,
    }));
  };

  const handleShiftHoursChange = (hours) => {
    if (!isAdmin) return;
    setCompany((prev) => ({
      ...prev,
      shift_hours: hours,
      total_shifts_per_day: hours === 12 ? 2 : 3,
    }));
  };

  const handleLogoFileSelect = async (file) => {
    if (!file || !isAdmin || !factoryId) return;

    const allowed = ['image/png', 'image/jpeg', 'image/jpg', 'image/svg+xml', 'image/webp'];
    if (!allowed.includes(file.type) && !file.name.match(/\.(png|jpe?g|svg|webp)$/i)) {
      setError('Please upload a valid image file (PNG, JPG, SVG, or WebP).');
      return;
    }

    if (file.size > 5 * 1024 * 1024) {
      setError('Image file size must be less than 5MB.');
      return;
    }

    setIsUploadingLogo(true);
    setError('');
    try {
      const res = await uploadCompanyLogo(factoryId, file);
      if (res?.data?.logo_url) {
        setCompany((prev) => ({ ...prev, logo_url: res.data.logo_url }));
        if (refreshCompany) refreshCompany();
        setSuccessMsg('Company logo uploaded and updated across the entire system!');
        setTimeout(() => setSuccessMsg(''), 4500);
      }
    } catch (err) {
      console.error('Failed to upload logo:', err);
      setError(err.response?.data?.detail || 'Failed to upload logo file. Please try again.');
    } finally {
      setIsUploadingLogo(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const handleLogoRemove = async () => {
    if (!isAdmin || !factoryId) return;
    if (!window.confirm('Are you sure you want to remove the company logo?')) return;

    setIsUploadingLogo(true);
    setError('');
    try {
      await removeCompanyLogo(factoryId);
      setCompany((prev) => ({ ...prev, logo_url: '' }));
      if (refreshCompany) refreshCompany();
      setSuccessMsg('Company logo removed.');
      setTimeout(() => setSuccessMsg(''), 3500);
    } catch (err) {
      console.error('Failed to remove logo:', err);
      setError(err.response?.data?.detail || 'Failed to remove logo.');
    } finally {
      setIsUploadingLogo(false);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!isAdmin) return;

    setIsSaving(true);
    setError('');
    setSuccessMsg('');

    try {
      const shiftHrs = Number(company.shift_hours) || 8;
      const shiftsPerDay = shiftHrs === 12 ? 2 : 3;
      const lunchMins = Number(company.lunch_break_minutes) || 0;
      const teaMins = Number(company.tea_break_minutes) || 0;
      const grossMins = shiftHrs * 60;
      const availMins = Math.max(0, grossMins - (lunchMins + teaMins));

      const payload = {
        name: company.name,
        code: company.code,
        location: company.location,
        contact_email: company.contact_email,
        phone: company.phone,
        address: company.address,
        gstin: company.gstin,
        logo_url: company.logo_url,
        industry_type: company.industry_type,
        shift_hours: shiftHrs,
        total_shifts_per_day: shiftsPerDay,
        lunch_break_minutes: lunchMins,
        tea_break_minutes: teaMins,
        available_working_minutes: availMins,
        shift_1_start: company.shift_1_start + ':00',
        shift_2_start: company.shift_2_start + ':00',
        shift_3_start: company.shift_3_start + ':00',
      };

      let res;
      let savedFactoryId = factoryId;
      if (!factoryId) {
        // Create new factory
        res = await createCompanyDetails(payload);
        if (res?.data?.id) {
          savedFactoryId = res.data.id;
          setFactoryId(savedFactoryId);
        }
      } else {
        // Update existing factory
        res = await updateCompanyDetails(factoryId, payload);
      }

      if (res?.data) {
        const pendingPlantName = newPlantName.trim();
        if (pendingPlantName && savedFactoryId) {
          const plantRes = await createCompanyPlant({ factory: savedFactoryId, name: pendingPlantName });
          setPlants((current) => [...current, plantRes.data]);
          setNewPlantName('');
        }
        if (refreshCompany) refreshCompany();
        setSuccessMsg(pendingPlantName ? 'Company details and plant saved successfully!' : (factoryId ? 'Company & Shift details saved successfully!' : 'Company record created successfully!'));
        setTimeout(() => setSuccessMsg(''), 4500);
      }
    } catch (err) {
      console.error('Failed to update company details', err);
      const errMsg =
        err?.response?.data?.detail ||
        err?.response?.data?.message ||
        (typeof err?.response?.data === 'object'
          ? Object.entries(err.response.data).map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`).join(' | ')
          : null) ||
        'Failed to save company details. Please try again.';
      setError(errMsg);
    } finally {
      setIsSaving(false);
    }
  };

  // Calculations for live UI feedback
  const grossShiftMins = (Number(company.shift_hours) || 8) * 60;
  const totalBreakMins = (Number(company.lunch_break_minutes) || 0) + (Number(company.tea_break_minutes) || 0);
  const netAvailableWorkingMins = Math.max(0, grossShiftMins - totalBreakMins);
  const dailyTotalUptimeMins = netAvailableWorkingMins * (company.total_shifts_per_day || 3);

  const inputStyle = (isMono = false) => ({
    background: isAdmin ? 'var(--bg-elevated)' : '#f8fafc',
    color: '#0f172a',
    fontWeight: isAdmin ? 500 : 600,
    cursor: isAdmin ? 'text' : 'default',
    fontFamily: isMono ? 'monospace' : 'inherit',
    borderColor: 'var(--border)',
    transition: 'border-color 0.2s ease, box-shadow 0.2s ease',
  });

  return (
    <>
      <Header
        title="Company & Organization Details"
        subtitle="Registered office identifiers, factory profile, and operating shift standards"
      />

      <div className="page-content bg-gradient-animated">
        <div style={{ maxWidth: 980, margin: '0 auto', display: 'flex', flexDirection: 'column', gap: 24 }}>
          <Breadcrumbs items={[{ label: 'Company Details' }]} />

          {/* ── Sub-Navigation Tabs ────────────────────────────────────────────── */}
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 12,
              background: 'var(--bg-card)',
              padding: '6px 12px',
              borderRadius: 'var(--radius-lg)',
              border: '1px solid var(--border)',
              boxShadow: 'var(--shadow-sm)',
            }}
          >
            <NavLink
              to="/profile"
              style={({ isActive }) => ({
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                padding: '8px 16px',
                borderRadius: 'var(--radius-md)',
                fontSize: '0.88rem',
                fontWeight: 600,
                textDecoration: 'none',
                color: isActive ? '#ffffff' : 'var(--text-muted)',
                background: isActive ? 'linear-gradient(135deg, #1e293b 0%, #0f172a 100%)' : 'transparent',
                boxShadow: isActive ? '0 2px 8px rgba(15,23,42,0.25)' : 'none',
                transition: 'all 0.2s ease',
              })}
            >
              <User size={16} /> My Profile
            </NavLink>

            <NavLink
              to="/company"
              style={({ isActive }) => ({
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                padding: '8px 16px',
                borderRadius: 'var(--radius-md)',
                fontSize: '0.88rem',
                fontWeight: 600,
                textDecoration: 'none',
                color: isActive ? '#ffffff' : 'var(--text-muted)',
                background: isActive ? 'linear-gradient(135deg, #1e293b 0%, #0f172a 100%)' : 'transparent',
                boxShadow: isActive ? '0 2px 8px rgba(15,23,42,0.25)' : 'none',
                transition: 'all 0.2s ease',
              })}
            >
              <Building2 size={16} /> Company Details
            </NavLink>
          </div>

          {/* ── Main Organization Card ────────────────────────────────────────── */}
          <div className="card" style={{ padding: '32px' }}>
            <form onSubmit={handleSubmit}>
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  marginBottom: 24,
                  paddingBottom: 14,
                  borderBottom: '1px solid var(--border)',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <Building2 size={20} color="var(--accent-blue)" />
                  <h3 style={{ fontSize: '1.05rem', fontWeight: 600, color: 'var(--text-primary)', margin: 0 }}>
                    Company Profile & Registration Details
                  </h3>
                </div>

                {isAdmin ? (
                  <span
                    style={{
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: 6,
                      fontSize: '0.78rem',
                      fontWeight: 600,
                      color: '#0284c7',
                      background: 'rgba(2, 132, 199, 0.1)',
                      border: '1px solid rgba(2, 132, 199, 0.25)',
                      padding: '4px 12px',
                      borderRadius: '20px',
                    }}
                  >
                    <ShieldCheck size={14} /> Admin Edit Mode
                  </span>
                ) : (
                  <span
                    style={{
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: 6,
                      fontSize: '0.78rem',
                      fontWeight: 500,
                      color: 'var(--text-muted)',
                      background: 'var(--bg-elevated)',
                      border: '1px solid var(--border)',
                      padding: '4px 12px',
                      borderRadius: '20px',
                    }}
                  >
                    <Lock size={13} /> Read-Only View
                  </span>
                )}
              </div>

              {error && (
                <div
                  style={{
                    background: '#fef2f2',
                    border: '1px solid #fecaca',
                    color: '#dc2626',
                    padding: '12px 16px',
                    borderRadius: 'var(--radius-md)',
                    fontSize: '0.85rem',
                    marginBottom: 20,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                  }}
                >
                  <AlertCircle size={16} /> {error}
                </div>
              )}

              {successMsg && (
                <div
                  style={{
                    background: '#f0fdf4',
                    border: '1px solid #bbf7d0',
                    color: '#16a34a',
                    padding: '12px 16px',
                    borderRadius: 'var(--radius-md)',
                    fontSize: '0.85rem',
                    marginBottom: 20,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                  }}
                >
                  <CheckCircle2 size={16} /> {successMsg}
                </div>
              )}

              <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
                <div className="company-profile-grid">
                {/* Row 1: Name & Code */}
                <div style={{ display: 'contents' }}>
                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">
                      Company / Factory Name {isAdmin && <span style={{ color: '#ef4444' }}>*</span>}
                    </label>
                    <input
                      className="form-input"
                      name="name"
                      value={company.name}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      required={isAdmin}
                      placeholder="e.g. Liha Tech Factory 1"
                      style={inputStyle()}
                    />
                  </div>

                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">
                      Factory Code {isAdmin && <span style={{ color: '#ef4444' }}>*</span>}
                    </label>
                    <input
                      className="form-input font-mono"
                      name="code"
                      value={company.code}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      required={isAdmin}
                      placeholder="e.g. FAC-01"
                      style={inputStyle(true)}
                    />
                  </div>
                </div>

                {/* Row 2: Plant & Location */}
                <div style={{ display: 'contents' }}>
                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label" htmlFor="plant-workshop-name">Plant / Workshop Name</label>
                    {isAdmin && (
                      <div className="plant-entry-row" style={{ display: 'flex', alignItems: 'center' }}>
                        <input id="plant-workshop-name" className="form-input" value={newPlantName} onChange={(event) => setNewPlantName(event.target.value)} placeholder="e.g. Pune Machining Plant" />
                      </div>
                    )}
                    {plants.length > 0 && (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 7, marginTop: 8 }}>
                        {plants.map((plant) => (
                          <div key={plant.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--bg-elevated)', border: '1px solid var(--border)', borderRadius: 6 }}>
                            <span style={{ fontWeight: 600, color: 'var(--text-primary)' }}>{plant.name}</span>
                            <span className="font-mono" style={{ fontSize: '0.72rem', color: 'var(--text-muted)' }}>{plant.code}</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>

                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">Factory Location / City</label>
                    <input
                      className="form-input"
                      name="location"
                      value={company.location}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      placeholder="e.g. Pune, Maharashtra"
                      style={inputStyle()}
                    />
                  </div>
                </div>

                {/* Row 3: Industry Type */}
                <div style={{ display: 'contents' }}>
                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">Industry Type</label>
                    <input
                      className="form-input"
                      name="industry_type"
                      value={company.industry_type}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      placeholder="e.g. Precision Component Manufacturing"
                      style={inputStyle()}
                    />
                  </div>
                </div>

                {/* Row 3: Email & Phone */}
                <div style={{ display: 'contents' }}>
                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">Official Email Address</label>
                    <input
                      className="form-input"
                      type="email"
                      name="contact_email"
                      value={company.contact_email}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      placeholder="e.g. contact@company.com"
                      style={inputStyle()}
                    />
                  </div>

                  <div className="form-group" style={{ margin: 0 }}>
                    <label className="form-label">Contact Phone Number</label>
                    <input
                      className="form-input"
                      name="phone"
                      value={company.phone}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      placeholder="e.g. +91 9876543210"
                      style={inputStyle()}
                    />
                  </div>
                </div>

                {/* Row 4: GSTIN & Company Logo */}
                <div style={{ display: 'contents' }}>
                  <div className="form-group" style={{ margin: 0, minWidth: 0 }}>
                    <label className="form-label">GSTIN / Tax Registration No.</label>
                    <input
                      className="form-input font-mono"
                      name="gstin"
                      value={company.gstin}
                      readOnly={!isAdmin}
                      onChange={handleChange}
                      placeholder="e.g. 27AAAAA0000A1Z5"
                      style={inputStyle(true)}
                    />
                  </div>

                  <div className="form-group" style={{ margin: 0, minWidth: 0 }}>
                    <label className="form-label" style={{ marginBottom: 6 }}>Company Logo (Reports, Mobile & PDFs)</label>

                    <input
                      type="file"
                      ref={fileInputRef}
                      style={{ display: 'none' }}
                      accept="image/png,image/jpeg,image/webp,image/svg+xml"
                      onChange={(e) => {
                        const file = e.target.files?.[0];
                        if (file) handleLogoFileSelect(file);
                      }}
                    />

                    {company.logo_url ? (
                      <div
                        style={{
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'space-between',
                          gap: 10,
                          padding: '0 12px',
                          height: 42,
                          background: 'var(--bg-elevated)',
                          borderRadius: 'var(--radius-md)',
                          border: '1px solid var(--border)',
                          boxSizing: 'border-box',
                        }}
                      >
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, minWidth: 0, overflow: 'hidden' }}>
                          <div
                            style={{
                              width: 28,
                              height: 28,
                              borderRadius: 6,
                              border: '1px solid var(--border)',
                              backgroundColor: '#ffffff',
                              display: 'flex',
                              alignItems: 'center',
                              justifyContent: 'center',
                              overflow: 'hidden',
                              padding: 2,
                              flexShrink: 0,
                            }}
                          >
                            <img
                              src={company.logo_url}
                              alt="Company Logo"
                              style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }}
                              onError={(e) => { e.target.style.display = 'none'; }}
                            />
                          </div>
                          <span style={{ fontSize: '0.82rem', fontWeight: 600, color: 'var(--text-primary)', whiteSpace: 'nowrap' }}>
                            Active Logo
                          </span>
                          <span
                            style={{
                              fontSize: '0.62rem',
                              padding: '1px 5px',
                              borderRadius: 4,
                              background: 'rgba(16, 185, 129, 0.1)',
                              color: '#10b981',
                              fontWeight: 700,
                            }}
                          >
                            LIVE
                          </span>
                        </div>

                        {isAdmin && (
                          <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
                            <button
                              type="button"
                              className="btn btn-secondary"
                              onClick={() => fileInputRef.current?.click()}
                              disabled={isUploadingLogo}
                              style={{ padding: '4px 8px', fontSize: '0.75rem', display: 'flex', alignItems: 'center', gap: 4, height: 28 }}
                            >
                              {isUploadingLogo ? <Loader2 size={13} className="animate-spin" /> : <Upload size={13} />}
                              Change
                            </button>
                            <button
                              type="button"
                              className="btn btn-ghost"
                              onClick={handleLogoRemove}
                              disabled={isUploadingLogo}
                              style={{ padding: '4px 6px', fontSize: '0.75rem', color: '#ef4444', height: 28 }}
                              title="Remove logo"
                            >
                              <Trash2 size={14} />
                            </button>
                          </div>
                        )}
                      </div>
                    ) : (
                      <div
                        onDragOver={(e) => { e.preventDefault(); if (isAdmin) setIsDragOver(true); }}
                        onDragLeave={() => setIsDragOver(false)}
                        onDrop={(e) => {
                          e.preventDefault();
                          setIsDragOver(false);
                          const file = e.dataTransfer.files?.[0];
                          if (file) handleLogoFileSelect(file);
                        }}
                        onClick={() => { if (isAdmin && !isUploadingLogo) fileInputRef.current?.click(); }}
                        style={{
                          border: `2px dashed ${isDragOver ? 'var(--accent-blue)' : 'var(--border)'}`,
                          backgroundColor: isDragOver ? 'rgba(56, 189, 248, 0.05)' : 'var(--bg-elevated)',
                          borderRadius: 'var(--radius-md)',
                          padding: '0 12px',
                          height: 42,
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          gap: 8,
                          cursor: isAdmin ? 'pointer' : 'default',
                          transition: 'all 0.15s ease',
                          boxSizing: 'border-box',
                        }}
                      >
                        {isUploadingLogo ? (
                          <>
                            <Loader2 size={16} className="animate-spin" style={{ color: 'var(--accent-blue)' }} />
                            <span style={{ fontSize: '0.8rem', color: 'var(--text-primary)', fontWeight: 500 }}>
                              Uploading & saving logo...
                            </span>
                          </>
                        ) : (
                          <>
                            <Upload size={15} style={{ color: 'var(--accent-blue)' }} />
                            <span style={{ fontSize: '0.8rem', fontWeight: 500, color: 'var(--text-primary)' }}>
                              {isAdmin ? 'Upload Company Logo (PNG, JPG, SVG)' : 'No logo uploaded'}
                            </span>
                          </>
                        )}
                      </div>
                    )}
                  </div>
                </div>

                {/* Row 5: Registered Address */}
                <div className="form-group" style={{ margin: 0 }}>
                  <label className="form-label">Registered Office Address</label>
                  <textarea
                    className="form-input"
                    name="address"
                    rows={2}
                    value={company.address}
                    readOnly={!isAdmin}
                    onChange={handleChange}
                    placeholder="Enter complete facility or registered office address..."
                    style={{
                      ...inputStyle(),
                      resize: isAdmin ? 'vertical' : 'none',
                    }}
                  />
                </div>
                </div>

                {/* ── Section 2: Shift & Operating Hours Configuration ──────────────── */}
                <div style={{ marginTop: 12, paddingTop: 24, borderTop: '1px solid var(--border)' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 18 }}>
                    <Clock size={19} color="var(--accent-blue)" />
                    <div>
                      <h4 style={{ fontSize: '1rem', fontWeight: 600, color: 'var(--text-primary)', margin: 0 }}>
                        Shift & Operating Standards
                      </h4>
                      <span style={{ fontSize: '0.8rem', color: 'var(--text-muted)' }}>
                        Factory shift duration, meal deductions, and net available operating time.
                      </span>
                    </div>
                  </div>

                  <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
                    {/* Shift Pattern Display / Select */}
                    <div className="form-group" style={{ margin: 0 }}>
                      <label className="form-label" style={{ fontWeight: 600, marginBottom: 10 }}>
                        Factory Shift Pattern {isAdmin && <span style={{ fontSize: '0.75rem', fontWeight: 400, color: 'var(--accent-blue)' }}>(Select to configure)</span>}
                      </label>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                        <div
                          onClick={() => handleShiftHoursChange(8)}
                          style={{
                            padding: '14px 18px',
                            borderRadius: 'var(--radius-md)',
                            border:
                              Number(company.shift_hours) === 8
                                ? '2px solid var(--accent-blue)'
                                : '1px solid var(--border)',
                            background:
                              Number(company.shift_hours) === 8
                                ? 'rgba(56,189,248,0.08)'
                                : 'var(--bg-elevated)',
                            display: 'flex',
                            alignItems: 'center',
                            gap: 12,
                            cursor: isAdmin ? 'pointer' : 'default',
                            transition: 'all 0.15s ease',
                          }}
                        >
                          <input
                            type="radio"
                            name="shift_hours_radio"
                            checked={Number(company.shift_hours) === 8}
                            disabled={!isAdmin}
                            onChange={() => handleShiftHoursChange(8)}
                            style={{ accentColor: 'var(--accent-blue)', width: 16, height: 16, cursor: isAdmin ? 'pointer' : 'default' }}
                          />
                          <div>
                            <div style={{ fontWeight: 600, fontSize: '0.92rem', color: 'var(--text-primary)' }}>
                              8-Hour Shift Pattern
                            </div>
                            <div style={{ fontSize: '0.78rem', color: 'var(--text-muted)', marginTop: 2 }}>
                              3 Shifts / Day • 480 mins gross duration
                            </div>
                          </div>
                        </div>

                        <div
                          onClick={() => handleShiftHoursChange(12)}
                          style={{
                            padding: '14px 18px',
                            borderRadius: 'var(--radius-md)',
                            border:
                              Number(company.shift_hours) === 12
                                ? '2px solid var(--accent-blue)'
                                : '1px solid var(--border)',
                            background:
                              Number(company.shift_hours) === 12
                                ? 'rgba(56,189,248,0.08)'
                                : 'var(--bg-elevated)',
                            display: 'flex',
                            alignItems: 'center',
                            gap: 12,
                            cursor: isAdmin ? 'pointer' : 'default',
                            transition: 'all 0.15s ease',
                          }}
                        >
                          <input
                            type="radio"
                            name="shift_hours_radio"
                            checked={Number(company.shift_hours) === 12}
                            disabled={!isAdmin}
                            onChange={() => handleShiftHoursChange(12)}
                            style={{ accentColor: 'var(--accent-blue)', width: 16, height: 16, cursor: isAdmin ? 'pointer' : 'default' }}
                          />
                          <div>
                            <div style={{ fontWeight: 600, fontSize: '0.92rem', color: 'var(--text-primary)' }}>
                              12-Hour Shift Pattern
                            </div>
                            <div style={{ fontSize: '0.78rem', color: 'var(--text-muted)', marginTop: 2 }}>
                              2 Shifts / Day • 720 mins gross duration
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>

                    {/* Dynamic Shift Timings Grid */}
                    <div style={{ marginTop: 20, paddingTop: 20, borderTop: '1px solid var(--border)' }}>
                      <h5 style={{ fontSize: '0.9rem', fontWeight: 600, color: 'var(--text-primary)', marginBottom: 12 }}>
                        Exact Shift Timings
                      </h5>
                      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 16 }}>
                        <div className="form-group" style={{ margin: 0 }}>
                          <label className="form-label">Shift 1 Start Time</label>
                          <input
                            className="form-input font-mono"
                            type="time"
                            name="shift_1_start"
                            value={company.shift_1_start}
                            readOnly={!isAdmin}
                            onChange={handleChange}
                            required={isAdmin}
                            style={inputStyle(true)}
                          />
                        </div>
                        <div className="form-group" style={{ margin: 0 }}>
                          <label className="form-label">Shift 2 Start Time</label>
                          <input
                            className="form-input font-mono"
                            type="time"
                            name="shift_2_start"
                            value={company.shift_2_start}
                            readOnly={!isAdmin}
                            onChange={handleChange}
                            required={isAdmin}
                            style={inputStyle(true)}
                          />
                        </div>
                        {Number(company.shift_hours) === 8 && (
                          <div className="form-group" style={{ margin: 0 }}>
                            <label className="form-label">Shift 3 Start Time</label>
                            <input
                              className="form-input font-mono"
                              type="time"
                              name="shift_3_start"
                              value={company.shift_3_start}
                              readOnly={!isAdmin}
                              onChange={handleChange}
                              required={isAdmin}
                              style={inputStyle(true)}
                            />
                          </div>
                        )}
                      </div>
                    </div>

                    {/* Break Inputs Grid */}
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                      <div className="form-group" style={{ margin: 0 }}>
                        <label className="form-label">Lunch / Dinner Break (mins)</label>
                        <input
                          className="form-input font-mono"
                          type="number"
                          min="0"
                          max="180"
                          name="lunch_break_minutes"
                          value={company.lunch_break_minutes}
                          readOnly={!isAdmin}
                          onChange={handleChange}
                          style={inputStyle(true)}
                        />
                      </div>

                      <div className="form-group" style={{ margin: 0 }}>
                        <label className="form-label">Tea & Rest Breaks (mins)</label>
                        <input
                          className="form-input font-mono"
                          type="number"
                          min="0"
                          max="180"
                          name="tea_break_minutes"
                          value={company.tea_break_minutes}
                          readOnly={!isAdmin}
                          onChange={handleChange}
                          style={inputStyle(true)}
                        />
                      </div>
                    </div>

                    {/* Operating Capacity Summary Card */}
                    <div
                      style={{
                        background: 'var(--bg-elevated)',
                        border: '1px solid var(--border)',
                        borderRadius: 'var(--radius-md)',
                        padding: '20px 24px',
                        marginTop: 4,
                      }}
                    >
                      <div
                        style={{
                          fontSize: '0.75rem',
                          fontWeight: 700,
                          textTransform: 'uppercase',
                          color: 'var(--text-muted)',
                          letterSpacing: '0.06em',
                          marginBottom: 14,
                        }}
                      >
                        Operating Capacity Summary
                      </div>

                      <div
                        style={{
                          display: 'grid',
                          gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
                          gap: 20,
                          alignItems: 'center',
                        }}
                      >
                        <div>
                          <div style={{ fontSize: '0.78rem', color: 'var(--text-muted)' }}>Gross Shift Duration</div>
                          <div style={{ fontSize: '1.1rem', fontWeight: 700, color: 'var(--text-primary)', marginTop: 2 }}>
                            {grossShiftMins}{' '}
                            <span style={{ fontSize: '0.8rem', fontWeight: 400, color: 'var(--text-muted)' }}>
                              mins ({company.shift_hours} hrs)
                            </span>
                          </div>
                        </div>

                        <div>
                          <div style={{ fontSize: '0.78rem', color: 'var(--text-muted)' }}>Total Break Deductions</div>
                          <div style={{ fontSize: '1.1rem', fontWeight: 700, color: '#e11d48', marginTop: 2 }}>
                            -{totalBreakMins}{' '}
                            <span style={{ fontSize: '0.8rem', fontWeight: 400, color: 'var(--text-muted)' }}>mins</span>
                          </div>
                        </div>

                        <div style={{ paddingLeft: 12, borderLeft: '2px solid var(--accent-blue)' }}>
                          <div style={{ fontSize: '0.78rem', fontWeight: 600, color: 'var(--accent-blue)' }}>
                            Net Available Working Time
                          </div>
                          <div style={{ fontSize: '1.3rem', fontWeight: 800, color: 'var(--text-primary)', marginTop: 2 }}>
                            {netAvailableWorkingMins}{' '}
                            <span style={{ fontSize: '0.85rem', fontWeight: 600, color: 'var(--text-muted)' }}>
                              mins / shift
                            </span>
                          </div>
                          <div style={{ fontSize: '0.74rem', color: 'var(--text-muted)', marginTop: 2 }}>
                            Total Plant Uptime: {dailyTotalUptimeMins} mins ({company.total_shifts_per_day} shifts/day)
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                {/* ── Admin Action Bar ────────────────────────────────────────────── */}
                {isAdmin && (
                  <div
                    style={{
                      marginTop: 16,
                      paddingTop: 20,
                      borderTop: '1px solid var(--border)',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'flex-end',
                      gap: 16,
                    }}
                  >
                    <button
                      type="submit"
                      className="btn btn-primary"
                      disabled={isSaving || loading}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: 8,
                        padding: '10px 24px',
                        fontSize: '0.92rem',
                        fontWeight: 600,
                        boxShadow: '0 2px 10px rgba(56, 189, 248, 0.25)',
                        cursor: isSaving ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {isSaving ? (
                        <>
                          <Loader2 size={16} className="animate-spin" />
                          Saving Changes...
                        </>
                      ) : (
                        <>
                          <Save size={16} />
                          Save Company Details
                        </>
                      )}
                    </button>
                  </div>
                )}
              </div>
            </form>
          </div>
        </div>
      </div>
    </>
  );
}
