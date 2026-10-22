import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { lazy, Suspense, useState, useEffect } from 'react';
import { useAuth } from './context/AuthContext';
import { WebSocketProvider } from './context/WebSocketContext';
import { MessageNotificationProvider } from './context/MessageNotificationContext';
import { MessagingProvider } from './context/MessagingContext';
import Sidebar from './components/layout/Sidebar';
import LoginPage from './pages/LoginPage';
import SessionDetailPage from './pages/SessionDetailPage';
import InspectionsPage from './pages/InspectionsPage';
import AnalyticsPage from './pages/AnalyticsPage';
import ReportsHubPage from './pages/ReportsHubPage';
import SetupApprovalReportsPage from './pages/SetupApprovalReportsPage';
import RunChartReportsPage from './pages/RunChartReportsPage';
import DailyProductionReportsPage from './pages/DailyProductionReportsPage';
import DowntimeReportsPage from './pages/DowntimeReportsPage';
import ProductionModulePage from './pages/ProductionModulePage';
import JHInspectionReportsPage from './pages/JHInspectionReportsPage';
import MachinesPage from './pages/MachinesPage';
import MachineDetailPage from './pages/MachineDetailPage';
import ParametersPage from './pages/ParametersPage';
import UsersPage from './pages/UsersPage';
import ProfilePage from './pages/ProfilePage';
import CompanyDetailsPage from './pages/CompanyDetailsPage';
import TasksPage from './pages/TasksPage';
import VerifyEmailPage from './pages/VerifyEmailPage';
import ForgotPasswordPage from './pages/ForgotPasswordPage';
import ResetPasswordPage from './pages/ResetPasswordPage';
import QualityAnalyzerPage from './pages/QualityAnalyzerPage';
import PDIReportsPage from './pages/PDIReportsPage';
import OEEReportPage from './pages/OEEReportPage';
import HRModulePage from './pages/HRModulePage';
import PurchaseModulePage from './pages/PurchaseModulePage';
import StoreModulePage from './pages/StoreModulePage';
import InventoryManagementPage from './pages/InventoryManagementPage';
import MaintenanceModulePage from './pages/MaintenanceModulePage';
import DevelopmentModulePage from './pages/DevelopmentModulePage';
import DrawingsPage from './pages/DrawingsPage';
import ControlPlansPage from './pages/ControlPlansPage';
import MarketingModulePage from './pages/MarketingModulePage';
import MessagesPage from './pages/MessagesPage';
import DocumentControlPage from './pages/DocumentControlPage';
import DocumentControlDocumentsPage from './pages/DocumentControlDocumentsPage';
import DocumentControlApprovalsPage from './pages/DocumentControlApprovalsPage';
import DocumentControlDCRPage from './pages/DocumentControlDCRPage';
import MasterDatabasePage from './pages/MasterDatabasePage';
import LoadingSpinner from './components/common/LoadingSpinner';
import AccessDeniedModalHost from './components/common/AccessDeniedModal';
import { getPendingSessions } from './api/inspections';
import { can, canOpenPath } from './utils/access';

const PLANT_ID = 1;
const CalibrationPage = lazy(() => import('./pages/CalibrationPage'));

function ProtectedLayout({ children, pendingCount }) {
  const { user, loading } = useAuth();
  const location = useLocation();
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() =>
    typeof window !== 'undefined' && window.innerWidth < 1100
  );

  useEffect(() => {
    const updateSidebarMode = () => setSidebarCollapsed(window.innerWidth < 1100);
    window.addEventListener('resize', updateSidebarMode);
    updateSidebarMode();
    return () => window.removeEventListener('resize', updateSidebarMode);
  }, []);

  if (loading) return <LoadingSpinner message="Checking authentication..." />;
  if (!user) return <Navigate to="/login" replace />;
  if (!canOpenPath(user, location.pathname)) return <Navigate to="/" replace />;

  const toggleSidebar = () => {
    setSidebarCollapsed((current) => !current);
  };

  const layout = (
    <div className={`app-layout${sidebarCollapsed ? ' sidebar-collapsed' : ''}`}>
      <Sidebar pendingCount={pendingCount} collapsed={sidebarCollapsed} onToggle={toggleSidebar} />
      <main className="main-content">
        <Suspense fallback={<LoadingSpinner message="Loading module..." />}>
          {children}
        </Suspense>
      </main>
      <AccessDeniedModalHost />
    </div>
  );

  return (
    <WebSocketProvider plantId={PLANT_ID}>
      <MessagingProvider>
        {layout}
      </MessagingProvider>
    </WebSocketProvider>
  );
}

