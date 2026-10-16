import { useState, useEffect, useMemo } from 'react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import Modal from '../components/common/Modal';
import Badge from '../components/common/Badge';
import { getUsers, registerUser, deleteUser, updateUserStatus, updateUserShift, getPlants,
  getRoles, createRole, updateRole, getAccessCatalog, getUserAccess, updateUserAccess } from '../api/users';
import PermissionPicker from '../components/users/PermissionPicker';
import { useCompany } from '../context/CompanyContext';
import { useAuth } from '../context/AuthContext';
import { can } from '../utils/access';
import { formatDateTime } from '../utils/formatters';

export default function UsersPage() {
  const { user: currentUser } = useAuth();
  const [users, setUsers]         = useState([]);
  const [plants, setPlants]       = useState([]);
  const [roles, setRoles] = useState([]);
  const [catalog, setCatalog] = useState({ groups: [], common: [] });
  const [selectedPermissions, setSelectedPermissions] = useState([]);
  const [accessTarget, setAccessTarget] = useState(null);
  const [accessRole, setAccessRole] = useState('');
  const [accessPermissions, setAccessPermissions] = useState([]);
  const [accessSaving, setAccessSaving] = useState(false);
  const [showRoleModal, setShowRoleModal] = useState(false);
  const [newRoleName, setNewRoleName] = useState('');
  const [newRolePermissions, setNewRolePermissions] = useState([]);
  const [showRoleEditModal, setShowRoleEditModal] = useState(false);
  const [roleEditSlug, setRoleEditSlug] = useState('');
  const [roleEditPermissions, setRoleEditPermissions] = useState([]);
  const [roleEditSaving, setRoleEditSaving] = useState(false);
  const [roleSaving, setRoleSaving] = useState(false);
  const [loading, setLoading]     = useState(true);
  const [showModal, setShowModal] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [roleFilter, setRoleFilter] = useState('');

  const [deleteTargetUser, setDeleteTargetUser] = useState(null);
  const [deleting, setDeleting]                 = useState(false);
  const [successBannerMsg, setSuccessBannerMsg] = useState('');
  const [errorToast, setErrorToast] = useState('');

  // Multi-shift configuration from Company Details (8h -> 3 shifts; 12h -> 2 shifts)
  const { shiftHours, totalShiftsPerDay } = useCompany();
  const is12HourSchedule = shiftHours === 12 || totalShiftsPerDay === 2;
  const availableShifts = is12HourSchedule
    ? [
        { value: 'I', label: 'Shift I (Day Shift)' },
        { value: 'II', label: 'Shift II (Night Shift)' },
        { value: 'ALL', label: 'All Shifts (Flexible / Supervisor)' },
      ]
    : [
        { value: 'I', label: 'Shift I (Morning Shift)' },
        { value: 'II', label: 'Shift II (Evening Shift)' },
        { value: 'III', label: 'Shift III (Night Shift)' },
        { value: 'ALL', label: 'All Shifts (Flexible / Supervisor)' },
      ];

  // Form state for creating user accounts
  const [formData, setFormData] = useState({
    username: '',
    first_name: '',
    last_name: '',
    employee_id: '',
    email: '',
    phone: '',
    role: 'operator',
    assigned_shift: 'I',
    plant: '',
    password: '',
    password2: '',
  });

  // Filter out "ALL" option for operators - they must have a specific shift assigned
  const shiftOptions = useMemo(() => {
    return formData.role === 'operator'
      ? availableShifts.filter(s => s.value !== 'ALL')
      : availableShifts;
  }, [formData.role, availableShifts, is12HourSchedule]);

  const sortUsers = (list) => {
    const sorted = [...list];
    sorted.sort((a, b) => {
      const aActive = a.is_active === true || a.is_active === undefined ? 1 : 0;
      const bActive = b.is_active === true || b.is_active === undefined ? 1 : 0;
      return bActive - aActive;
    });
    return sorted;
  };

  const fetchUsers = async (showSpinner = true) => {
    if (showSpinner) setLoading(true);
    try {
      const res = await getUsers(roleFilter ? { role: roleFilter } : {});
      const data = res.data?.results ?? res.data ?? [];
      const userList = Array.isArray(data) ? [...data] : [];
      setUsers(sortUsers(userList));
    } catch {
      setUsers([]);
    } finally {
      if (showSpinner) setLoading(false);
    }
  };

  const fetchPlantList = async () => {
    try {
      const res = await getPlants();
      const data = res.data?.results ?? res.data ?? [];
      setPlants(Array.isArray(data) ? data : []);
      if (data.length > 0 && !formData.plant) {
        setFormData(prev => ({ ...prev, plant: data[0].id }));
      }
    } catch { /* ignore */ }
  };

  useEffect(() => {
    fetchUsers();
    fetchPlantList();
  }, [roleFilter]);

  useEffect(() => {
    Promise.all([getRoles(), getAccessCatalog()]).then(([roleResponse, catalogResponse]) => {
      setRoles(roleResponse.data);
      setCatalog(catalogResponse.data);
      const operator = roleResponse.data.find((role) => role.slug === 'operator');
      setSelectedPermissions([...(operator?.permissions || []), ...catalogResponse.data.common]);
    }).catch(() => {
      const message = 'Could not load roles and permissions.';
      setErrorToast(message);
    });
  }, []);

  useEffect(() => {
    if (!errorToast) return undefined;
    const timer = window.setTimeout(() => {
      setErrorToast('');
    }, 4500);
    return () => window.clearTimeout(timer);
  }, [errorToast]);

  const dismissErrorToast = () => {
    setErrorToast('');
  };

  const rolePermissions = (slug) => roles.find((role) => role.slug === slug)?.permissions || [];
  const overridesFor = (slug, selected) => {
    const base = new Set([...rolePermissions(slug), ...catalog.common]);
    const chosen = new Set(selected);
    return {
      access_grants: [...chosen].filter((key) => !base.has(key)),
        access_denials: [...base].filter((key) => !chosen.has(key)),
    };
  };

  const handleChange = (e) => {
    if (e.target.name === 'role') {
      if (e.target.value === '__create_role__') {
        setNewRoleName('');
        setNewRolePermissions([...catalog.common]);
        setShowRoleModal(true);
        return;
      }
      setSelectedPermissions([...rolePermissions(e.target.value), ...catalog.common]);

      // If changing to operator role and current shift is 'ALL', reset to first available shift
      if (e.target.value === 'operator' && formData.assigned_shift === 'ALL') {
        setFormData({ ...formData, role: e.target.value, assigned_shift: 'I' });
        return;
      }
    }
    setFormData({ ...formData, [e.target.name]: e.target.value });
  };

  const handleCreateRole = async () => {
    if (!newRoleName.trim()) return;
    setErrorToast('');
    setRoleSaving(true);
    try {
      const response = await createRole({ name: newRoleName.trim(), permissions: newRolePermissions });
      const rolesResponse = await getRoles();
      const createdRole = rolesResponse.data.find((role) => role.slug === response.data.slug) || response.data;
      setRoles(rolesResponse.data);
      setFormData((currentForm) => ({ ...currentForm, role: createdRole.slug }));
      setSelectedPermissions([...createdRole.permissions, ...catalog.common]);
      setRoleEditSlug(createdRole.slug);
      setRoleEditPermissions([...createdRole.permissions, ...catalog.common]);
      setShowRoleModal(false);
      setSuccessBannerMsg(`Role "${createdRole.name}" created and selected.`);
    } catch (err) {
      const errData = err.response?.data;
      if (errData && typeof errData === 'object') {
        const messages = Object.entries(errData).flatMap(([key, value]) => {
          const values = Array.isArray(value) ? value : [value];
          return values.map((message) => `${key.toUpperCase()}: ${message}`);
        });
        const message = messages.join(' · ') || 'Could not create role.';
        setErrorToast(message);
      } else {
        const message = 'Could not create role.';
        setErrorToast(message);
      }
    } finally {
      setRoleSaving(false);
    }
  };

  const openRoleEditor = (slug = roles.find((role) => role.slug !== 'admin')?.slug) => {
    if (!slug) return;
    setRoleEditSlug(slug);
    setRoleEditPermissions([...rolePermissions(slug), ...catalog.common]);
    setShowRoleEditModal(true);
  };

  const handleRoleEdit = async () => {
    if (!roleEditSlug) return;
    setErrorToast('');
    setRoleEditSaving(true);
    try {
      await updateRole(roleEditSlug, {
        permissions: roleEditPermissions,
      });
      const rolesResponse = await getRoles();
      setRoles(rolesResponse.data);
      if (formData.role === roleEditSlug) {
        setSelectedPermissions([...roleEditPermissions]);
      }
      if (accessRole === roleEditSlug) {
        setAccessPermissions([...roleEditPermissions]);
      }
      setShowRoleEditModal(false);
      const updatedRole = rolesResponse.data.find((role) => role.slug === roleEditSlug);
      setSuccessBannerMsg(`Role "${updatedRole?.name || roleEditSlug}" permissions updated.`);
    } catch (err) {
      const detail = err.response?.data?.detail;
      const message = detail || 'Could not update role permissions.';
      setErrorToast(message);
    } finally {
      setRoleEditSaving(false);
    }
  };

  const openAccess = async (userObj) => {
    setErrorToast('');
    try {
      const response = await getUserAccess(userObj.id);
      setAccessTarget(userObj);
      setAccessRole(response.data.role);
      setAccessPermissions(response.data.permissions);
    } catch {
      const message = 'Could not load this user’s access.';
      setErrorToast(message);
    }
  };

  const saveAccess = async () => {
    if (!accessTarget) return;
    setErrorToast('');
    setAccessSaving(true);
    try {
      await updateUserAccess(accessTarget.id, {
        role: accessRole, ...overridesFor(accessRole, accessPermissions),
      });
      setSuccessBannerMsg(`Access updated for ${accessTarget.username}.`);
      setAccessTarget(null);
      fetchUsers(false);
    } catch (err) {
      const message = err.response?.data?.detail || 'Could not update user access.';
      setErrorToast(message);
    } finally {
      setAccessSaving(false);
    }
  };

  const handleCreateUser = async (e) => {
    e.preventDefault();
    setErrorToast('');
    setSuccessBannerMsg('');

    if (!formData.username.trim()) {
      setErrorToast('Username is required.');
      return;
    }
    if (!formData.employee_id.trim()) {
      setErrorToast('Employee ID is required.');
      return;
    }
    if (!formData.password) {
      setErrorToast('Password is required.');
      return;
    }
    if (formData.password !== formData.password2) {
      setErrorToast('Passwords do not match.');
      return;
    }

    setSubmitting(true);
    try {
      await registerUser({ ...formData, ...overridesFor(formData.role, selectedPermissions) });
      setShowModal(false);
      setSuccessBannerMsg(`User account "${formData.username}" created with the selected access.`);
      // Reset form
      setFormData({
        username: '',
        first_name: '',
        last_name: '',
        employee_id: '',
        email: '',
        phone: '',
        role: 'operator',
        assigned_shift: 'I',
        plant: plants[0]?.id ?? '',
        password: '',
        password2: '',
      });
      setSelectedPermissions([...rolePermissions('operator'), ...catalog.common]);
      fetchUsers();
    } catch (err) {
      const errData = err.response?.data;
      if (errData && typeof errData === 'object') {
        const validationMessages = Object.entries(errData).flatMap(([key, value]) => {
          const values = Array.isArray(value) ? value : [value];
          return values.map((message) => `${key.toUpperCase()}: ${message}`);
        });
        const message = validationMessages.join(' · ') || 'Failed to save user account to database.';
        setErrorToast(message);
      } else {
        const message = 'Failed to save user account to database.';
        setErrorToast(message);
      }
    } finally {
      setSubmitting(false);
    }
  };

  const handleShiftChange = async (userObj, newShift) => {
    setErrorToast('');
    try {
      await updateUserShift(userObj.id, newShift);
      setUsers((prev) =>
        prev.map((u) =>
          u.id === userObj.id ? { ...u, assigned_shift: newShift, assigned_shift_display: `Shift ${newShift}` } : u
        )
      );
      setSuccessBannerMsg(`✓ ${userObj.username} (${userObj.full_name || userObj.employee_id}) reassigned to Shift ${newShift} successfully.`);
      setTimeout(() => setSuccessBannerMsg(''), 4000);
    } catch (err) {
      const message = err?.response?.data?.message || 'Failed to reassign user shift.';
      setErrorToast(message);
      setTimeout(() => setErrorToast(''), 4000);
    }
  };

  const handleDelete = (userObj) => {
    setSuccessBannerMsg('');
    setErrorToast('');
    setDeleteTargetUser(userObj);
  };

  const confirmDeleteUser = async () => {
    if (!deleteTargetUser) return;
    setErrorToast('');
    setDeleting(true);
    setSuccessBannerMsg('');

    try {
      const res = await deleteUser(deleteTargetUser.id);
      const data = res.data;
      
      const msg = data?.message || (data?.action === 'deactivated' 
        ? `User account "${deleteTargetUser.username}" has historical inspection records and was deactivated instead.`
        : `User account "${deleteTargetUser.username}" was deleted successfully.`);
      
      setSuccessBannerMsg(`✓ ${msg}`);
      setDeleteTargetUser(null);
      fetchUsers();
    } catch (err) {
      const respData = err.response?.data;
      let errMsg = 'Failed to delete user account.';
      if (respData?.message) {
        errMsg = respData.message;
      } else if (respData?.detail) {
        errMsg = respData.detail;
      }
      setErrorToast(errMsg);
      setDeleteTargetUser(null);
    } finally {
      setDeleting(false);
    }
  };

  const handleToggleActive = async (userObj, targetActive) => {
    setSuccessBannerMsg('');
    setErrorToast('');

    // Optimistically update local state immediately : row moves to correct position right away
    setUsers(prev => sortUsers(
      prev.map(u => u.id === userObj.id ? { ...u, is_active: targetActive } : u)
    ));

    try {
      const res = await updateUserStatus(userObj.id, targetActive);
      // Update the row with server-confirmed data to stay in sync
      const serverUser = res.data?.user;
      if (serverUser) {
        setUsers(prev => sortUsers(
          prev.map(u => u.id === userObj.id ? { ...u, ...serverUser } : u)
        ));
      }
      setSuccessBannerMsg(`✓ User account "${userObj.username}" has been ${targetActive ? 'reactivated' : 'inactivated'}.`);
    } catch (err) {
      // Revert optimistic update on failure
      setUsers(prev => sortUsers(
        prev.map(u => u.id === userObj.id ? { ...u, is_active: !targetActive } : u)
      ));
      const respData = err.response?.data;
      const msg = respData?.message || respData?.detail || `Failed to update status for "${userObj.username}".`;
      setErrorToast(msg);
    }
  };

  const getRoleLabel = (role) => {
    const configured = roles.find((item) => item.slug === role);
    if (configured) return configured.name.toUpperCase();
    switch (role) {
      case 'supervisor': return 'SUPERVISOR';
      case 'quality_engineer': return 'QUALITY ENGINEER';
      case 'inspector': return 'INSPECTOR';
      case 'calibrator': return 'CALIBRATOR';
      case 'operator': return 'OPERATOR';
      case 'admin': return 'ADMIN';
      default: return role ? role.toUpperCase() : 'USER';
    }
  };

  const getRoleBadgeClass = (role) => {
    switch (role) {
      case 'supervisor': return 'badge-purple';
      case 'quality_engineer': return 'badge-ok';
      case 'inspector': return 'badge-ok';
      case 'calibrator': return 'badge-progress';
      case 'operator': return 'badge-blue';
      default: return 'badge-manual';
    }
  };

  return (
    <>
      {errorToast && (
        <div className="app-toast app-toast-error" role="alert" aria-live="assertive">
          <span>⚠️ {errorToast}</span>
          <button
            type="button"
            className="app-toast-close"
            onClick={dismissErrorToast}
            aria-label="Dismiss error notification"
          >
            ×
          </button>
        </div>
      )}

      <Header
        title="User & Account Management"
        subtitle="Manage accounts for Supervisors, Quality Inspectors, Calibrators, and Machine Operators"
      />

      <div className="page-content bg-gradient-animated">
        <Breadcrumbs items={[{ label: 'User Management' }]} />
        <div className="card">
          {successBannerMsg && (
            <div className="badge badge-ok mb-16" style={{ width: '100%', padding: '12px 16px', borderRadius: 8, fontSize: 13, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span>{successBannerMsg}</span>
              <button onClick={() => setSuccessBannerMsg('')} style={{ background: 'none', border: 'none', color: '#fff', cursor: 'pointer', fontWeight: 'bold' }}>✕</button>
            </div>
          )}

          <div className="section-header" style={{ marginBottom: 20 }}>
            <h3 className="section-title">
              <span className="dot" />
              Account Registry ({users.length})
            </h3>
            <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <select
                className="form-select"
                value={roleFilter}
                onChange={(e) => setRoleFilter(e.target.value)}
                style={{ width: 170, padding: '6px 12px' }}
              >
                <option value="">All Roles</option>
                {roles.map((role) => <option key={role.slug} value={role.slug}>{role.name}</option>)}
              </select>

              {can(currentUser, 'roles.manage') && <button
                className="btn btn-outline"
                onClick={() => openRoleEditor()}
                disabled={!roles.length}
              >
                Manage Roles
              </button>}

              {can(currentUser, 'users.create') && <button
                id="create-operator-btn"
                className="btn btn-primary"
                onClick={() => {
                  setShowModal(true);
                }}
              >
                + Create User / Account
              </button>}
            </div>
          </div>

          {loading ? (
            <LoadingSpinner message="Fetching user accounts from database..." />
          ) : users.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-text">No accounts found. Click "+ Create User / Account" to add one!</div>
            </div>
          ) : (
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Emp ID</th>
                    <th>Full Name</th>
                    <th>Username</th>
                    <th>Email</th>
                    <th>Phone</th>
                    <th>Role</th>
                    <th>Assigned Shift</th>
                    <th>Plant Location</th>
                    <th>Status</th>
                    <th>Created At</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {users.map((u) => (
                    <tr key={u.id}>
                      <td className="font-mono font-bold text-blue">{u.employee_id || `EMP-${u.id}`}</td>
                      <td>{u.full_name || u.username}</td>
                      <td className="font-mono">{u.username}</td>
                      <td className="text-xs">{u.email || '-'}</td>
                      <td className="text-xs font-mono">{u.phone || '-'}</td>
                      <td>
                        <span className={`badge ${getRoleBadgeClass(u.role)}`}>
                          {getRoleLabel(u.role)}
                        </span>
                      </td>
                      <td>
                        {u.role === 'admin' ? (
                          <span
                            style={{
                              display: 'inline-block',
                              padding: '2px 8px',
                              fontSize: 11,
                              fontWeight: 700,
                              borderRadius: 4,
                              background: '#f1f5f9',
                              color: '#475569',
                              letterSpacing: '0.04em',
                            }}
                          >
                            ALL SHIFTS
                          </span>
                        ) : (
                          <select
                            value={u.assigned_shift || 'ALL'}
                            onChange={(e) => handleShiftChange(u, e.target.value)}
                            disabled={!can(currentUser, 'users.manage')}
                            title="Click to reassign worker shift"
                            style={{
                              padding: '3px 8px',
                              fontSize: 12,
                              fontWeight: 700,
                              fontFamily: 'Inter, sans-serif',
                              borderRadius: 6,
                              border: '1px solid #cbd5e1',
                              cursor: 'pointer',
                              outline: 'none',
                              background:
                                u.assigned_shift === 'I'
                                  ? '#eff6ff'
                                  : u.assigned_shift === 'II'
                                  ? '#f5f3ff'
                                  : u.assigned_shift === 'III'
                                  ? '#fffbeb'
                                  : '#f0fdf4',
                              color:
                                u.assigned_shift === 'I'
                                  ? '#1d4ed8'
                                  : u.assigned_shift === 'II'
                                  ? '#6d28d9'
                                  : u.assigned_shift === 'III'
                                  ? '#b45309'
                                  : '#15803d',
                            }}
                          >
                            <option value="I">Shift I</option>
                            <option value="II">Shift II</option>
                            {!is12HourSchedule && <option value="III">Shift III</option>}
                            <option value="ALL">All Shifts</option>
                          </select>
                        )}
                      </td>
                      <td>{u.plant_name || 'Main Plant #1'}</td>
                      <td>
                        <span className={`badge badge-${u.is_active !== false ? 'ok' : 'red'}`}>
                          {u.is_active !== false ? 'ACTIVE' : 'INACTIVE'}
                        </span>
                      </td>
                      <td className="text-xs text-muted">{formatDateTime(u.created_at)}</td>
                      <td style={{ textAlign: 'right' }}>
                        <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                          {can(currentUser, 'users.manage') && <button className="btn btn-ghost" onClick={() => openAccess(u)}>Access</button>}
                        {u.role !== 'admin' && can(currentUser, 'users.manage') && (
                          <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                            {u.is_active !== false ? (
                              <>
                                <button
                                  onClick={() => handleToggleActive(u, false)}
                                  title="Inactivate user account"
                                  style={{
                                    padding: '4px 12px',
                                    fontSize: 11,
                                    fontWeight: 600,
                                    fontFamily: 'Inter, sans-serif',
                                    letterSpacing: '0.03em',
                                    color: '#64748b',
                                    background: 'transparent',
                                    border: '1px solid #cbd5e1',
                                    borderRadius: 6,
                                    cursor: 'pointer',
                                    transition: 'all 0.2s ease',
                                  }}
                                  onMouseEnter={e => {
                                    e.target.style.background = '#f1f5f9';
                                    e.target.style.borderColor = '#94a3b8';
                                    e.target.style.color = '#334155';
                                  }}
                                  onMouseLeave={e => {
                                    e.target.style.background = 'transparent';
                                    e.target.style.borderColor = '#cbd5e1';
                                    e.target.style.color = '#64748b';
                                  }}
                                >
                                  Inactivate
                                </button>
                                <button
                                  onClick={() => handleDelete(u)}
                                  title="Delete user account"
                                  style={{
                                    padding: '4px 12px',
                                    fontSize: 11,
                                    fontWeight: 600,
                                    fontFamily: 'Inter, sans-serif',
                                    letterSpacing: '0.03em',
                                    color: '#dc2626',
                                    background: 'transparent',
                                    border: '1px solid #fca5a5',
                                    borderRadius: 6,
                                    cursor: 'pointer',
                                    transition: 'all 0.2s ease',
                                  }}
                                  onMouseEnter={e => {
                                    e.target.style.background = '#fef2f2';
                                    e.target.style.borderColor = '#dc2626';
                                  }}
                                  onMouseLeave={e => {
                                    e.target.style.background = 'transparent';
                                    e.target.style.borderColor = '#fca5a5';
                                  }}
                                >
                                  Delete
                                </button>
                              </>
                            ) : (
                              <>
                                <button
                                  onClick={() => handleToggleActive(u, true)}
                                  title="Reactivate user account"
                                  style={{
                                    padding: '4px 12px',
                                    fontSize: 11,
                                    fontWeight: 600,
                                    fontFamily: 'Inter, sans-serif',
                                    letterSpacing: '0.03em',
                                    color: '#1d4ed8',
                                    background: 'transparent',
                                    border: '1px solid #93c5fd',
                                    borderRadius: 6,
                                    cursor: 'pointer',
                                    transition: 'all 0.2s ease',
                                  }}
                                  onMouseEnter={e => {
                                    e.target.style.background = '#eff6ff';
                                    e.target.style.borderColor = '#1d4ed8';
                                  }}
                                  onMouseLeave={e => {
                                    e.target.style.background = 'transparent';
                                    e.target.style.borderColor = '#93c5fd';
                                  }}
                                >
                                  Reactivate
                                </button>
                                <button
                                  onClick={() => handleDelete(u)}
                                  title="Delete user account"
                                  style={{
                                    padding: '4px 12px',
                                    fontSize: 11,
                                    fontWeight: 600,
                                    fontFamily: 'Inter, sans-serif',
                                    letterSpacing: '0.03em',
                                    color: '#dc2626',
                                    background: 'transparent',
                                    border: '1px solid #fca5a5',
                                    borderRadius: 6,
                                    cursor: 'pointer',
                                    transition: 'all 0.2s ease',
                                  }}
                                  onMouseEnter={e => {
                                    e.target.style.background = '#fef2f2';
                                    e.target.style.borderColor = '#dc2626';
                                  }}
                                  onMouseLeave={e => {
                                    e.target.style.background = 'transparent';
                                    e.target.style.borderColor = '#fca5a5';
                                  }}
                                >
                                  Delete
                                </button>
                              </>
                            )}
                          </div>
                        )}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {/* Modal for creating a new user account */}
      {showModal && (
        <Modal
          size="wide"
          title="Create User Account"
          onClose={() => setShowModal(false)}
          footer={
            <>
              <button
                className="btn btn-ghost"
                onClick={() => setShowModal(false)}
                disabled={submitting}
              >
                Cancel
              </button>
              <button
                id="submit-create-user"
                className="btn btn-primary"
                onClick={handleCreateUser}
                disabled={submitting}
              >
                {submitting ? 'Saving to Database...' : 'Save Account & Enable Login'}
              </button>
            </>
          }
        >
          <form onSubmit={handleCreateUser}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">Username * (Login Identifier)</label>
                <input
                  type="text"
                  name="username"
                  className="form-input"
                  placeholder="e.g. supervisor_rahul or inspector_sarah"
                  required
                  value={formData.username}
                  onChange={handleChange}
                />
              </div>

              <div className="form-group">
                <label className="form-label">Employee ID *</label>
                <input
                  type="text"
                  name="employee_id"
                  className="form-input"
                  placeholder="e.g. EMP-105"
                  required
                  value={formData.employee_id}
                  onChange={handleChange}
                />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">First Name</label>
                <input
                  type="text"
                  name="first_name"
                  className="form-input"
                  placeholder="e.g. Rahul"
                  value={formData.first_name}
                  onChange={handleChange}
                />
              </div>

              <div className="form-group">
                <label className="form-label">Last Name</label>
                <input
                  type="text"
                  name="last_name"
                  className="form-input"
                  placeholder="e.g. Sharma"
                  value={formData.last_name}
                  onChange={handleChange}
                />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">Email Address</label>
                <input
                  type="email"
                  name="email"
                  className="form-input"
                  placeholder="e.g. rahul@example.com"
                  value={formData.email}
                  onChange={handleChange}
                />
              </div>

              <div className="form-group">
                <label className="form-label">Phone Number</label>
                <input
                  type="text"
                  name="phone"
                  className="form-input"
                  placeholder="e.g. +91 9876543210"
                  value={formData.phone}
                  onChange={handleChange}
                />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">Plant Assignment *</label>
                <select
                  name="plant"
                  className="form-select"
                  value={formData.plant}
                  onChange={handleChange}
                >
                  {plants.length === 0 ? (
                    <option value="1">Main Machining Plant #1</option>
                  ) : (
                    plants.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name} ({p.factory_name})
                      </option>
                    ))
                  )}
                </select>
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">Login Password *</label>
                <input
                  type="password"
                  name="password"
                  className="form-input"
                  placeholder="Enter login password..."
                  required
                  value={formData.password}
                  onChange={handleChange}
                />
              </div>

              <div className="form-group">
                <label className="form-label">Confirm Password *</label>
                <input
                  type="password"
                  name="password2"
                  className="form-input"
                  placeholder="Confirm password..."
                  required
                  value={formData.password2}
                  onChange={handleChange}
                />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
              <div className="form-group">
                <label className="form-label">Account Role *</label>
                <select
                  name="role"
                  className="form-select"
                  value={formData.role}
                  onChange={handleChange}
                >
                  {can(currentUser, 'roles.manage') && (
                    <option value="__create_role__">+ Create new role...</option>
                  )}
                  {roles.map((role) => <option key={role.slug} value={role.slug}>{role.name}</option>)}
                </select>
              </div>

              <div className="form-group">
                <label className="form-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span>Assigned Shift *</span>
                  <span style={{ fontSize: 11, color: '#2563eb', fontWeight: 600 }}>
                    {is12HourSchedule ? '12h (2 Shifts)' : '8h (3 Shifts)'}
                  </span>
                </label>
                <select
                  name="assigned_shift"
                  className="form-select"
                  value={formData.assigned_shift}
                  onChange={handleChange}
                  style={{
                    borderColor: '#93c5fd',
                    backgroundColor: '#eff6ff',
                    fontWeight: 600,
                  }}
                >
                  {shiftOptions.map((s) => (
                    <option key={s.value} value={s.value}>
                      {s.label}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="form-group user-permission-section" style={{ marginBottom: 16 }}>
              <div className="user-permission-header">
                <div>
                  <label className="form-label" style={{ marginBottom: 2 }}>Access for this user</label>
                  <p style={{ fontSize: 12, margin: 0 }}>The selected role fills these permissions. Changes here apply only to this user.</p>
                </div>
                <span className="permission-summary">{selectedPermissions.length} selected</span>
              </div>
              <PermissionPicker groups={catalog.groups} common={catalog.common}
                value={selectedPermissions} onChange={setSelectedPermissions} />
            </div>
          </form>
        </Modal>
      )}

      {showRoleModal && (
        <Modal
          size="xl"
          zIndex={10001}
          title="Create New Role"
          onClose={() => setShowRoleModal(false)}
          footer={<>
            <button className="btn btn-ghost" onClick={() => setShowRoleModal(false)} disabled={roleSaving}>
              Cancel
            </button>
            <button className="btn btn-primary" onClick={handleCreateRole}
              disabled={roleSaving || !newRoleName.trim()}>
              {roleSaving ? 'Creating Role...' : 'Create Role'}
            </button>
          </>}
        >
          <form onSubmit={(event) => { event.preventDefault(); handleCreateRole(); }}>
            <div className="form-group">
              <label className="form-label" htmlFor="new-role-name">Role Name *</label>
              <input
                id="new-role-name"
                className="form-input"
                value={newRoleName}
                onChange={(event) => setNewRoleName(event.target.value)}
                placeholder="e.g. Quality Supervisor"
                maxLength={100}
                autoFocus
              />
            </div>

            <div className="form-group user-permission-section" style={{ marginTop: 16 }}>
              <div className="user-permission-header">
                <div>
                  <label className="form-label" style={{ marginBottom: 2 }}>Role Permissions</label>
                  <p style={{ fontSize: 12, margin: 0 }}>Choose the modules and actions this role can access.</p>
                </div>
                <span className="permission-summary">{newRolePermissions.length} selected</span>
              </div>
              <PermissionPicker groups={catalog.groups} common={catalog.common}
                value={newRolePermissions} onChange={setNewRolePermissions} />
            </div>
          </form>
        </Modal>
      )}

      {showRoleEditModal && (
        <Modal
          size="role-editor"
          title="Edit Role Permissions"
          onClose={() => setShowRoleEditModal(false)}
          footer={<>
            <button className="btn btn-ghost" onClick={() => setShowRoleEditModal(false)} disabled={roleEditSaving}>
              Cancel
            </button>
            <button className="btn btn-primary" onClick={handleRoleEdit} disabled={roleEditSaving || !roleEditSlug}>
              {roleEditSaving ? 'Saving Role...' : 'Save Role Permissions'}
            </button>
          </>}
        >
          <label className="form-label" htmlFor="edit-role-select">Role to edit</label>
          <select
            id="edit-role-select"
            className="form-select"
            value={roleEditSlug}
            onChange={(event) => {
              const slug = event.target.value;
              if (slug === '__create_role__') {
                setNewRoleName('');
                setNewRolePermissions([...catalog.common]);
                setShowRoleModal(true);
                return;
              }
              setRoleEditSlug(slug);
              setRoleEditPermissions([...rolePermissions(slug), ...catalog.common]);
            }}
            style={{ marginBottom: 16 }}
          >
            <option value="__create_role__">+ Create new role...</option>
            {roles.filter((role) => role.slug !== 'admin').map((role) => (
              <option key={role.slug} value={role.slug}>{role.name}</option>
            ))}
          </select>
          <p style={{ fontSize: 12, margin: '0 0 14px' }}>
            These permissions become the defaults for users assigned to this role. Existing user-specific grants and denials are preserved.
          </p>
          <div className="form-group user-permission-section">
            <div className="user-permission-header">
              <div>
                <label className="form-label" style={{ marginBottom: 2 }}>Role Permissions</label>
                <p style={{ fontSize: 12, margin: 0 }}>Common permissions are enabled for every active user.</p>
              </div>
              <span className="permission-summary">{roleEditPermissions.length} selected</span>
            </div>
            <PermissionPicker
              groups={catalog.groups}
              common={catalog.common}
              value={roleEditPermissions}
              onChange={setRoleEditPermissions}
            />
          </div>
        </Modal>
      )}

      {accessTarget && (
        <Modal size="wide" title={`Access: ${accessTarget.full_name || accessTarget.username}`}
          onClose={() => setAccessTarget(null)}
          footer={<>
            <button className="btn btn-ghost" onClick={() => setAccessTarget(null)}>Close</button>
            <button className="btn btn-primary" onClick={saveAccess}
              disabled={accessSaving || accessTarget.id === currentUser?.id}>
              {accessSaving ? 'Saving...' : 'Save Access'}
            </button>
          </>}>
          {accessTarget.id === currentUser?.id && <p>Your own access cannot be changed here.</p>}
          <label className="form-label" htmlFor="access-role">Role</label>
          <select id="access-role" className="form-select" value={accessRole}
            onChange={(event) => {
              setAccessRole(event.target.value);
              setAccessPermissions([...rolePermissions(event.target.value), ...catalog.common]);
            }} style={{ marginBottom: 16 }}>
            {roles.map((role) => <option key={role.slug} value={role.slug}>{role.name}</option>)}
          </select>
          <p style={{ fontSize: 12 }}>These are the user’s effective permissions. Changes here apply only to this user.</p>
          <PermissionPicker groups={catalog.groups} common={catalog.common}
            value={accessPermissions} onChange={setAccessPermissions}
            disabled={accessTarget.id === currentUser?.id} />
        </Modal>
      )}

      {/* Modal for Confirming User Deletion / Deactivation */}
      {deleteTargetUser && (
        <Modal
          title="Confirm User Account Removal"
          onClose={() => setDeleteTargetUser(null)}
          footer={
            <>
              <button
                className="btn btn-ghost"
                onClick={() => setDeleteTargetUser(null)}
                disabled={deleting}
              >
                Cancel
              </button>
              <button
                id="confirm-delete-user-btn"
                className="btn btn-danger"
                onClick={confirmDeleteUser}
                disabled={deleting}
              >
                {deleting ? 'Removing Account...' : 'Confirm Remove Account'}
              </button>
            </>
          }
        >
          <div style={{ padding: '4px 0' }}>
            <p style={{ fontSize: 14, color: 'var(--text-primary)', marginBottom: 16 }}>
              Are you sure you want to remove this user account?
            </p>

            <div style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid var(--border)', borderRadius: 8, padding: 14, marginBottom: 16 }}>
              <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', rowGap: 8, fontSize: 13, alignItems: 'center' }}>
                <span style={{ color: 'var(--text-muted)' }}>Full Name:</span>
                <strong style={{ color: '#fff' }}>{deleteTargetUser.full_name || deleteTargetUser.username}</strong>

                <span style={{ color: 'var(--text-muted)' }}>Employee ID:</span>
                <strong style={{ color: 'var(--accent-blue)', fontFamily: 'monospace' }}>{deleteTargetUser.employee_id || `EMP-${deleteTargetUser.id}`}</strong>

                <span style={{ color: 'var(--text-muted)' }}>Username:</span>
                <strong style={{ color: '#fff', fontFamily: 'monospace' }}>{deleteTargetUser.username}</strong>

                <span style={{ color: 'var(--text-muted)' }}>Role:</span>
                <div>
                  <span className={`badge ${getRoleBadgeClass(deleteTargetUser.role)}`}>
                    {getRoleLabel(deleteTargetUser.role)}
                  </span>
                </div>
              </div>
            </div>

            <div style={{ fontSize: 12, color: 'var(--text-muted)', lineHeight: 1.5, background: 'rgba(59, 130, 246, 0.08)', padding: 12, borderRadius: 6, border: '1px solid rgba(59, 130, 246, 0.2)' }}>
              ℹ️ <strong>System Protection Rule:</strong> If this account has recorded historical inspection or audit logs, the system will safely <strong>deactivate</strong> the account instead of deleting historical inspection records.
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}
