import axios from './axios';

export const getInventoryReceipts = (params = {}) =>
  axios.get('/api/inventory/receipts/', { params });

export const createInventoryReceipt = (data) =>
  axios.post('/api/inventory/receipts/', data);

export const updateInventoryReceipt = (id, data) =>
  axios.patch(`/api/inventory/receipts/${id}/`, data);

export const dispatchInventoryReceipt = (id, quantity) =>
  axios.post(`/api/inventory/receipts/${id}/dispatch/`, { quantity });

export const addIncomingInventory = (id, data) =>
  axios.post(`/api/inventory/receipts/${id}/intake/`, data);
