"""
Root URL configuration for Voice-Driven Inspection System.
"""

from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static

urlpatterns = [
    # Django Admin
    path('admin/', admin.site.urls),

    # API Routes
    path('api/users/',       include('apps.users.urls')),
    path('api/auth/',        include('apps.users.urls')),
    path('api/machines/',    include('apps.machines.urls')),
    path('api/parts/',       include('apps.parts.urls')),
    path('api/inspections/', include('apps.inspections.urls')),
    path('api/voice/',       include('apps.voice.urls')),
    path('api/dashboard/',   include('apps.dashboard.urls')),
    path('api/analytics/',   include('apps.analytics.urls')),
    path('api/calibration/', include('apps.calibration.urls')),
    path('api/messaging/',        include('apps.messaging.urls')),
    path('api/document-control/', include('apps.document_control.urls')),
    path('api/', include('apps.tasks.urls')),
    path('api/support/', include('apps.support.urls')),
    path('api/inventory/', include('apps.inventory.urls')),
]

# Serve media files in development
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
