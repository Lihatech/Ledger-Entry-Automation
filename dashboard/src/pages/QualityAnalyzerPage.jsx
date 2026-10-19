import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { Cpu, FileText, ArrowRight, ShieldCheck, Clock, Gauge, FileSpreadsheet, LineChart } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { canOpenPath } from '../utils/access';

export default function QualityAnalyzerPage() {
  const navigate = useNavigate();
  const { user } = useAuth();

  const allReportCards = [
    {
      id: 'live-reports',
      title: 'Live Reports',
      badge: 'Live Station Monitoring',
      badgeBg: '#DEF7EC',
      badgeColor: '#03543F',
      icon: Cpu,
      iconBg: '#EBF5FF',
      iconColor: '#1A56DB',
      description:
        'Real-time active station tracking, machine status, operator assignments, and live digital inspection sheets per machine.',
      details: ['Live Machine Station Status', 'Active Operator Tracking', 'Real-Time WebSocket Sync'],
      actionText: 'Open Live Reports',
      link: '/machines',
    },
    {
      id: 'f02-reports',
      title: 'First PC Inspection & In process Reports',
      badge: 'Form F02 Quality Records',
      badgeBg: '#E1EFFE',
      badgeColor: '#1E40AF',
      icon: FileText,
      iconBg: '#F3E8FF',
      iconColor: '#7E22CE',
      description:
        '100% completed daily quality inspection reports, official 19-column Form F02 sheets, supervisor reviews & PDF exports with date-wise naming.',
      details: ['Official Form F02 PDF Downloads', '19-Column Inspection Records', 'Date-Wise Filterable Archive'],
      actionText: 'Open Inspection Reports',
      link: '/analytics',
    },
    {
      id: 'setup-approval-reports',
      title: 'Set Up Approval Report',
      badge: '● Setup Approval Quality Records',
      badgeBg: '#EEF2FF',
      badgeColor: '#4338CA',
      icon: ShieldCheck,
      iconBg: '#EEF2FF',
      iconColor: '#4F46E5',
      description:
        'View and download 100% completed First Piece Setup Approval Reports (Form F02), including Product Quality Parameters & Process Parameters (RPM, Feed Rate, Tooling, Coolant).',
      details: ['Official Setup Approval PDF Exports', 'Product & Process Parameter Logs', 'Date, Machine & Part Archive'],
      actionText: 'Open Setup Approval Reports',
      link: '/reports/setup-approval',
      disabled: false,
    },
    {
      id: 'calibration-hub',
      title: 'Calibration Equipment & Record Hub',
      badge: '● Equipment Calibration & Standards',
      badgeBg: '#FEF3C7',
      badgeColor: '#92400E',
      icon: Gauge,
      iconBg: '#FEF3C7',
      iconColor: '#D97706',
      description:
        'Manage master calibration equipment, equipment master register, preventive calibration schedules, calibration history, and compliance certificates.',
      details: ['Equipment Master Register', 'Calibration Schedule & Plan', 'Audit Trail & Calibration History'],
      actionText: 'Open Calibration Hub',
      link: '/calibration',
      disabled: false,
    },
    {
      id: 'monthly-oee',
      title: 'Monthly OEE Excel Report',
      badge: '● OEE Analytics',
      badgeBg: '#DCFCE7',
      badgeColor: '#166534',
      icon: FileSpreadsheet,
      iconBg: '#DCFCE7',
      iconColor: '#15803D',
      description:
        'Generate and download automated Monthly Overall Equipment Effectiveness (OEE) Excel reports with full parameter tracking.',
      details: ['Dynamic Shift Formatting', 'Downtime & Quality Rates', 'Excel Formulas Built-in'],
      actionText: 'View OEE Report',
      link: '/reports/oee',
      disabled: false,
    },
    {
      id: 'run-chart-reports',
      title: 'Run Chart Reports',
      badge: '● Completed Shift Reports',
      badgeBg: '#DCFCE7',
      badgeColor: '#166534',
      icon: LineChart,
      iconBg: '#ECFDF5',
      iconColor: '#059669',
      description:
        'Review completed critical-parameter run charts with saved readings, machine, part, operation, operator, and shift details.',
      details: ['Saved Graph Readings', 'Shift-Wise Archive', 'Red / Yellow / Green Zones'],
      actionText: 'Open Run Chart Reports',
      link: '/reports/run-chart',
      disabled: false,
    },
  ];

  const reportCards = allReportCards.filter((card) => canOpenPath(user, card.link));

  return (
    <>
      <Header
        title="Reports"
      />

      <div className="page-content bg-gradient-animated" style={{ padding: '24px' }}>
        <div style={{ maxWidth: '1200px', margin: '0 auto' }}>
          <Breadcrumbs items={[{ label: 'Quality Analyzer' }]} />
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))',
              gap: '24px',
            }}
          >
          {reportCards.map((card) => {
            const CardIcon = card.icon;
            const isDisabled = card.disabled || (!card.link && !card.onClick);

            return (
              <div
                key={card.id}
                className="card shadow-hover-elevate transition-all duration-300"
                style={{
                  background: isDisabled ? '#FAFBFD' : '#ffffff',
                  border: '1px solid #E2E8F0',
                  borderRadius: '16px',
                  padding: '24px',
                  opacity: isDisabled ? 0.75 : 1,
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                }}
              >
                <div>
                  {/* Top Badge & Icon */}
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '16px' }}>
                    <div
                      style={{
                        width: '48px',
                        height: '48px',
                        borderRadius: '12px',
                        background: card.iconBg,
                        color: card.iconColor,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                      }}
                    >
                      <CardIcon size={24} />
                    </div>

                    <span
                      style={{
                        background: card.badgeBg,
                        color: card.badgeColor,
                        fontSize: '11px',
                        fontWeight: '700',
                        padding: '4px 10px',
                        borderRadius: '20px',
                        display: 'inline-flex',
                        alignItems: 'center',
                        gap: '6px',
                      }}
                    >
                      <span
                        style={{
                          width: '6px',
                          height: '6px',
                          borderRadius: '50%',
                          background: card.badgeColor,
                        }}
                      />
                      {card.badge}
                    </span>
                  </div>

                  {/* Title */}
                  <h3 style={{ fontSize: '18px', fontWeight: '800', color: '#0F172A', marginBottom: '24px' }}>
                    {card.title}
                  </h3>
                </div>

                {/* Bottom Action Button */}
                <button
                  className="btn btn-primary"
                  disabled={isDisabled}
                  onClick={() => {
                    if (!isDisabled) {
                      if (card.onClick) {
                        card.onClick();
                      } else if (card.link) {
                        navigate(card.link);
                      }
                    }
                  }}
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
                    backgroundColor: isDisabled ? '#94A3B8' : '#EA580C',
                    borderColor: isDisabled ? '#94A3B8' : '#EA580C',
                    color: '#ffffff',
                    cursor: isDisabled ? 'not-allowed' : 'pointer',
                  }}
                >
                  <span>{card.actionText}</span>
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
