import api from './axios';

export const getPendingSessions = (plantId) =>
  api.get('/api/inspections/pending/', plantId ? { params: { plant: plantId } } : {});

export const getSessionDetail = (sessionId) =>
  api.get(`/api/inspections/${sessionId}/`);

export const getSessions = (params = {}) =>
  api.get('/api/inspections/', { params });

export const getSetupApprovalData = (templateId, machineId, dateStr) => {
  let url = `/api/inspections/setup-approval/?machine=${machineId}`;
  if (templateId) url += `&template=${templateId}`;
  if (dateStr) url += `&date=${dateStr}`;
  return api.get(url);
};

export const getSetupApprovalOptions = (machineId, dateStr) => {
  const params = new URLSearchParams({ machine: machineId, list: '1' });
  if (dateStr) params.set('date', dateStr);
  return api.get(`/api/inspections/setup-approval/?${params.toString()}`);
};

export const reviewSession = (sessionId, action, remark = '', rejectedParameters = []) =>
  api.post(`/api/inspections/${sessionId}/review/`, {
    action,
    remark,
    rejected_parameters: rejectedParameters,
  });

export const supervisorOverride = (sessionId, parameterCode, value, remark = '') =>
  api.post(`/api/inspections/${sessionId}/supervisor-override/`, {
    parameter_code: parameterCode,
    measured_value: value,
    remark,
  });

export const downloadInspectionPDF = async (sessionId, fileName = '') => {
  const response = await api.get(`/api/inspections/${sessionId}/pdf/`, {
    responseType: 'blob',
  });
  const blob = new Blob([response.data], { type: 'application/pdf' });
  const url = window.URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.setAttribute('download', fileName || `Daily_Report_${sessionId.slice(0, 8)}.pdf`);
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.URL.revokeObjectURL(url);
};

export const openInspectionPDF = async (sessionId) => {
  const response = await api.get(`/api/inspections/${sessionId}/pdf/`, {
    responseType: 'blob',
  });
  const blob = new Blob([response.data], { type: 'application/pdf' });
  const url = window.URL.createObjectURL(blob);
  window.open(url, '_blank');
  setTimeout(() => window.URL.revokeObjectURL(url), 60000); // Clean up memory
};
