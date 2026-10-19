import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Sliders,
  ArrowRight,
} from 'lucide-react';
import { getParts } from '../api/parts';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';

export default function MasterDatabasePage() {
  const navigate = useNavigate();
  const [partsCount, setPartsCount] = useState(null);
  const [fetchError, setFetchError] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getParts()
      .then((res) => {
        const parts = Array.isArray(res.data) ? res.data : (res.data?.results || []);
        setPartsCount(parts.length);
        setFetchError(false);
      })
      .catch(() => {
        setFetchError(true);
        setPartsCount(null);
      })
      .finally(() => {
        setLoading(false);
      });
  }, []);

  const getBadgeInfo = () => {
    if (loading) {
      return {
        text: '• Loading...',
        bg: '#F1F5F9',
        color: '#64748B',
      };
    }
    if (fetchError) {
      return {
        text: '• Status Unavailable',
        bg: '#FEF2F2',
        color: '#DC2626',
      };
    }
    if (typeof partsCount === 'number') {
      return {
        text: `• ${partsCount} Active Parts`,
        bg: '#FFF7ED',
        color: '#C2410C',
      };
    }
    return {
      text: '• Active Database',
      bg: '#FFF7ED',
      color: '#C2410C',
    };
  };

  const badgeInfo = getBadgeInfo();

  const masterCards = [
    {
      id: 'master-parameters',
      title: 'Master Parameters',
      icon: Sliders,
      iconBg: '#FFF7ED',
      iconColor: '#EA580C',
      to: '/parameters',
      badge: badgeInfo.text,
      badgeBg: badgeInfo.bg,
      badgeColor: badgeInfo.color,
      actionText: 'Open Master Parameters',
    },
  ];

  return (
    <>
      <Header
        title="Master Database"
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
          <Breadcrumbs items={[{ label: 'Master Database' }]} />

          {/* Feature Cards Grid */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(360px, 1fr))',
              gap: '24px',
            }}
          >
            {masterCards.map((card) => {
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
