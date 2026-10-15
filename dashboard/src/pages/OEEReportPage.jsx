import React, { useState, useEffect } from 'react';
import { Download, AlertCircle, FileSpreadsheet } from 'lucide-react';
import Header from '../components/layout/Header';
import Breadcrumbs from '../components/layout/Breadcrumbs';
import LoadingSpinner from '../components/common/LoadingSpinner';
import api from '../api/axios';

export default function OEEReportPage() {
  const [machines, setMachines] = useState([]);
  const [loading, setLoading] = useState(true);
  const [fetchingData, setFetchingData] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [error, setError] = useState('');
  
  const today = new Date();
  const [selectedMachine, setSelectedMachine] = useState('');
  const [selectedMonth, setSelectedMonth] = useState(today.getMonth() + 1); // 1-12
  const [selectedYear, setSelectedYear] = useState(today.getFullYear());
  
  const [reportData, setReportData] = useState(null);

  // Fetch Machines
  useEffect(() => {
    const fetchMachines = async () => {
      try {
        const response = await api.get('/api/machines/');
        const data = response.data.results || response.data;
        setMachines(data);
        if (data.length > 0) {
          setSelectedMachine(data[0].machine_code);
        }
      } catch (err) {
        console.error('Failed to fetch machines:', err);
        setError('Failed to load machines.');
      } finally {
        setLoading(false);
      }
    };
    fetchMachines();
  }, []);

  // Fetch Report Data when filters change
  useEffect(() => {
    if (!selectedMachine || !selectedMonth || !selectedYear) return;
    
    const controller = new AbortController();
    
    const fetchReportData = async () => {
      try {
        setFetchingData(true);
        setError('');
        const response = await api.get('/api/analytics/oee-report/data/', {
          params: {
            machine: selectedMachine,
            month: selectedMonth,
            year: selectedYear
          },
          signal: controller.signal
        });
        setReportData(response.data);
      } catch (err) {
        if (err.name === 'CanceledError' || err.code === 'ERR_CANCELED') return;
        console.error('Failed to fetch report data:', err);
        setError('Failed to load OEE report data.');
        setReportData(null);
      } finally {
        if (!controller.signal.aborted) {
          setFetchingData(false);
        }
      }
    };
    
    fetchReportData();
    return () => controller.abort();
  }, [selectedMachine, selectedMonth, selectedYear]);

  const handleDownload = async () => {
    if (!selectedMachine) return;

    try {
      setDownloading(true);
      setError('');
      
      const response = await api.get('/api/analytics/oee-report/export/', {
        params: {
          machine: selectedMachine,
          month: selectedMonth,
          year: selectedYear
        },
        responseType: 'blob',
      });

      const blob = new Blob([response.data], { 
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' 
      });
      
      let filename = `OEE_Report_${selectedMachine}_${selectedYear}_${String(selectedMonth).padStart(2, '0')}.xlsx`;
      const disposition = response.headers['content-disposition'];
      if (disposition && disposition.indexOf('filename=') !== -1) {
        const matches = /filename="([^"]*)"/.exec(disposition);
        if (matches != null && matches[1]) filename = matches[1];
      }

      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', filename);
      document.body.appendChild(link);
      link.click();
      
      link.parentNode.removeChild(link);
      window.URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Download failed:', err);
      setError('Failed to download report Excel file.');
    } finally {
      setDownloading(false);
    }
  };

  const months = [
    { value: 1, label: 'January' }, { value: 2, label: 'February' },
    { value: 3, label: 'March' }, { value: 4, label: 'April' },
    { value: 5, label: 'May' }, { value: 6, label: 'June' },
    { value: 7, label: 'July' }, { value: 8, label: 'August' },
    { value: 9, label: 'September' }, { value: 10, label: 'October' },
    { value: 11, label: 'November' }, { value: 12, label: 'December' }
  ];

  const currentYear = today.getFullYear();
  const years = Array.from({ length: Math.max(3, currentYear - 2024 + 2) }, (_, i) => 2024 + i);

  return (
    <>
      <Header
        title="Monthly OEE Excel Report"
        subtitle="View and download Overall Equipment Effectiveness data by machine and month"
      />

      <div className="page-content" style={{ padding: '24px' }}>
        <div style={{ maxWidth: '1400px', margin: '0 auto' }}>
          
          {/* Breadcrumbs and Action */}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '20px' }}>
            <Breadcrumbs items={[
              { label: 'Quality Analyzer', to: '/quality-analyzer' },
              { label: 'OEE Report' }
            ]} />
            
            <button
              onClick={handleDownload}
              disabled={downloading || !selectedMachine || !reportData || reportData.data.length === 0}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '8px',
                padding: '10px 20px',
                background: (downloading || !selectedMachine || !reportData || reportData.data.length === 0) ? '#9CA3AF' : '#1D4ED8',
                color: 'white',
                border: 'none',
                borderRadius: '8px',
                fontWeight: 600,
                cursor: (downloading || !selectedMachine || !reportData || reportData.data.length === 0) ? 'not-allowed' : 'pointer',
                transition: 'background 0.2s'
              }}
            >
              {downloading ? (
                <>
                  <LoadingSpinner size={16} color="white" />
                  Generating...
                </>
              ) : (
                <>
                  <FileSpreadsheet size={18} />
                  Download Excel
                </>
              )}
            </button>
          </div>

          {/* Filters */}
          <div style={{
            background: 'white',
            borderRadius: '12px',
            padding: '20px',
            border: '1px solid #E5E7EB',
            marginBottom: '24px',
            display: 'flex',
            gap: '24px',
            alignItems: 'flex-end',
            boxShadow: '0 1px 3px 0 rgba(0, 0, 0, 0.1)'
          }}>
            <div style={{ flex: 1, maxWidth: '300px' }}>
              <label style={{ display: 'block', marginBottom: '6px', fontWeight: 600, color: '#374151', fontSize: '14px' }}>
                Machine
              </label>
              {loading ? (
                <div style={{ height: '42px', display: 'flex', alignItems: 'center' }}>
                  <LoadingSpinner size={20} />
                </div>
              ) : (
                <select
                  value={selectedMachine}
                  onChange={(e) => setSelectedMachine(e.target.value)}
                  style={{
                    width: '100%', padding: '10px 12px', borderRadius: '8px',
                    border: '1px solid #D1D5DB', fontSize: '15px', outline: 'none'
                  }}
                >
                  {machines.map(m => (
                    <option key={m.id} value={m.machine_code}>
                      {m.machine_code} {m.name ? `- ${m.name}` : ''}
                    </option>
                  ))}
                </select>
              )}
            </div>

            <div style={{ width: '200px' }}>
              <label style={{ display: 'block', marginBottom: '6px', fontWeight: 600, color: '#374151', fontSize: '14px' }}>
                Month
              </label>
              <select
                value={selectedMonth}
                onChange={(e) => setSelectedMonth(Number(e.target.value))}
                style={{
                  width: '100%', padding: '10px 12px', borderRadius: '8px',
                  border: '1px solid #D1D5DB', fontSize: '15px', outline: 'none'
                }}
              >
                {months.map(m => (
                  <option key={m.value} value={m.value}>{m.label}</option>
                ))}
              </select>
            </div>

            <div style={{ width: '150px' }}>
              <label style={{ display: 'block', marginBottom: '6px', fontWeight: 600, color: '#374151', fontSize: '14px' }}>
                Year
              </label>
              <select
                value={selectedYear}
                onChange={(e) => setSelectedYear(Number(e.target.value))}
                style={{
                  width: '100%', padding: '10px 12px', borderRadius: '8px',
                  border: '1px solid #D1D5DB', fontSize: '15px', outline: 'none'
                }}
              >
                {years.map(y => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
          </div>

          {error && (
            <div style={{ 
              display: 'flex', alignItems: 'center', gap: '8px', 
              background: '#FEF2F2', color: '#B91C1C', 
              padding: '12px', borderRadius: '8px', marginBottom: '20px',
              fontSize: '14px'
            }}>
              <AlertCircle size={18} />
              <span>{error}</span>
            </div>
          )}

          {/* Data Table Area */}
          <div style={{
            background: 'white',
            borderRadius: '12px',
            border: '1px solid #E5E7EB',
            overflow: 'hidden',
            boxShadow: '0 1px 3px 0 rgba(0, 0, 0, 0.1)'
          }}>
            {fetchingData ? (
              <div style={{ padding: '60px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '16px' }}>
                <LoadingSpinner size={32} />
                <span style={{ color: '#6B7280', fontSize: '14px' }}>Loading OEE data...</span>
              </div>
            ) : !reportData || reportData.data.length === 0 ? (
              <div style={{ padding: '60px', textAlign: 'center', color: '#6B7280' }}>
                <FileSpreadsheet size={48} style={{ margin: '0 auto', marginBottom: '16px', opacity: 0.2 }} />
                <p>No production records found for {months.find(m => m.value === selectedMonth)?.label} {selectedYear}.</p>
              </div>
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '13px', whiteSpace: 'nowrap' }}>
                  <thead>
                    <tr style={{ background: '#F9FAFB', borderBottom: '1px solid #E5E7EB', color: '#374151' }}>
                      <th style={{ padding: '12px 16px', textAlign: 'left', fontWeight: 600 }}>Date</th>
                      <th style={{ padding: '12px 16px', textAlign: 'left', fontWeight: 600 }}>Shift</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB' }}>Avail. Time<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>Planned DT<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>Net Avail.<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB' }}>DT Losses<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>ST</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>NL</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>NO</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>MM</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>OW</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>PF</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB' }}>Op. Time<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB', color: '#047857' }}>Availability</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB' }}>Total Qty</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600 }}>Cycle Time<br/>(mins)</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB', color: '#047857' }}>Performance</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB' }}>Rejection</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 600, borderLeft: '1px solid #E5E7EB', color: '#047857' }}>Quality Rate</th>
                      <th style={{ padding: '12px 16px', textAlign: 'right', fontWeight: 700, borderLeft: '1px solid #E5E7EB', color: '#1D4ED8', background: '#EFF6FF' }}>O.E.E</th>
                    </tr>
                  </thead>
                  <tbody>
                    {reportData.data.map((row, idx, arr) => {
                      const isFirstOfDay = idx === 0 || arr[idx - 1].date !== row.date;
                      const shiftsForDay = arr.filter(r => r.date === row.date).length;
                      
                      return (
                      <tr key={idx} style={{ borderBottom: '1px solid #E5E7EB', background: idx % 2 === 0 ? 'white' : '#F9FAFB' }}>
                        {isFirstOfDay && (
                          <td 
                            rowSpan={shiftsForDay} 
                            style={{ 
                              padding: '10px 16px', 
                              color: '#111827', 
                              verticalAlign: 'middle',
                              borderRight: '1px solid #E5E7EB',
                              background: '#ffffff'
                            }}
                          >
                            {row.date}
                          </td>
                        )}
                        <td style={{ padding: '10px 16px', color: '#4B5563' }}>{row.shift}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB' }}>{row.available_time}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right' }}>{row.planned_downtime}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right' }}>{row.net_available}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB' }}>{row.downtime_losses}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.st || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.nl || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.no || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.mm || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.ow || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', color: '#6B7280' }}>{row.downtimes?.pf || 0}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB' }}>{row.operating_time}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB', fontWeight: 500 }}>{row.availability}%</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB' }}>{row.total_qty}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right' }}>{row.cycle_time}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB', fontWeight: 500 }}>{row.performance}%</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB' }}>{row.rejection}</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB', fontWeight: 500 }}>{row.quality_rate}%</td>
                        <td style={{ padding: '10px 16px', textAlign: 'right', borderLeft: '1px solid #E5E7EB', fontWeight: 700, color: '#1D4ED8', background: '#EFF6FF' }}>{row.oee}%</td>
                      </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}
