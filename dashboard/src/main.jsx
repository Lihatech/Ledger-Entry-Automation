import React from 'react';
import ReactDOM from 'react-dom/client';
import * as Sentry from '@sentry/react';
import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './context/AuthContext';
import { CompanyProvider } from './context/CompanyContext';
import App from './App';
import './index.css';

const sentryDsn = import.meta.env.VITE_SENTRY_DSN;
if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    integrations: [Sentry.browserTracingIntegration()],
    tracesSampleRate: 0.1,
    environment: import.meta.env.MODE,
  });
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <CompanyProvider>
          <App />
        </CompanyProvider>
      </AuthProvider>
    </BrowserRouter>
  </React.StrictMode>
);
