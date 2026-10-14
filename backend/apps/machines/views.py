import os
import uuid
import logging
import threading
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import AllowAny
from rest_framework.parsers import MultiPartParser, FormParser

from .models import Factory, Plant, Machine
from .serializers import FactorySerializer, PlantSerializer, MachineSerializer, MachineListSerializer
from apps.users.permissions import HasAccess
from apps.users.access import OPERATIONAL_READ

logger = logging.getLogger(__name__)


# ─── Factory ──────────────────────────────────────────────────────────────
class FactoryListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/machines/factories/   → list factories (Public branding metadata)
    POST /api/machines/factories/   → create (Admin only)
    """
    queryset           = Factory.objects.filter(is_active=True)
    serializer_class   = FactorySerializer
    permission_classes = [AllowAny]

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('quality.machines.manage')]
        return [AllowAny()]


class FactoryDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/machines/factories/<id>/"""
    queryset           = Factory.objects.all()
    serializer_class   = FactorySerializer
    def get_permissions(self):
        if self.request.method == 'GET':
            return [AllowAny()]
        return [HasAccess('quality.machines.manage')]

    def perform_update(self, serializer):
        instance = serializer.save()
        shift_hrs = instance.shift_hours or 8
        total_break = (instance.lunch_break_minutes or 0) + (instance.tea_break_minutes or 0)

        # Cascade shift duration and break minutes to all plants under this factory
        instance.plants.all().update(
            shift_duration_hours=shift_hrs,
            total_break_mins=total_break
        )

        # Update all inspection sessions' document_payload with new shift_hours
        try:
            from apps.inspections.models import InspectionSession
            from apps.inspections import document_utils as doc_utils
            sessions = InspectionSession.objects.filter(
                machine__plant__factory=instance
            )
            for session in sessions:
                doc_utils.update_document(
                    session,
                    updates={
                        'shift_hours': shift_hrs,
                        'total_hourly_slots': shift_hrs
                    },
                    save=True
                )
        except Exception:
            pass


def _trigger_apk_rebuild(logo_url: str) -> None:
    """
    Fire-and-forget: triggers GitHub Actions workflow to rebuild the APK
    with the new company logo as the launcher icon.
    Runs in a background thread so it never blocks the API response.
    Requires GITHUB_PAT env var with 'workflow' scope.
    """
    import requests as req
    token = os.environ.get('GITHUB_PAT', '')
    if not token:
        logger.warning('[APK Rebuild] GITHUB_PAT not set — skipping APK rebuild trigger.')
        return

    repo          = 'Samrudhi1004/Ledger-Entry-Automation'
    workflow_file = 'build-apk.yml'
    url = f'https://api.github.com/repos/{repo}/actions/workflows/{workflow_file}/dispatches'

    try:
        resp = req.post(
            url,
            headers={
                'Authorization': f'Bearer {token}',
                'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28',
            },
            json={'ref': 'samruddhi_contri', 'inputs': {'logo_url': logo_url}},
            timeout=10,
        )
        if resp.status_code == 204:
            logger.info(f'[APK Rebuild] GitHub Actions triggered successfully for logo: {logo_url}')
        else:
            logger.warning(f'[APK Rebuild] GitHub Actions returned {resp.status_code}: {resp.text}')
    except Exception as exc:
        logger.warning(f'[APK Rebuild] Failed to trigger GitHub Actions: {exc}')


