/**
 * Document Control API wrapper.
 * Provides endpoints for Categories, Documents (L1-L4), DCR Workflow (DKI/MR/F/05), and Notifications.
 */

import axios from 'axios';

const BASE = import.meta.env.VITE_API_URL || 'http://localhost:8000';

const api = axios.create({ baseURL: `${BASE}/api/document-control` });

// Attach JWT token to every request
api.interceptors.request.use((config) => {
  const token = localStorage.getItem('access_token');
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});


// ── Documents ──────────────────────────────────────────────────────────────
export const getDocuments = (params = {}) => api.get('/documents/', { params });

export const getDocumentById = (id) => api.get(`/documents/${id}/`);

export const uploadDocument = (formData) =>
  api.post('/documents/', formData, {
    headers: { 'Content-Type': 'multipart/form-data' },
  });

export const getDocumentRoles = () => api.get('/documents/roles/');

// ── Per-user document access (new permission matrix) ───────────────────────
// Fetch all org users + their current permissions for a specific document.
// Only callable by the document uploader or an admin.
export const getDocumentAccess = (id) =>
  api.get(`/documents/${id}/access/`);

// Save the full permission matrix for a document in one call.
// permissions: [{ user_id, can_preview, can_download, can_print, can_edit, can_delete }]
export const saveDocumentAccess = (id, permissions) =>
  api.patch(`/documents/${id}/access/`, { permissions });

export const submitForReview = (id, comment = '') =>
  api.post(`/documents/${id}/submit_review/`, { comment });

export const approveDocument = (id, comment = '') =>
  api.post(`/documents/${id}/approve/`, { comment });

export const rejectDocument = (id, comment) =>
  api.post(`/documents/${id}/reject/`, { comment });

export const reviseDocument = (id, formData) =>
  api.post(`/documents/${id}/revise/`, formData, {
    headers: { 'Content-Type': 'multipart/form-data' },
  });

export const getDocumentHistory = (id) => api.get(`/documents/${id}/history/`);

export const getDownloadUrl = (id) => {
  return `${BASE}/api/document-control/documents/${id}/download/`;
};

export const getPreviewUrl = (id) => {
  return `${BASE}/api/document-control/documents/${id}/preview/`;
};

export const downloadDocument = async (id, fallbackName = 'document') => {
  const response = await api.get(`/documents/${id}/download/`, { responseType: 'blob' });
  const disposition = response.headers['content-disposition'] || '';
  const match = disposition.match(/filename\*?=(?:UTF-8''|"?)([^;"\r\n]+)/i);
  const filename = match?.[1] ? decodeURIComponent(match[1].trim()) : fallbackName;
  const blobUrl = URL.createObjectURL(response.data);
  const link = document.createElement('a');
  link.href = blobUrl;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(blobUrl);
};

export const markObsolete = (id, comment = '') =>
  api.post(`/documents/${id}/obsolete/`, { comment });

export const deleteDocument = (id) =>
  api.delete(`/documents/${id}/`);


// ── Document Change Requests (Form DKI/MR/F/05) ────────────────────────────
export const getDCRs = (params = {}) => api.get('/change-requests/', { params });

export const getDCRById = (id) => api.get(`/change-requests/${id}/`);

export const submitDCR = (data) => api.post('/change-requests/', data);

export const submitDCRReview = (id, data) =>
  api.post(`/change-requests/${id}/submit-review/`, data);

export const rejectDCRReview = (id, data) =>
  api.post(`/change-requests/${id}/reject-review/`, data);

export const approveDCR = (id, data = {}) =>
  api.post(`/change-requests/${id}/approve/`, data);

export const rejectDCRApproval = (id, data) =>
  api.post(`/change-requests/${id}/reject-approval/`, data);

export const getDCRPDFUrl = (id) =>
  `${BASE}/api/document-control/change-requests/${id}/pdf/`;

export const getAssignableUsers = () =>
  api.get('/change-requests/assignable-users/');

// ── Realtime DCR Notifications ─────────────────────────────────────────────
export const getNotifications = (params = {}) =>
  api.get('/notifications/', { params });

export const getUnreadNotificationCount = () =>
  api.get('/notifications/unread-count/');

export const markNotificationRead = (id) =>
  api.post(`/notifications/${id}/mark-read/`);

export const markNotificationUnread = (id) =>
  api.post(`/notifications/${id}/mark-unread/`);

export const markAllNotificationsRead = () =>
  api.post('/notifications/mark-all-read/');
