import api from './axios';

// Get list of factories (Company details)
export const getCompanyDetails = async () => {
  const res = await api.get('/api/machines/factories/');
  return res;
};

// Create a new factory/company record
export const createCompanyDetails = async (data) => {
  const res = await api.post('/api/machines/factories/', data);
  return res;
};

// Update primary factory/company details
export const updateCompanyDetails = async (id, data) => {
  const res = await api.patch(`/api/machines/factories/${id}/`, data);
  return res;
};

// Upload company logo file (multipart/form-data)
export const uploadCompanyLogo = async (id, file) => {
  const formData = new FormData();
  formData.append('logo', file);
  const res = await api.post(`/api/machines/factories/${id}/upload-logo/`, formData, {
    headers: { 'Content-Type': 'multipart/form-data' },
  });
  return res;
};

// Remove company logo
export const removeCompanyLogo = async (id) => {
  const res = await api.delete(`/api/machines/factories/${id}/upload-logo/`);
  return res;
};

// Get connected plants overview
export const getCompanyPlants = async () => {
  const res = await api.get('/api/machines/plants/');
  return res;
};

export const createCompanyPlant = async (data) => {
  const res = await api.post('/api/machines/plants/', data);
  return res;
};