class FactoryUploadLogoView(APIView):
    """
    POST /api/machines/factories/<id>/upload-logo/
    Uploads a new company logo image file (multipart/form-data with 'logo' or 'file').
    Saves to Cloudinary if configured, or local media storage.
    Updates factory.logo and factory.logo_url with full absolute URL.

    DELETE /api/machines/factories/<id>/upload-logo/
    Removes the custom uploaded logo and resets logo_url to empty.
    """
    parser_classes = [MultiPartParser, FormParser]

    def get_permissions(self):
        return [HasAccess('quality.machines.manage')]

    def post(self, request, pk):
        try:
            factory = Factory.objects.get(pk=pk)
        except Factory.DoesNotExist:
            return Response({'detail': 'Factory not found.'}, status=status.HTTP_404_NOT_FOUND)

        file_obj = request.FILES.get('logo') or request.FILES.get('file')
        if not file_obj:
            return Response(
                {'detail': 'No file uploaded. Please supply a "logo" image file.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Validate file extension
        ext = os.path.splitext(file_obj.name)[1].lower()
        allowed_exts = ['.png', '.jpg', '.jpeg', '.svg', '.webp']
        if ext not in allowed_exts:
            return Response(
                {'detail': f'Unsupported file type "{ext}". Allowed types: {", ".join(allowed_exts)}'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Validate file size (max 5 MB)
        max_bytes = 5 * 1024 * 1024
        if file_obj.size > max_bytes:
            return Response(
                {'detail': f'File size exceeds 5MB limit ({file_obj.size / (1024*1024):.1f}MB).'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # 1. Try Cloudinary if available and configured
        uploaded_to_cloudinary = False
        try:
            import cloudinary
            import cloudinary.uploader
            if os.getenv('CLOUDINARY_CLOUD_NAME'):
                upload_res = cloudinary.uploader.upload(
                    file_obj,
                    folder='company_logos',
                    resource_type='image',
                    public_id=f"factory_{factory.id}_{uuid.uuid4().hex[:8]}"
                )
                if upload_res and 'secure_url' in upload_res:
                    secure_url = upload_res['secure_url']
                    # Use .update() to safely bypass any bugged CloudinaryField pre_save
                    Factory.objects.filter(pk=factory.pk).update(
                        logo_url=secure_url,
                        logo=upload_res.get('public_id', '')
                    )
                    factory.logo_url = secure_url
                    uploaded_to_cloudinary = True
        except Exception as e:
            import logging
            logger = logging.getLogger(__name__)
            logger.error(f"Cloudinary upload failed: {e}")

        # 2. Local media storage fallback
        if not uploaded_to_cloudinary:
            try:
                factory.logo = file_obj
                factory.save()
                absolute_url = request.build_absolute_uri(factory.logo.url)
                factory.logo_url = absolute_url
                Factory.objects.filter(pk=factory.pk).update(logo_url=absolute_url)
            except Exception as e:
                import logging
                logger = logging.getLogger(__name__)
                logger.error(f"Fallback local upload failed: {e}")
                return Response(
                    {'detail': 'Failed to upload logo. Ensure Cloudinary variables are configured.'},
                    status=status.HTTP_500_INTERNAL_SERVER_ERROR
                )

        # Trigger async APK rebuild with the new launcher icon (non-blocking)
        threading.Thread(
            target=_trigger_apk_rebuild,
            args=(factory.logo_url,),
            daemon=True,
        ).start()

        return Response({
            'success': True,
            'message': 'Company logo uploaded successfully.',
            'logo_url': factory.logo_url,
            'factory_id': factory.id,
            'factory_name': factory.name,
        }, status=status.HTTP_200_OK)

    def delete(self, request, pk):
        try:
            factory = Factory.objects.get(pk=pk)
        except Factory.DoesNotExist:
            return Response({'detail': 'Factory not found.'}, status=status.HTTP_404_NOT_FOUND)

        if factory.logo:
            try:
                factory.logo.delete(save=False)
            except Exception:
                pass
        factory.logo_url = ''
        factory.save()
        return Response({
            'success': True,
            'message': 'Company logo removed successfully.',
            'logo_url': '',
        }, status=status.HTTP_200_OK)


# ─── Plant ────────────────────────────────────────────────────────────────
class PlantListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/machines/plants/              → all plants
    GET  /api/machines/plants/?factory=1    → filter by factory
    POST /api/machines/plants/              → create (Admin only)
    """
    serializer_class   = PlantSerializer
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_queryset(self):
        qs = Plant.objects.select_related('factory').filter(is_active=True)
        factory_id = self.request.query_params.get('factory')
        if factory_id:
            qs = qs.filter(factory_id=factory_id)
        return qs

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('quality.machines.manage')]
        return [HasAccess(('inventory.manage', *OPERATIONAL_READ))]


class PlantDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/machines/plants/<id>/"""
    queryset           = Plant.objects.all()
    serializer_class   = PlantSerializer
    def get_permissions(self):
        if self.request.method == 'GET':
            return [HasAccess(OPERATIONAL_READ)]
        return [HasAccess('quality.machines.manage')]


# ─── Machine ──────────────────────────────────────────────────────────────
class MachineListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/machines/                 → all machines
    GET  /api/machines/?plant=1         → filter by plant
    GET  /api/machines/?status=active   → filter by status
    POST /api/machines/                 → create (Admin only)
    """
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    serializer_class = MachineSerializer

    def get_queryset(self):
        qs = Machine.objects.select_related('plant__factory').filter(is_active=True)
        plant_id = self.request.query_params.get('plant')
        status   = self.request.query_params.get('status')
        if plant_id:
            qs = qs.filter(plant_id=plant_id)
        if status:
            qs = qs.filter(status=status)
        return qs

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('quality.machines.manage')]
        return [HasAccess(OPERATIONAL_READ)]


class MachineDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/machines/<id>/"""
    queryset           = Machine.objects.select_related('plant__factory').all()
    serializer_class   = MachineSerializer
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_permissions(self):
        if self.request.method not in ('GET', 'HEAD', 'OPTIONS'):
            return [HasAccess('quality.machines.manage')]
        return [HasAccess(OPERATIONAL_READ)]

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        instance.is_active = False
        instance.save()
        return Response({'message': f'Machine {instance.machine_code} deactivated successfully.'}, status=status.HTTP_204_NO_CONTENT)


class MachineByQRView(APIView):
    """
    GET /api/machines/scan/<qr_code>/
    Flutter app scans QR → fetches machine details instantly.
    """
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get(self, request, qr_code):
        try:
            machine = Machine.objects.select_related('plant__factory').get(
                qr_code=qr_code, is_active=True
            )
            serializer = MachineSerializer(machine, context={'request': request})
            return Response(serializer.data)
        except Machine.DoesNotExist:
            return Response(
                {'error': f'No active machine found for QR code: {qr_code}'},
                status=status.HTTP_404_NOT_FOUND,
            )
