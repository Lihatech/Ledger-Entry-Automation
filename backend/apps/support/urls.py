from django.urls import path
from .views import BugReportListCreateView, MobileUpdateView

urlpatterns = [
    path('bug-reports/', BugReportListCreateView.as_view(), name='bug-reports-list-create'),
    path('mobile-update/', MobileUpdateView.as_view(), name='mobile-update'),
]
