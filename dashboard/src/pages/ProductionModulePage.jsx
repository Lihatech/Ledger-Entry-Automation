import React from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { canOpenPath } from '../utils/access';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import { BarChart3, ArrowRight, Clock, ClipboardCheck } from 'lucide-react';

export default function ProductionModulePage() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const productionCards = [
    {
      id: 'daily-production-reports',
      title: 'Daily Production Reports',
      badge: '● End of Day Output & Rejections',
      badgeBg: '#FFF7ED',
      badgeColor: '#C2410C',
      icon: BarChart3,
      iconBg: '#FFF7ED',
      iconColor: '#EA580C',
      description:
        'End-of-day shift production targets, completed jobs, correct vs incorrect counts, rejection breakup (CR, MR, RW), achievement %, and supervisor filters.',
      details: ['End of Day Shift Production Logs', 'Target vs Actual Achievement %', 'CR / MR / RW Rejection Breakup'],
      actionText: 'Open Daily Production Reports',
      link: '/production/daily-production',
    },
    {
      id: 'downtime-reports',
      title: 'Downtime Reports',
      badge: '● Machine Delays & Downtime Minutes',
      badgeBg: '#E0F2FE',
      badgeColor: '#0369A1',
      icon: Clock,
      iconBg: '#E0F2FE',
      iconColor: '#0284C7',
      description:
        'Log shift downtime minutes (No Load, No Operator, U/M, Setting, Insp Wait, Tool Change, P/O, R/W, Tool Prob) automatically linked to submitted Daily Production Reports.',
      details: ['Operator & Machine Downtime Log', '9-Category Downtime Minutes Breakdown', 'Form QF/MF-06 Hanuman Engineering Format'],
      actionText: 'Open Downtime Reports',
      link: '/production/downtime?view=full',
    },
    {
      id: 'jh-inspections',
      title: 'JH Inspection Reports',
      badge: '● Autonomous Maintenance & 31-Day Shift Matrix',
      badgeBg: '#F0FDF4',
      badgeColor: '#15803D',
      icon: ClipboardCheck,
      iconBg: '#DCFCE7',
      iconColor: '#16A34A',
      description:
        'Track daily Autonomous Maintenance (Jishu Hozen) checklists, 31-day shift compliance matrix (Shifts I, II, III), and abnormal item logs (Form QF/MF-08).',
      details: ['Autonomous Maintenance Shift Audits', '31-Day Shift I, II, III Compliance Matrix', 'Not OK & Immediate Correction Log'],
      actionText: 'Open JH Inspection Reports',
      link: '/production/jh-inspections',
    },
  ];

  return (
    <>
      <Header
        title="Production Module"
      />

      <div className="page-content bg-gradient-animated" style={{ padding: '28px', background: '#F8FAFC', minHeight: '100vh' }}>
        <Breadcrumbs items={[{ label: 'Production' }]} />

        {/* Feature Cards Grid */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(360px, 1fr))', gap: '24px' }}>
          {productionCards.filter((card) => canOpenPath(user, card.link.split('?')[0])).map((card) => {
            const IconComponent = card.icon;
            return (
              <div
                key={card.id}
                className="card shadow-hover-elevate transition-all duration-300"
                style={{
                  borderRadius: '16px',
                  padding: '24px',
                  display: 'flex',
                  flexDirection: 'column',
                  justify: 'space-between',
                  border: '1px solid #E2E8F0',
                  backgroundColor: '#ffffff',
                }}
              >
                <div>
                  {/* Top Icon & Badge */}
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '16px' }}>
                    <div
                      style={{
                        width: '48px',
                        height: '48px',
                        flex: '0 0 48px',
                        borderRadius: '12px',
                        backgroundColor: card.iconBg,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        color: card.iconColor,
                        lineHeight: 0,
                      }}
                    >
                      <IconComponent size={24} style={{ display: 'block' }} />
                    </div>
                    <span
                      style={{
                        fontSize: '11px',
                        fontWeight: '700',
                        padding: '4px 10px',
                        borderRadius: '20px',
                        backgroundColor: card.badgeBg,
                        color: card.badgeColor,
                      }}
                    >
                      {card.badge}
                    </span>
                  </div>

                  {/* Title */}
                  <h3 style={{ fontSize: '18px', fontWeight: '800', color: '#0F172A', marginBottom: '24px' }}>
                    {card.title}
                  </h3>
                </div>

                {/* Action Button */}
                <button
                  className="btn btn-primary"
                  onClick={() => navigate(card.link)}
                  style={{
                    width: '100%',
                    padding: '12px 16px',
                    borderRadius: '10px',
                    fontSize: '13px',
                    fontWeight: '700',
                    display: 'flex',
                    alignItems: 'center',
                    justify: 'center',
                    gap: '8px',
                    backgroundColor: '#EA580C',
                    borderColor: '#EA580C',
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
    </>
  );
}
