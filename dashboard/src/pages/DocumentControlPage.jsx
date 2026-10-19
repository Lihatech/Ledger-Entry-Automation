import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  FolderOpen,
  FileText,
  ClipboardCheck,
  Tag,
  ArrowRight,
  Clock,
  CheckCircle,
  Edit3,
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { canOpenPath } from '../utils/access';
import { getDocuments, getDCRs } from '../api/documentControl';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';

export default function DocumentControlPage() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const isAdmin = canOpenPath(user, '/document-control/approvals');

  const [stats, setStats] = useState({ total: 0, approved: 0, pending: 0, pendingDcr: 0 });

  useEffect(() => {
    Promise.all([
      getDocuments({ status: 'approved' }).catch(() => ({ data: [] })),
      getDocuments({ status: 'under_review' }).catch(() => ({ data: [] })),
      getDocuments().catch(() => ({ data: [] })),
      getDCRs({ tab: 'action_required' }).catch(() => ({ data: [] })),
    ]).then(([approved, pending, all, dcrRes]) => {
      const getLen = (res) => (Array.isArray(res.data) ? res.data.length : (res.data?.results?.length ?? 0));
      setStats({
        total:      getLen(all),
        approved:   getLen(approved),
        pending:    getLen(pending),
        pendingDcr: getLen(dcrRes),
      });
    });
  }, []);

  const moduleCards = [
    {
      title: 'Document Register (L1 : L4)',
      icon: FolderOpen,
      iconBg: '#EEF2FF',
      iconColor: '#4F46E5',
      to: '/document-control/documents',
      badge: '• L1 : L4 Hierarchy',
      badgeBg: '#EEF2FF',
      badgeColor: '#4338CA',
      primary: true,
      actionText: 'Open Document Library',
      showAlways: true,
    },
    {
      title: 'Change Requests (DCR)',
      icon: Edit3,
      iconBg: '#ECFDF5',
      iconColor: '#059669',
      to: '/document-control/dcr',
      badge: stats.pendingDcr > 0 ? `• ${stats.pendingDcr} Action Required` : '• DKI/MR/F/05',
      badgeBg: stats.pendingDcr > 0 ? '#FEF3C7' : '#ECFDF5',
      badgeColor: stats.pendingDcr > 0 ? '#B45309' : '#059669',
      primary: false,
      actionText: 'Manage Change Requests',
      showAlways: true,
    },
    {
      title: 'Direct Approvals Queue',
      icon: ClipboardCheck,
      iconBg: '#FFFBEB',
      iconColor: '#D97706',
      to: '/document-control/approvals',
      badge: `• ${stats.pending} Pending`,
      badgeBg: '#FEF3C7',
      badgeColor: '#D97706',
      primary: false,
      actionText: 'Review Pending Approvals',
      showAlways: false,
      adminOnly: true,
    },
  ];

  const visibleCards = moduleCards.filter((card) => canOpenPath(user, card.to));

  const statItems = [
    { label: 'Total Documents', value: stats.total, icon: FileText, color: '#4f46e5', bg: 'rgba(99,102,241,0.1)' },
    { label: 'Approved & Active', value: stats.approved, icon: CheckCircle, color: '#10b981', bg: 'rgba(16,185,129,0.1)' },
    { label: 'Pending DCR Actions', value: stats.pendingDcr, icon: Clock, color: '#f59e0b', bg: 'rgba(245,158,11,0.1)' },
    { label: 'Document Categories', value: stats.categories, icon: Tag, color: '#8b5cf6', bg: 'rgba(139,92,246,0.1)' },
  ];

  return (
    <>
      <Header
        title="Document Control Management"
      />

      <div className="page-content bg-gradient-animated">
        <div style={{ maxWidth: '1400px', margin: '0 auto' }}>

      {/* Module Cards */}
      <div style={{
        display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))',
        gap: '24px', marginBottom: '40px'
      }}>
        {visibleCards.map((c, i) => {
          const Icon = c.icon;
          return (
            <div
              key={i}
              className="card shadow-hover-elevate transition-all duration-300"
              style={{
                borderRadius: '16px',
                padding: '24px',
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'space-between',
                border: '1px solid #E2E8F0',
                backgroundColor: '#ffffff',
              }}
            >
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '16px' }}>
                  <div style={{
                    background: c.iconBg, borderRadius: '12px', width: '48px', height: '48px',
                    display: 'flex', alignItems: 'center', justifyContent: 'center'
                  }}>
                    <Icon size={24} color={c.iconColor} />
                  </div>
                  <span style={{
                    background: c.badgeBg, color: c.badgeColor, fontSize: '11px',
                    fontWeight: '700', padding: '4px 10px', borderRadius: '20px'
                  }}>
                    {c.badge}
                  </span>
                </div>
                <h3 style={{ fontSize: '18px', fontWeight: '800', color: '#0F172A', marginBottom: '24px' }}>
                  {c.title}
                </h3>
              </div>

              <button
                className="btn btn-primary"
                onClick={() => navigate(c.to)}
                style={{
                  width: '100%',
                  padding: '12px 16px',
                  borderRadius: '10px',
                  fontSize: '13px',
                  fontWeight: '700',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  gap: '8px',
                  backgroundColor: '#EA580C',
                  borderColor: '#EA580C',
                  color: '#ffffff',
                  cursor: 'pointer',
                }}
              >
                <span>{c.actionText}</span>
                <ArrowRight size={16} />
              </button>
            </div>
          );
        })}
      </div>
      </div>
      </div>
    </>
  );
}