function RootRedirect() {
  const { user, loading } = useAuth();
  if (loading) return <LoadingSpinner message="Redirecting..." />;
  if (!user) return <Navigate to="/login" replace />;
  for (const path of ['/users', '/production', '/quality-analyzer', '/tasks', '/messages']) {
    if (canOpenPath(user, path)) return <Navigate to={path} replace />;
  }
  return <Navigate to="/profile" replace />;
}

export default function App() {
  const { user } = useAuth();
  const [pendingCount, setPendingCount] = useState(0);

  useEffect(() => {
    if (!user || !can(user, 'quality.inspections.review')) {
      setPendingCount(0);
      return;
    }

    const updatePendingCount = async () => {
      try {
        const res = await getPendingSessions();
        setPendingCount(res.data?.length ?? 0);
      } catch { /* ignore */ }
    };
    updatePendingCount();
    const interval = setInterval(updatePendingCount, 30000);
    return () => clearInterval(interval);
  }, [user]);

  // Dynamically update browser tab title to "[ROLE] | Inspection Hub"
  useEffect(() => {
    if (!user) {
      document.title = 'Inspection Hub';
      return;
    }
    const roleLabels = {
      admin: 'ADMIN',
      supervisor: 'SUPERVISOR',
      calibrator: 'CALIBRATOR',
      operator: 'OPERATOR',
      quality_engineer: 'QUALITY ENGINEER',
      inspector: 'INSPECTOR',
    };
    const roleText = user.role_name?.toUpperCase() || roleLabels[user.role] || (user.role || '').toUpperCase();
    document.title = `${roleText} | Inspection Hub`;
  }, [user]);

  return (
    <MessageNotificationProvider>
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/verify-email/:token" element={<VerifyEmailPage />} />
      <Route path="/forgot-password" element={<ForgotPasswordPage />} />
      <Route path="/reset-password/:uid/:token" element={<ResetPasswordPage />} />
      
      <Route
        path="/"
        element={<RootRedirect />}
      />
      <Route
        path="/pending"
        element={<RootRedirect />}
      />
      <Route
        path="/reports"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <ReportsHubPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/reports/setup-approval"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <SetupApprovalReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/reports/run-chart"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <RunChartReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/reports/daily-production"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DailyProductionReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/reports/downtime"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DowntimeReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/reports/oee"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <OEEReportPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/production"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <ProductionModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/production/downtime"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DowntimeReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/production/daily-production"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DailyProductionReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/production/jh-inspections"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <JHInspectionReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/quality-analyzer"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <QualityAnalyzerPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/quality-analyzer/pdi"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <PDIReportsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/qa"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <QualityAnalyzerPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/hr"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <HRModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/purchase"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <PurchaseModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/inventory"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <InventoryManagementPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/store"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <StoreModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/maintenance"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MaintenanceModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/development"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DevelopmentModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/development/drawings"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DrawingsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/development/control-plans"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <ControlPlansPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/marketing"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MarketingModulePage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/inspections"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <InspectionsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/inspections/:sessionId"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <SessionDetailPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/analytics"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <AnalyticsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/machines"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MachinesPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/machines/:machineId"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MachineDetailPage />
          </ProtectedLayout>
        }
      />
      
      <Route
        path="/master-database"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MasterDatabasePage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/parameters"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <ParametersPage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/users"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <UsersPage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/profile"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <ProfilePage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/company"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CompanyDetailsPage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/calibration"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CalibrationPage view="dashboard" />
          </ProtectedLayout>
        }
      />

      <Route
        path="/calibration/equipment"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CalibrationPage view="equipment" />
          </ProtectedLayout>
        }
      />

      <Route
        path="/calibration/equipment/new"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CalibrationPage view="register" />
          </ProtectedLayout>
        }
      />

      <Route
        path="/calibration/plan"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CalibrationPage view="plan" />
          </ProtectedLayout>
        }
      />

      <Route
        path="/calibration/equipment/:equipmentId/history"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <CalibrationPage view="history" />
          </ProtectedLayout>
        }
      />

      <Route
        path="/tasks"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <TasksPage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/messages"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <MessagesPage />
          </ProtectedLayout>
        }
      />

      <Route
        path="/document-control"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DocumentControlPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/document-control/documents"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DocumentControlDocumentsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/document-control/approvals"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DocumentControlApprovalsPage />
          </ProtectedLayout>
        }
      />
      <Route
        path="/document-control/dcr"
        element={
          <ProtectedLayout pendingCount={pendingCount}>
            <DocumentControlDCRPage />
          </ProtectedLayout>
        }
      />

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
    </MessageNotificationProvider>
  );
}
