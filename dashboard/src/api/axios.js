import axios from 'axios';
import * as Sentry from '@sentry/react';

export const BASE_URL = (import.meta.env.VITE_API_URL || 'https://ledger-entry-backend.onrender.com').replace(/\/api\/?$/, '').replace(/\/$/, '');

const api = axios.create({
  baseURL: BASE_URL,
  headers: { 'Content-Type': 'application/json' },
});

// ── Request interceptor : attach JWT ────────────────────────
api.interceptors.request.use((config) => {
  const token = localStorage.getItem('access_token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

let isRefreshing = false;
let failedQueue = [];

const processQueue = (error, token = null) => {
  failedQueue.forEach((prom) => {
    if (error) {
      prom.reject(error);
    } else {
      prom.resolve(token);
    }
  });
  failedQueue = [];
};

// ── Response interceptor : auto-refresh on 401 ──────────────
api.interceptors.response.use(
  (response) => response,
  async (error) => {
    const original = error.config;
    if (error.response?.status !== 401) {
      Sentry.captureException(error, {
        extra: {
          request_url: original?.url,
          request_method: original?.method,
          response_status: error.response?.status,
          response_data: error.response?.data,
        },
      });
    }
    if (error.response?.status === 401 && !original._retry) {
      if (isRefreshing) {
        return new Promise((resolve, reject) => {
          failedQueue.push({ resolve, reject });
        })
          .then((token) => {
            original.headers.Authorization = `Bearer ${token}`;
            return api(original);
          })
          .catch((err) => Promise.reject(err));
      }

      original._retry = true;
      isRefreshing = true;

      const refresh = localStorage.getItem('refresh_token');
      if (refresh) {
        try {
          const res = await axios.post(`${BASE_URL}/api/users/token/refresh/`, {
            refresh,
          });
          const { access, refresh: newRefresh } = res.data;
          localStorage.setItem('access_token', access);
          if (newRefresh) {
            localStorage.setItem('refresh_token', newRefresh);
          }
          original.headers.Authorization = `Bearer ${access}`;
          processQueue(null, access);
          return api(original);
        } catch (refreshErr) {
          processQueue(refreshErr, null);
          localStorage.clear();
          if (window.location.pathname !== '/login') {
            window.location.href = '/login';
          }
          return Promise.reject(refreshErr);
        } finally {
          isRefreshing = false;
        }
      } else {
        localStorage.clear();
        if (window.location.pathname !== '/login') {
          window.location.href = '/login';
        }
      }
    }
    return Promise.reject(error);
  }
);

export const WS_BASE_URL = BASE_URL.replace(/^http/, 'ws');
export default api;
