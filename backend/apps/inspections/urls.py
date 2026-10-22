from django.urls import path, include
from rest_framework.routers import SimpleRouter
from .views import (
    StartInspectionView,
    RecordMeasurementView,
    BatchMeasureView,
    CompleteInspectionView,
    SessionDetailView,
    PendingReviewView,
    ApproveRejectView,
    SessionListView,
    RejectionsListView,
    SupervisorOverrideView,
    HourlyStatusView,
    SetupStatusView,
    ClearHistoryView,
    FinalizeFirstPieceView,
    FirstPiecePDFView,
    FirstPieceStatusView,
    SetupApprovalView,
    SetupApprovalPDFView,
    DailyProductionReportViewSet,
    DowntimeReportViewSet,
    JHChecklistItemsView,
    JHInspectionSubmitView,
    JHInspectionReportsView,
    JHInspectionDetailView,
    JHInspectionMatrixView,
    JHInspectionMatrixExportExcelView,
    JHChecklistUploadParseView,
    JHChecklistBulkSaveView,
    JHChecklistTemplateDownloadView,
    JHChecklistVersionListView,
    JHChecklistVersionDetailView,
    JHChecklistVersionRestoreView,
    JHChecklistStatusView,
    RunChartOperationsView,
    RunChartParametersView,
    RunChartOpenReportView,
    RunChartReportDetailView,
    RunChartReportHistoryView,
    RunChartCompleteView,
    RunChartReadingCreateView,
    RunChartPDFView,
    RunChartExcelView,
)
from .pdi_views import (
    PDIReportOperationsView,
    PDIReportParametersView,
    PDIReportCreateView,
    PDIReportReadingView,
    PDIReportDetailView,
    PDIReportSubmitView,
    PDIReportListView,
)

router = SimpleRouter()
router.register('daily-production-reports', DailyProductionReportViewSet, basename='daily-production-report')
router.register('downtime-reports', DowntimeReportViewSet, basename='downtime-report')

