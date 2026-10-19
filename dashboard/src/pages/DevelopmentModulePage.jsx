import React from 'react';
import { useNavigate } from 'react-router-dom';
import { 
  FileCode, 
  ArrowRight,
  FileSpreadsheet
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { canOpenPath } from '../utils/access';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';

export default function DevelopmentModulePage() {
  const navigate = useNavigate();
  const { user } = useAuth();

  const cards = [
    {
      title: 'Drawing Management',
      icon: FileCode,
      iconBg: '#EEF2FF',
      iconColor: '#4F46E5',
      to: '/development/drawings',
      badge: '• Engineering Drawings',
      badgeBg: '#EEF2FF',
      badgeColor: '#4338CA',
      actionText: 'Open Drawing Management',
    },
    {
      title: 'Control Plan Management',
      icon: FileSpreadsheet,
      iconBg: '#ECFDF5',
      iconColor: '#059669',
      to: '/development/control-plans',
      badge: '• Process Control',
      badgeBg: '#ECFDF5',
      badgeColor: '#047857',
      actionText: 'Open Control Plan Management',
    },
  ];

  const visibleCards = cards.filter((card) => canOpenPath(user, card.to));
  return (
    <>
      <Header
        title="Development"
      />

      <div
        className="page-content bg-gradient-animated"
        style={{
          padding: '28px',
          background: '#F8FAFC',
          minHeight: '100vh',
        }}
      >
        <div style={{ maxWidth: '1400px', margin: '0 auto' }}>
          <Breadcrumbs items={[{ label: 'Development' }]} />

          {/* Feature Cards Grid */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(360px, 1fr))',
              gap: '24px',
            }}
          >
            {visibleCards.map((card, idx) => {
              const IconComponent = card.icon;
              return (
                <div
                  key={idx}
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
                    {/* Top Icon & Badge */}
                    <div
                      style={{
                        display: 'flex',
                        justifyContent: 'space-between',
                        alignItems: 'flex-start',
                        marginBottom: '16px',
                      }}
                    >
                      <div
                        style={{
                          width: '48px',
                          height: '48px',
                          borderRadius: '12px',
                          backgroundColor: card.iconBg,
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          color: card.iconColor,
                        }}
                      >
                        <IconComponent size={24} />
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
                    <h3
                      style={{
                        fontSize: '18px',
                        fontWeight: '800',
                        color: '#0F172A',
                        marginBottom: '24px',
                      }}
                    >
                      {card.title}
                    </h3>
                  </div>

                  {/* Action Button */}
                  <button
                    className="btn btn-primary"
                    onClick={() => navigate(card.to)}
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
