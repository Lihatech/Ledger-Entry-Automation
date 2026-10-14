import axios from './axios';

export const getInventoryReceipts = (params = {}) =>
  axios.get('/api/inventory/receipts/', { params });

export const getAllInventoryReceipts = async (params = {}) => {
  let response = await getInventoryReceipts(params);
  const rows = Array.isArray(response.data) ? [...response.data] : [...(response.data?.results || [])];
  let next = response.data?.next;
  while (next) {
    response = await axios.get(next);
    if (Array.isArray(response.data)) rows.push(...response.data);
    else rows.push(...(response.data?.results || []));
    next = response.data?.next;
  }
  return rows;
};

export const createInventoryReceipt = (data) =>
  axios.post('/api/inventory/receipts/', data);

export const updateInventoryReceipt = (id, data) =>
  axios.patch(`/api/inventory/receipts/${id}/`, data);

export const dispatchInventoryReceipt = (id, quantity, idempotencyKey) =>
  axios.post(`/api/inventory/receipts/${id}/dispatch/`, { quantity, idempotency_key: idempotencyKey });

export const addIncomingInventory = (id, data) =>
  axios.post(`/api/inventory/receipts/${id}/intake/`, data);