urlpatterns = [
    # Main session list
    path('', SessionListView.as_view(), name='session-list'),

    # Daily Production Reports router
    path('', include(router.urls)),

    # 100% critical-parameter run charts
    path('run-chart/machines/<int:machine_id>/operations/', RunChartOperationsView.as_view(), name='run-chart-operations'),
    path('run-chart/operations/<int:template_id>/parameters/', RunChartParametersView.as_view(), name='run-chart-parameters'),
    path('run-chart/reports/open/', RunChartOpenReportView.as_view(), name='run-chart-open-report'),
    path('run-chart/reports/', RunChartReportHistoryView.as_view(), name='run-chart-report-history'),
    path('run-chart/reports/<uuid:report_id>/complete/', RunChartCompleteView.as_view(), name='run-chart-complete'),
    path('run-chart/reports/<uuid:report_id>/', RunChartReportDetailView.as_view(), name='run-chart-report-detail'),
    path('run-chart/reports/<uuid:report_id>/readings/', RunChartReadingCreateView.as_view(), name='run-chart-reading-create'),
    path('run-chart/reports/<uuid:report_id>/pdf/', RunChartPDFView.as_view(), name='run-chart-pdf'),
    path('run-chart/reports/<uuid:report_id>/xlsx/', RunChartExcelView.as_view(), name='run-chart-xlsx'),

    # Pre-Dispatch Inspection (five samples X1-X5)
    path('pdi/machines/<int:machine_id>/operations/', PDIReportOperationsView.as_view(), name='pdi-operations'),
    path('pdi/operations/<int:template_id>/parameters/', PDIReportParametersView.as_view(), name='pdi-parameters'),
    path('pdi/reports/', PDIReportListView.as_view(), name='pdi-report-list'),
    path('pdi/reports/create/', PDIReportCreateView.as_view(), name='pdi-report-create'),
    path('pdi/reports/<uuid:report_id>/', PDIReportDetailView.as_view(), name='pdi-report-detail'),
    path('pdi/reports/<uuid:report_id>/readings/', PDIReportReadingView.as_view(), name='pdi-report-reading'),
    path('pdi/reports/<uuid:report_id>/submit/', PDIReportSubmitView.as_view(), name='pdi-report-submit'),

    # Inspector & Setup flow
    path('first-piece-status/',             FirstPieceStatusView.as_view(),   name='first-piece-status'),
    path('<uuid:session_id>/finalize/',      FinalizeFirstPieceView.as_view(), name='finalize-first-piece'),
    path('<uuid:session_id>/pdf/',           FirstPiecePDFView.as_view(),      name='first-piece-pdf'),

    # Supervisor flow
    path('pending/',                        PendingReviewView.as_view(),      name='pending-review'),
    path('clear-history/',                  ClearHistoryView.as_view(),       name='clear-history'),
    path('<uuid:session_id>/supervisor-override/', SupervisorOverrideView.as_view(), name='supervisor-override'),
    path('<uuid:session_id>/hourly-status/', HourlyStatusView.as_view(),      name='hourly-status'),

    # Operator flow
    path('setup-status/',                   SetupStatusView.as_view(),        name='setup-status'),
    path('setup-approval/',                 SetupApprovalView.as_view(),      name='setup-approval'),
    path('setup-approval/<uuid:setup_id>/pdf/', SetupApprovalPDFView.as_view(), name='setup-approval-pdf'),
    path('rejections/',                     RejectionsListView.as_view(),     name='rejections-list'),
    path('start/',                          StartInspectionView.as_view(),    name='inspection-start'),
    path('<uuid:session_id>/measure/',       RecordMeasurementView.as_view(),  name='record-measurement'),
    path('<uuid:session_id>/complete/',      CompleteInspectionView.as_view(), name='inspection-complete'),
    path('<uuid:session_id>/review/',        ApproveRejectView.as_view(),      name='approve-reject'),

    # JH (Autonomous Maintenance) Routes
    path('jh/items/',                                       JHChecklistItemsView.as_view(),              name='jh-checklist-items'),
    path('jh/checklist/upload_parse/',                      JHChecklistUploadParseView.as_view(),        name='jh-checklist-upload-parse'),
    path('jh/checklist/upload-parse/',                      JHChecklistUploadParseView.as_view(),        name='jh-checklist-upload-parse-alias'),
    path('jh/checklist/bulk_save/',                         JHChecklistBulkSaveView.as_view(),           name='jh-checklist-bulk-save'),
    path('jh/checklist/bulk-save/',                         JHChecklistBulkSaveView.as_view(),           name='jh-checklist-bulk-save-alias'),
    path('jh/checklist/template/',                          JHChecklistTemplateDownloadView.as_view(),   name='jh-checklist-template-download'),
    path('jh/checklist/status/',                           JHChecklistStatusView.as_view(),             name='jh-checklist-status'),
    path('jh/checklist/versions/',                          JHChecklistVersionListView.as_view(),        name='jh-checklist-versions-list'),
    path('jh/checklist/versions/<int:version_number>/',     JHChecklistVersionDetailView.as_view(),      name='jh-checklist-version-detail'),
    path('jh/checklist/versions/<int:version_number>/restore/', JHChecklistVersionRestoreView.as_view(), name='jh-checklist-version-restore'),
    path('jh/submit/',                                      JHInspectionSubmitView.as_view(),             name='jh-inspection-submit'),
    path('jh/reports/',                     JHInspectionReportsView.as_view(),            name='jh-inspection-reports'),
    path('jh/reports/<str:pk>/',            JHInspectionDetailView.as_view(),             name='jh-inspection-detail'),
    path('jh/matrix/export_excel/',         JHInspectionMatrixExportExcelView.as_view(),  name='jh-inspection-matrix-export-excel'),
    path('jh/matrix/',                      JHInspectionMatrixView.as_view(),             name='jh-inspection-matrix'),

    # Session detail (full MongoDB document) : wildcard route must be last
    path('<uuid:session_id>/batch-measure/', BatchMeasureView.as_view(),      name='batch-measure'),
    path('<uuid:session_id>/',              SessionDetailView.as_view(),      name='session-detail'),
]
