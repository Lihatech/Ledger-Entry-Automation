import { NavLink, useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../../context/AuthContext';
import { useCompany } from '../../context/CompanyContext';
import { canOpenPath } from '../../utils/access';
import { useState, useEffect } from 'react';
import CompanyDetailsModal from '../common/CompanyDetailsModal';
import {
  Database,
  ShieldCheck,
  Layers,
  Users,
  Sliders,
  Factory,
  LogOut,
  ChevronDown,
  ChevronRight,
  CheckSquare,
  ShoppingCart,
  Wrench,
  Cpu,
  TrendingUp,
  BarChart3,
  Package,
  MessageSquare,
  FolderOpen,
  PanelLeftClose,
  PanelLeftOpen,
} from 'lucide-react';

const MODULES = [
  {
    key: 'hr',
    label: 'HR',
    icon: Users,
    to: '/users',
    items: [],
  },
  {
    key: 'production_old',
    label: 'Production Module',
    icon: Layers,
    to: '/production',
    items: [],
  },
  {
    key: 'quality_analyzer',
    label: 'Quality Analyzer',
    icon: BarChart3,
    to: '/quality-analyzer',
    items: [],
  },
  {
    key: 'tasks',
    label: 'Tasks Management',
    icon: CheckSquare,
    to: '/tasks',
    items: [],
  },
  {
    key: 'messages',
    label: 'Messages',
    icon: MessageSquare,
    to: '/messages',
    items: [],
  },

  // Master Database Module
  {
    key: 'master_database',
    label: 'Master Database',
    icon: Database,
    to: '/master-database',
    items: [
      {
        label: 'Master Parameters',
        to: '/parameters',
        icon: Sliders,
      },
    ],
  },

  // Enterprise Modules
  {
    key: 'purchase',
    label: 'Purchase',
    icon: ShoppingCart,
    to: '/purchase',
    items: [],
  },
  {
    key: 'inventory',
    label: 'Inventory Management',
    icon: Package,
    to: '/inventory',
    items: [],
  },
  {
    key: 'maintenance',
    label: 'Maintenance',
    icon: Wrench,
    to: '/maintenance',
    items: [],
  },
  {
    key: 'development',
    label: 'Development',
    icon: Cpu,
    to: '/development',
    items: [],
  },
  {
    key: 'marketing',
    label: 'Marketing',
    icon: TrendingUp,
    to: '/marketing',
    items: [],
  },
  {
    key: 'document_control',
    label: 'Document Control',
    icon: FolderOpen,
    to: '/document-control',
    items: [
      { label: 'Documents (L1 : L4)', to: '/document-control/documents' },
      { label: 'Change Requests (DCR)', to: '/document-control/dcr' },
      { label: 'Approvals Queue', to: '/document-control/approvals' },
    ],
  }
];

export default function Sidebar({ pendingCount = 0, collapsed = false, onToggle }) {
  const { user, logout } = useAuth();
  const { logoUrl } = useCompany() || {};
  const navigate = useNavigate();
  const location = useLocation();
  const [loggingOut, setLoggingOut] = useState(false);
  const [showCompanyModal, setShowCompanyModal] = useState(false);

  // Initialize expanded state: expand module that contains current active route, or master_database by default
  const [expanded, setExpanded] = useState(() => {
    const activeMod = MODULES.find((m) => m.items && m.items.some((item) => item.to === location.pathname));
    return activeMod ? { [activeMod.key]: true } : { master_database: true };
  });

  // Automatically expand module when route changes
  useEffect(() => {
    const activeMod = MODULES.find((m) => m.items && m.items.some((item) => item.to === location.pathname));
    if (activeMod) {
      setExpanded((prev) => ({ ...prev, [activeMod.key]: true }));
    }
  }, [location.pathname]);

  const toggleModule = (key) => {
    setExpanded((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  const handleLogout = async () => {
    setLoggingOut(true);
    await logout();
    navigate('/login');
  };

  const initials = user
    ? `${user.first_name?.[0] ?? ''}${user.last_name?.[0] ?? ''}`.toUpperCase() || user.username?.[0]?.toUpperCase()
    : '?';
  const visibleModules = MODULES
    .filter((module) => canOpenPath(user, module.to))
    .map((module) => ({
      ...module,
      items: (module.items || []).filter((item) => canOpenPath(user, item.to)),
    }));

  return (
    <aside className={`sidebar${collapsed ? ' collapsed' : ''}`}>
      {/* Brand Logo -> Open Company Details Modal (Popup Only, No Navigation) */}
      <button
        type="button"
        className="sidebar-logo"
        title="View Company Details"
        onClick={() => setShowCompanyModal(true)}
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: '100%',
          padding: '16px 20px',
          border: 'none',
          borderBottom: '1px solid #1e293b',
          background: 'transparent',
          cursor: 'pointer',
          transition: 'background 0.2s ease',
        }}
        onMouseEnter={(e) => { e.currentTarget.style.background = 'rgba(255, 255, 255, 0.04)'; }}
        onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; }}
      >
        <div
          className="sidebar-logo-icon"
          style={{
            width: '40px',
            height: '40px',
            overflow: 'hidden',
            padding: 0,
            background: 'transparent',
            boxShadow: '0 2px 10px rgba(0,0,0,0.3)',
            borderRadius: '10px',
            transition: 'transform 0.18s ease',
          }}
        >
          <img
            src={logoUrl || "/apple-touch-icon.png"}
            alt="Inspection Hub Logo"
            style={{ width: '100%', height: '100%', borderRadius: 'inherit', objectFit: 'contain' }}
            onError={(e) => { e.target.src = "/apple-touch-icon.png"; }}
          />
        </div>
      </button>

      {/* Nav */}
      <nav className="sidebar-nav">
        {visibleModules.map((m) => {
          const module = m;
          const ModuleIcon = module.icon;

          if (module.to) {
            const isChildActive = module.items && module.items.some((item) => item.to === location.pathname);
            const isMasterParamActive = module.key === 'master_database' && location.pathname.startsWith('/parameters');
            const isProductionActive = module.key === 'production_old' && location.pathname.startsWith('/production');
            const isQAActive = module.key === 'quality_analyzer' && (location.pathname.startsWith('/machines') || location.pathname.startsWith('/analytics') || location.pathname.startsWith('/calibration') || location.pathname.startsWith('/reports/setup-approval') || location.pathname.startsWith('/reports/run-chart') || location.pathname.startsWith('/reports/oee'));
            return (
              <div key={module.key} className="sidebar-module">
                <NavLink
                  to={module.to}
                  title={module.label}
                  className={({ isActive }) => `nav-item${isActive || isChildActive || isMasterParamActive || isProductionActive || isQAActive ? ' active' : ''}`}
                >
                  <span className="module-icon">
                    <ModuleIcon size={16} />
                  </span>
                  <span className="module-label">{module.label}</span>
                </NavLink>
              </div>
            );
          }

          const isExpanded = !!expanded[module.key];
          const hasActiveChild = module.items && module.items.some((item) => item.to === location.pathname);

          return (
            <div key={module.key} className={`sidebar-module${hasActiveChild ? ' has-active' : ''}`}>
              <button
                type="button"
                title={module.label}
                className={`sidebar-module-header${isExpanded ? ' expanded' : ''}`}
                onClick={() => toggleModule(module.key)}
              >
                <span className="module-icon">
                  <ModuleIcon size={16} />
                </span>
                <span className="module-title">{module.label}</span>
                <span className="module-chevron">
                  {isExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                </span>
              </button>

              {isExpanded && (
                <div className="sidebar-submodules">
                  {module.items && module.items.length > 0 ? (
                    module.items.map((item) => {
                      const ItemIcon = item.icon;
                      return (
                        <NavLink
                          key={item.to}
                          to={item.to}
                          title={item.label}
                          end={item.to === '/'}
                          className={({ isActive }) => `nav-item${isActive ? ' active' : ''}`}
                        >
                          {ItemIcon && <span className="module-icon"><ItemIcon size={16} /></span>}
                          <span className="module-label" style={{ flex: 1 }}>{item.label}</span>
                          {item.badgeKey === 'pending' && pendingCount > 0 && (
                            <span className="nav-badge">{pendingCount}</span>
                          )}
                        </NavLink>
                      );
                    })
                  ) : (
                    <div className="sidebar-empty-item">
                      <span style={{ opacity: 0.5, fontSize: '0.75rem', fontStyle: 'italic', paddingLeft: '8px' }}>
                        (Empty)
                      </span>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </nav>

      <button
        type="button"
        className="sidebar-toggle"
        onClick={onToggle}
        aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
        title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
      >
        {collapsed ? <PanelLeftOpen size={17} /> : <PanelLeftClose size={17} />}
        <span className="module-label">{collapsed ? 'Expand navigation' : 'Collapse navigation'}</span>
      </button>

      {/* User footer */}
      <div className="sidebar-footer">
        <NavLink
          to="/profile"
          style={({ isActive }) => ({
            display: 'block',
            textDecoration: 'none',
            borderRadius: 10,
            border: isActive ? '1px solid rgba(29,78,216,0.25)' : '1px solid transparent',
            background: isActive ? 'rgba(29,78,216,0.06)' : 'transparent',
            transition: 'all 0.18s ease',
          })}
          onMouseEnter={e => {
            if (!e.currentTarget.classList.contains('active-profile')) {
              e.currentTarget.style.background = 'rgba(15,23,42,0.04)';
              e.currentTarget.style.borderColor = 'rgba(0,0,0,0.07)';
            }
          }}
          onMouseLeave={e => {
            if (!e.currentTarget.style.borderColor.includes('29,78,216')) {
              e.currentTarget.style.background = 'transparent';
              e.currentTarget.style.borderColor = 'transparent';
            }
          }}
        >
          <div className="user-pill">
            <div className="user-avatar" style={{ overflow: 'hidden', padding: 0 }}>
              {user?.profile_photo_url
                ? <img src={user.profile_photo_url} alt="Profile" style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '50%' }} />
                : initials
              }
            </div>
            <div className="user-info" style={{ flex: 1, minWidth: 0 }}>
              <div
                className="sidebar-user-name"
                style={{
                  color: '#ffffff',
                  fontWeight: 700,
                  fontSize: '0.84rem',
                  lineHeight: 1.2,
                  whiteSpace: 'nowrap',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                }}
              >
                {user ? `${user.first_name} ${user.last_name}`.trim() || user.username : '-'}
              </div>
              <div
                className="sidebar-user-role"
                style={{
                  color: '#94a3b8',
                  fontSize: '0.72rem',
                  fontWeight: 500,
                  textTransform: 'capitalize',
                  marginTop: '2px',
                }}
              >
                {user?.role_name ?? user?.role ?? 'User'}
              </div>
            </div>
            <button
              id="sidebar-logout"
              className="sidebar-logout-btn"
              onClick={(e) => { e.preventDefault(); handleLogout(); }}
              disabled={loggingOut}
              style={{
                background: 'rgba(255, 255, 255, 0.08)',
                border: '1px solid rgba(255, 255, 255, 0.12)',
                color: '#cbd5e1',
                borderRadius: '6px',
                padding: '6px 8px',
                flexShrink: 0,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                cursor: 'pointer',
              }}
              title="Log out"
            >
              <LogOut size={15} />
            </button>
          </div>
        </NavLink>
      </div>

      {showCompanyModal && (
        <CompanyDetailsModal onClose={() => setShowCompanyModal(false)} />
      )}
    </aside>
  );
}
