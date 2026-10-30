"""
Views for the Document Control module.

Handles:
  1. DocumentViewSet (Upload, revisions, in-app viewer metadata, levels L1-L4)
  2. DocumentChangeRequestViewSet (Form DKI/MR/F/05 DCR workflow, reviews, approvals, rejection, PDF)
  3. DCRNotificationViewSet (Realtime notifications, unread counts, mark as read)
"""

import mimetypes
import logging
from datetime import datetime
from pathlib import Path

from django.db import transaction
from django.db.models import Q
from django.shortcuts import redirect, get_object_or_404
from django.http import HttpResponse
from django.utils import timezone
from django.contrib.auth import get_user_model

from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

try:
    import cloudinary
    import cloudinary.uploader
    CLOUDINARY_AVAILABLE = True
except ImportError:
    CLOUDINARY_AVAILABLE = False

try:
    import filetype as filetype_lib
    FILETYPE_AVAILABLE = True
except ImportError:
    FILETYPE_AVAILABLE = False

from .models import Document, DocumentActivity, DocumentChangeRequest, DCRNotification, DocumentUserPermission
from apps.users.models import AccessRole
from .serializers import (
    DocumentListSerializer,
    DocumentDetailSerializer,
    DocumentCreateSerializer,
    DocumentAccessSerializer,
    DocumentActivitySerializer,
    DocumentUserPermissionReadSerializer,
    BulkDocumentAccessSerializer,
    DCRCreateSerializer,
    DCRReviewSerializer,
    DCRApproveSerializer,
    DCRRejectSerializer,
    DCRListSerializer,
    DCRDetailSerializer,
    DCRNotificationSerializer,
)
from .storage import document_delivery_url
from .services.dcr_mailer import (
    notify_dcr_submitted,
    notify_dcr_reviewed,
    notify_dcr_rejected,
    notify_dcr_approved,
)
from .services.doc_mailer import (
    notify_doc_review_requested,
    notify_doc_approval_requested,
    notify_doc_approved,
    notify_doc_rejected,
)
from .services.dcr_pdf import generate_dcr_pdf

logger = logging.getLogger(__name__)
User = get_user_model()

FILE_SIZE_LIMIT = 50 * 1024 * 1024  # 50 MB
DOCUMENT_EXTENSIONS = {
    '.pdf', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.txt', '.csv',
    '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
}


def _validate_document_upload(file):
    """Validate size, extension, and magic bytes before storage."""
    if file.size <= 0 or file.size > FILE_SIZE_LIMIT:
        return 'Document files must be larger than 0 bytes and no larger than 50 MB.'
    extension = Path(file.name).suffix.lower()
    if extension not in DOCUMENT_EXTENSIONS:
        return 'Unsupported document extension.'
    header = file.read(16)
    file.seek(0)
    signatures = {
        '.pdf': b'%PDF-', '.png': b'\x89PNG\r\n\x1a\n',
        '.jpg': b'\xff\xd8\xff', '.jpeg': b'\xff\xd8\xff', '.gif': b'GIF8',
        '.webp': b'RIFF',
    }
    signature = signatures.get(extension)
    if signature and not header.startswith(signature):
        return 'File contents do not match the selected file type.'
    return None


def _generate_document_number():
    """Auto-generate document number: DOC-YYYY-NNN"""
    year = datetime.now().year
    prefix = f'DOC-{year}-'
    last = (
        Document.objects
        .filter(document_number__startswith=prefix)
        .order_by('-document_number')
        .values_list('document_number', flat=True)
        .first()
    )
    if last:
        try:
            seq = int(last.split('-')[-1]) + 1
        except ValueError:
            seq = 1
    else:
        seq = 1
    return f'{prefix}{seq:03d}'


def _detect_mime(file):
    """Detect MIME type for uploaded document."""
    if FILETYPE_AVAILABLE:
        file_bytes = file.read(2048)
        file.seek(0)
        kind = filetype_lib.guess(file_bytes)
        if kind:
            return kind.mime
    mime, _ = mimetypes.guess_type(file.name)
    return mime or 'application/octet-stream'


def _upload_to_cloudinary(file, file_type):
    """Upload document file to Cloudinary."""
    if not CLOUDINARY_AVAILABLE:
        raise RuntimeError('Cloudinary is not configured.')

    year = datetime.now().year
    resource_type = 'image' if file_type.startswith('image/') else 'raw'
    folder = f'document_control/{year}'

    result = cloudinary.uploader.upload(
        file,
        folder=folder,
        resource_type=resource_type,
        use_filename=True,
        unique_filename=True,
    )
    return result


# ─────────────────────────────────────────────────────────────────────────────
# 2. Document ViewSet (Includes L1-L4 Filtering and Direct In-App Viewing)
# ─────────────────────────────────────────────────────────────────────────────

class DocumentViewSet(viewsets.ModelViewSet):
    """
    Main Document ViewSet.
    Supports filtering by level (L1, L2, L3, L4), status, and text search.
    """
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def get_permissions(self):
        return super().get_permissions()

    def _authenticate_request_user(self, request):
        if request.user and request.user.is_authenticated:
            if not request.user.is_active:
                return None
            return request.user
        return None

    def get_queryset(self):
        qs = Document.objects.select_related(
            'uploaded_by', 'approved_by', 'reviewed_by'
        ).prefetch_related('allowed_roles').filter(is_latest_revision=True)

        user = self.request.user
        if not user.has_access('document.view_unapproved'):
            qs = qs.filter(status=Document.Status.APPROVED)

        # Documents without an allow-list remain visible to all users with
        # document access. A role allow-list is enforced for every non-admin
        # viewer, including users who can upload documents; the uploader keeps
        # owner visibility so they can continue managing their document.
        # ── Per-user permission visibility filter ────────────────────────────
        # A document is visible if:
        #   1. User is admin / superuser → no filter (sees everything)
        #   2. User is the uploader → always visible
        #   3. User has a DocumentUserPermission row with at least one True flag
        # Legacy allowed_roles is ignored going forward.
        is_manager = (
            user.is_superuser or
            getattr(user, 'role', '') == 'admin'
        )
        if not is_manager:
            accessible_doc_ids = DocumentUserPermission.objects.filter(
                user=user
            ).filter(
                Q(can_preview=True) | Q(can_download=True) |
                Q(can_print=True) | Q(can_edit=True) | Q(can_delete=True)
            ).values_list('document_id', flat=True)

            qs = qs.filter(
                Q(id__in=accessible_doc_ids) | Q(uploaded_by=user)
            ).distinct()

        params = self.request.query_params
        # Filter by Document Level (L1, L2, L3, L4)
        if level := params.get('level'):
            qs = qs.filter(doc_level=level)

        # Filter by Status
        if status_filter := params.get('status'):
            if status_filter == 'pending':
                qs = qs.filter(status__in=[Document.Status.UNDER_REVIEW, Document.Status.AWAITING_APPROVAL])
            else:
                qs = qs.filter(status=status_filter)

        # Search Query
        if search := params.get('search'):
            qs = qs.filter(
                Q(title__icontains=search) |
                Q(document_number__icontains=search) |
                Q(description__icontains=search)
            )

        return qs.order_by('-created_at')

    def get_serializer_class(self):
        if self.action == 'retrieve':
            return DocumentDetailSerializer
        if self.action == 'create':
            return DocumentCreateSerializer
        return DocumentListSerializer

    def create(self, request, *args, **kwargs):
        if not request.user.has_access('document.upload'):
            return Response({'error': 'Document upload access required.'}, status=403)

        file = request.FILES.get('file')
        if not file:
            return Response({'error': 'A file is required.'}, status=400)

        validation_error = _validate_document_upload(file)
        if validation_error:
            return Response({'error': validation_error}, status=400)

        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        file_type = _detect_mime(file)

        try:
            upload_result = _upload_to_cloudinary(file, file_type)
        except Exception as exc:
            logger.error('Cloudinary upload failed: %s', exc)
            return Response({'error': f'File upload failed: {exc}'}, status=500)

        custom_doc_number = (request.data.get('document_number') or '').strip()
        if custom_doc_number:
            if Document.objects.filter(document_number__iexact=custom_doc_number).exists():
                return Response({'error': f'Document with number "{custom_doc_number}" already exists.'}, status=400)
            doc_number = custom_doc_number
        else:
            doc_number = _generate_document_number()

        desired_status = (request.data.get('status') or '').strip().lower()
        if desired_status == 'approved':
            initial_status = Document.Status.APPROVED
        elif desired_status == 'under_review' or serializer.validated_data.get('reviewed_by'):
            initial_status = Document.Status.UNDER_REVIEW
        else:
            initial_status = Document.Status.DRAFT

        save_kwargs = {
            'uploaded_by': request.user,
            'document_number': doc_number,
            'cloudinary_url': upload_result['secure_url'],
            'cloudinary_public_id': upload_result['public_id'],
            'file_name': file.name,
            'file_size': file.size,
            'file_type': file_type,
            'status': initial_status,
        }
        if not serializer.validated_data.get('revision'):
            save_kwargs['revision'] = '0'

        if initial_status == Document.Status.APPROVED:
            if serializer.validated_data.get('reviewed_by'):
                save_kwargs['reviewed_at'] = timezone.now()
            if serializer.validated_data.get('approved_by'):
                save_kwargs['approved_at'] = timezone.now()

        with transaction.atomic():
            doc = serializer.save(**save_kwargs)
            action_name = 'approved' if initial_status == Document.Status.APPROVED else ('submitted_review' if initial_status == Document.Status.UNDER_REVIEW else 'uploaded')
            if initial_status == Document.Status.APPROVED:
                rev = doc.reviewed_by
                app = doc.approved_by
                rev_text = (rev.get_full_name() or rev.username) if rev else "None"
                app_text = (app.get_full_name() or app.username) if app else "None"
                activity_comment = f'Uploaded active master: {file.name} (Reviewer: {rev_text}, Approver: {app_text})'
            elif initial_status == Document.Status.UNDER_REVIEW:
                activity_comment = f'Submitted for review: {file.name}'
            else:
                activity_comment = f'Uploaded initial file: {file.name} (Status: {initial_status})'

            DocumentActivity.objects.create(
                document=doc,
                action=action_name,
                performed_by=request.user,
                comment=activity_comment,
            )

        # Trigger notification based on initial status
        if initial_status == Document.Status.UNDER_REVIEW:
            notify_doc_review_requested(doc)
        elif initial_status == Document.Status.APPROVED:
            notify_doc_approved(doc)

        return Response(DocumentListSerializer(doc).data, status=status.HTTP_201_CREATED)

    @action(detail=False, methods=['get'], url_path='roles')
    def roles(self, request):
        """Return current roles for document visibility selectors."""
        if not (request.user.has_access('document.view') or request.user.has_access('document.upload')):
            return Response({'error': 'Document access required.'}, status=403)
        return Response(list(AccessRole.objects.order_by('name').values('slug', 'name')))

    @action(detail=True, methods=['get', 'patch'], url_path='access')
    def access(self, request, pk=None):
        """GET: list all org users + their current permissions for this document.
           PATCH: bulk-save the full permission matrix."""
        doc = get_object_or_404(Document, pk=pk)

        # Only the uploader or an admin may manage access.
        is_admin = request.user.is_superuser or getattr(request.user, 'role', '') == 'admin'
        is_owner = doc.uploaded_by_id == request.user.id
        if not is_admin and not is_owner:
            return Response(
                {'error': 'Only the document uploader or an admin can manage access.'},
                status=403
            )

        if request.method == 'GET':
            # Fetch ALL active org users (exclude the uploader and admins —
            # they always have implicit full access and are not listed).
            all_users = User.objects.filter(
                is_active=True
            ).exclude(
                id=doc.uploaded_by_id
            ).exclude(
                role='admin'
            ).exclude(
                is_superuser=True
            ).order_by('first_name', 'last_name', 'username')

            # Build a lookup of existing permission rows
            existing = {
                str(p.user_id): p
                for p in DocumentUserPermission.objects.filter(document=doc)
            }

            result = []
            for u in all_users:
                uid = str(u.id)
                perm = existing.get(uid)
                result.append({
                    'user_id':      uid,
                    'full_name':    f'{u.first_name} {u.last_name}'.strip() or u.username,
                    'username':     u.username,
                    'role':         u.role,
                    'can_preview':  perm.can_preview  if perm else False,
                    'can_download': perm.can_download if perm else False,
                    'can_print':    perm.can_print    if perm else False,
                    'can_edit':     perm.can_edit     if perm else False,
                    'can_delete':   perm.can_delete   if perm else False,
                })
            return Response({'users': result})

        # PATCH — replace the entire permission matrix atomically
        serializer = BulkDocumentAccessSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        permissions_data = serializer.validated_data['permissions']
        before_snapshot = list(
            DocumentUserPermission.objects.filter(document=doc).values(
                'user_id', 'can_preview', 'can_download', 'can_print', 'can_edit', 'can_delete'
            )
        )

        with transaction.atomic():
            # Wipe existing rows and rebuild
            DocumentUserPermission.objects.filter(document=doc).delete()
            to_create = []
            for entry in permissions_data:
                # Skip rows where every flag is False (no access = no row needed)
                if any([
                    entry.get('can_preview'), entry.get('can_download'),
                    entry.get('can_print'), entry.get('can_edit'), entry.get('can_delete')
                ]):
                    try:
                        user_obj = User.objects.get(id=entry['user_id'])
                    except User.DoesNotExist:
                        continue
                    to_create.append(DocumentUserPermission(
                        document=doc,
                        user=user_obj,
                        can_preview=entry.get('can_preview', False),
                        can_download=entry.get('can_download', False),
                        can_print=entry.get('can_print', False),
                        can_edit=entry.get('can_edit', False),
                        can_delete=entry.get('can_delete', False),
                    ))
            DocumentUserPermission.objects.bulk_create(to_create)
        DocumentActivity.objects.create(
            document=doc,
            action='access_updated',
            performed_by=request.user,
            comment=(
                f'Per-user access updated by {request.user.get_full_name() or request.user.username}. '
                f'{len(to_create)} user(s) granted access.'
            ),
        )
        return Response({'detail': 'Access permissions saved successfully.', 'granted_count': len(to_create)})

    @action(detail=True, methods=['post'], url_path='submit_review')
    def submit_review(self, request, pk=None):
        doc = self.get_object()
        if not request.user.has_access('document.upload'):
            return Response({'error': 'Permission denied.'}, status=403)
        user = request.user

        # Allow assigned reviewer, uploader, or admin/supervisor
        if doc.reviewed_by and doc.reviewed_by != user and getattr(user, 'role', '') not in ('admin', 'supervisor'):
            return Response({'error': 'Only the assigned reviewer or an admin can submit review.'}, status=403)
        if doc.reviewed_at is not None or doc.status not in (Document.Status.DRAFT, Document.Status.UNDER_REVIEW):
            return Response({'error': f'Document has already been reviewed or has status {doc.status}.'}, status=400)

        doc.status = Document.Status.AWAITING_APPROVAL
        doc.reviewed_at = timezone.now()
        if not doc.reviewed_by:
            doc.reviewed_by = user
        doc.save(update_fields=['status', 'reviewed_at', 'reviewed_by', 'updated_at'])

        comment = request.data.get('comment', 'Reviewed and recommended for final approval.')
        DocumentActivity.objects.create(
            document=doc, action='submitted_review', performed_by=user,
            comment=comment
        )
        notify_doc_approval_requested(doc)
        return Response({
            'status': doc.status,
            'detail': 'Reviewed successfully. Submitted for final approval.',
            'document': DocumentListSerializer(doc).data
        })

    @action(detail=True, methods=['post'])
    def approve(self, request, pk=None):
        doc = self.get_object()
        if not request.user.has_access('document.approve'):
            return Response({'error': 'Permission denied.'}, status=403)
        user = request.user

        # Allow assigned approver or admin
        if doc.approved_by and doc.approved_by != user and getattr(user, 'role', '') != 'admin':
            return Response({'error': 'Only the assigned approver or an admin can approve this document.'}, status=403)
        if doc.status not in (Document.Status.DRAFT, Document.Status.UNDER_REVIEW, Document.Status.AWAITING_APPROVAL):
            return Response({'error': f'Cannot approve document with status {doc.status}.'}, status=400)

        doc.status = Document.Status.APPROVED
        doc.approved_at = timezone.now()
        if not doc.approved_by:
            doc.approved_by = user
        doc.effective_date = request.data.get('effective_date') or doc.effective_date or timezone.now().date()
        doc.save(update_fields=['status', 'approved_at', 'approved_by', 'effective_date', 'updated_at'])

        comment = request.data.get('comment', 'Document officially approved.')
        DocumentActivity.objects.create(
            document=doc, action='approved', performed_by=user,
            comment=comment
        )
        notify_doc_approved(doc)
        return Response({
            'status': doc.status,
            'detail': 'Document approved and published.',
            'document': DocumentListSerializer(doc).data
        })

    @action(detail=True, methods=['post'])
    def reject(self, request, pk=None):
        doc = self.get_object()
        if not request.user.has_access('document.approve'):
            return Response({'error': 'Permission denied.'}, status=403)
        user = request.user

        # Allow assigned reviewer, approver, or admin
        is_authorized = (
            user in (doc.reviewed_by, doc.approved_by) or
            getattr(user, 'role', '') in ('admin', 'supervisor')
        )
        if not is_authorized:
            return Response({'error': 'Permission denied.'}, status=403)

        doc.status = Document.Status.REJECTED
        doc.save(update_fields=['status', 'updated_at'])
        reason = request.data.get('comment') or request.data.get('reason') or 'Document rejected.'
        DocumentActivity.objects.create(
            document=doc, action='rejected', performed_by=user,
            comment=reason
        )
        notify_doc_rejected(doc, reason)
        return Response({
            'status': doc.status,
            'detail': 'Document rejected.',
            'document': DocumentListSerializer(doc).data
        })

    @action(detail=True, methods=['post'])
    def revise(self, request, pk=None):
        """Upload a new revision of an existing document."""
        original = self.get_object()
        if not request.user.has_access('document.upload'):
            return Response({'error': 'Permission denied.'}, status=403)

        file = request.FILES.get('file')
        if not file:
            return Response({'error': 'A new revision file is required.'}, status=400)

        validation_error = _validate_document_upload(file)
        if validation_error:
            return Response({'error': validation_error}, status=400)

        next_rev_num = original.revision_number + 1
        rev_letter = chr(ord('A') + next_rev_num - 1) if next_rev_num <= 26 else str(next_rev_num)
        rev_label = f'Rev {rev_letter}'

        file_type = _detect_mime(file)
        category_name = original.category.name.lower().replace(' ', '_') if original.category else 'general'

        try:
            upload_result = _upload_to_cloudinary(file, file_type, category_name)
        except Exception as exc:
            return Response({'error': f'Upload failed: {exc}'}, status=500)

        root = original.parent_document if original.parent_document else original

        with transaction.atomic():
            Document.objects.filter(
                Q(id=root.id) | Q(parent_document=root)
            ).update(is_latest_revision=False)

            new_doc = Document.objects.create(
                document_number=original.document_number,
                title=request.data.get('title') or original.title,
                description=request.data.get('description') or original.description,
                category=original.category,
                doc_level=original.doc_level,
                status=Document.Status.APPROVED if request.user.has_access('document.approve') else Document.Status.DRAFT,
                revision=rev_label,
                revision_number=next_rev_num,
                is_latest_revision=True,
                parent_document=root,
                cloudinary_url=upload_result['secure_url'],
                cloudinary_public_id=upload_result['public_id'],
                file_name=file.name,
                file_size=file.size,
                file_type=file_type,
                uploaded_by=request.user,
                related_part=original.related_part,
                related_machine=original.related_machine,
                effective_date=request.data.get('effective_date') or original.effective_date,
            )
            new_doc.allowed_roles.set(original.allowed_roles.all())
            DocumentActivity.objects.create(
                document=new_doc, action='revised', performed_by=request.user,
                comment=f'New revision {rev_label} uploaded. Supersedes {original.revision}.',
            )

            # If this revision is tied to an approved DCR, mark DCR as IMPLEMENTED
            if dcr_id := request.data.get('dcr_id'):
                try:
                    dcr = DocumentChangeRequest.objects.get(id=dcr_id, status=DocumentChangeRequest.Status.APPROVED)
                    dcr.implemented_revision = new_doc
                    dcr.implemented_notes = request.data.get('implementation_notes', f'Implemented with {rev_label}')
                    dcr.implemented_by = request.user
                    dcr.implemented_at = timezone.now()
                    dcr.status = DocumentChangeRequest.Status.IMPLEMENTED
                    dcr.save()
                except DocumentChangeRequest.DoesNotExist:
                    pass

        return Response(DocumentListSerializer(new_doc).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=['get'])
    def preview(self, request, pk=None):
        user = self._authenticate_request_user(request)
        if not user or not user.is_authenticated:
            return Response({'detail': 'Authentication credentials were not provided.'}, status=status.HTTP_401_UNAUTHORIZED)

        doc = self.get_object()
        if not doc.cloudinary_url:
            return Response({'error': 'No file attached.'}, status=404)

        # Enforce preview permission
        is_manager = user.is_superuser or getattr(user, 'role', '') == 'admin'
        is_owner = doc.uploaded_by_id == user.id
        is_reviewer_or_approver = (doc.reviewed_by_id == user.id) or (doc.approved_by_id == user.id)
        if not (is_manager or is_owner or is_reviewer_or_approver):
            can_preview = False
            try:
                perm = DocumentUserPermission.objects.get(document=doc, user=user)
                can_preview = perm.can_preview
            except DocumentUserPermission.DoesNotExist:
                pass

            # Approved documents are previewable by allowed roles
            if not can_preview and doc.status == Document.Status.APPROVED:
                allowed_role_slugs = [r.slug for r in doc.allowed_roles.all()]
                user_role = getattr(user, 'role', '')
                if not allowed_role_slugs or user_role in allowed_role_slugs:
                    can_preview = True

            if not can_preview:
                return Response({'error': 'You do not have permission to preview this document.'}, status=403)

        DocumentActivity.objects.create(document=doc, action='viewed', performed_by=user)
        return redirect(document_delivery_url(doc))

    @action(detail=True, methods=['get'])
    def download(self, request, pk=None):
        user = self._authenticate_request_user(request)
        if not user or not user.is_authenticated:
            return Response({'detail': 'Authentication credentials were not provided.'}, status=status.HTTP_401_UNAUTHORIZED)

        doc = self.get_object()
        if not doc.cloudinary_url:
            return Response({'error': 'No file attached.'}, status=404)

        # Enforce download permission
        is_manager = user.is_superuser or getattr(user, 'role', '') == 'admin'
        is_owner = doc.uploaded_by_id == user.id
        if not is_manager and not is_owner:
            can_download = False
            try:
                perm = DocumentUserPermission.objects.get(document=doc, user=user)
                can_download = perm.can_download
            except DocumentUserPermission.DoesNotExist:
                pass

            # Approved documents can be downloaded by users with allowed roles
            if not can_download and doc.status == Document.Status.APPROVED:
                allowed_role_slugs = [r.slug for r in doc.allowed_roles.all()]
                user_role = getattr(user, 'role', '')
                if not allowed_role_slugs or user_role in allowed_role_slugs:
                    can_download = True

            if not can_download:
                return Response({'error': 'You do not have permission to download this document.'}, status=403)

        DocumentActivity.objects.create(document=doc, action='downloaded', performed_by=user)
        return redirect(document_delivery_url(doc))

    def destroy(self, request, *args, **kwargs):
        doc = self.get_object()
        is_manager = request.user.is_superuser or getattr(request.user, 'role', '') == 'admin'
        is_owner = doc.uploaded_by_id == request.user.id
        has_delete_perm = DocumentUserPermission.objects.filter(
            document=doc, user=request.user, can_delete=True
        ).exists()

        if not (is_manager or is_owner or has_delete_perm):
            return Response({'error': 'You do not have permission to delete this document.'}, status=status.HTTP_403_FORBIDDEN)

        # In controlled document management, approved documents must be marked obsolete instead of deleted
        if doc.status == Document.Status.APPROVED:
            return Response(
                {'error': 'Approved master documents cannot be deleted. Please mark as Obsolete instead.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        doc_num = doc.document_number
        doc.delete()
        return Response({'detail': f'Document {doc_num} deleted successfully.'}, status=status.HTTP_200_OK)

    @action(detail=True, methods=['get'])
    def history(self, request, pk=None):
        doc = self.get_object()
        activities = doc.activities.select_related('performed_by').order_by('-timestamp')
        return Response(DocumentActivitySerializer(activities, many=True).data)

    @action(detail=True, methods=['post'])
    def obsolete(self, request, pk=None):
        doc = self.get_object()
        is_manager = request.user.is_superuser or getattr(request.user, 'role', '') == 'admin'
        is_owner = doc.uploaded_by_id == request.user.id
        has_approve_perm = request.user.has_access('document.approve')
        has_user_perm = DocumentUserPermission.objects.filter(
            document=doc, user=request.user, can_delete=True
        ).exists()

        if not (is_manager or is_owner or has_approve_perm or has_user_perm):
            return Response({'error': 'You do not have permission to mark this document as obsolete.'}, status=403)

        doc.status = Document.Status.OBSOLETE
        doc.save(update_fields=['status', 'updated_at'])
        DocumentActivity.objects.create(
            document=doc, action='obsoleted', performed_by=request.user,
            comment=request.data.get('comment', 'Marked obsolete.')
        )
        return Response({'status': doc.status, 'detail': 'Document marked as obsolete.'})

    @action(detail=False, methods=['get'], url_path='assignable-users')
    def assignable_users(self, request):
        """Returns all active users so anyone can be selected as reviewer or approver."""
        qs = User.objects.filter(is_active=True)
        if request.user and request.user.is_authenticated:
            qs = qs.exclude(id=request.user.id)
        eligible_users = qs.values('id', 'first_name', 'last_name', 'username', 'role', 'email').order_by('first_name', 'username')
        result = []
        for u in eligible_users:
            full_name = f"{u['first_name']} {u['last_name']}".strip() or u['username']
            result.append({
                'id': u['id'],
                'name': full_name,
                'username': u['username'],
                'role': u['role'],
                'email': u['email'],
            })
        return Response(result)


# ─────────────────────────────────────────────────────────────────────────────
# 3. DocumentChangeRequest ViewSet (Form DKI/MR/F/05)
# ─────────────────────────────────────────────────────────────────────────────

class DocumentChangeRequestViewSet(viewsets.ModelViewSet):
    """
    Complete lifecycle ViewSet for Form DKI/MR/F/05.
    Actions:
      - submit (create DCR)
      - submit_review (CFT review approval)
      - reject_review (CFT review rejection)
      - approve (MR final authorization)
      - reject_approval (MR final rejection)
      - pdf (Export ReportLab PDF)
      - assignable_users (List users for dropdowns)
    """
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        qs = DocumentChangeRequest.objects.select_related(
            'document', 'raised_by', 'assigned_cft_reviewer',
            'assigned_calibrator', 'assigned_approver',
            'reviewed_by', 'approved_by', 'rejected_by', 'implemented_revision'
        )

        tab = self.request.query_params.get('tab')
        if tab == 'my_requests':
            return qs.filter(raised_by=user).order_by('-created_at')
        elif tab == 'action_required':
            return qs.filter(
                (Q(assigned_cft_reviewer=user) & Q(status=DocumentChangeRequest.Status.AWAITING_REVIEW)) |
                (Q(assigned_calibrator=user) & Q(status=DocumentChangeRequest.Status.AWAITING_REVIEW)) |
                (Q(assigned_approver=user) & Q(status=DocumentChangeRequest.Status.AWAITING_APPROVAL))
            ).order_by('-created_at')

        # Default: if admin, show all; otherwise show requests involving user
        if user.has_access('document.dcr.approve'):
            return qs.order_by('-created_at')
        return qs.filter(
            Q(raised_by=user) |
            Q(assigned_cft_reviewer=user) |
            Q(assigned_calibrator=user) |
            Q(assigned_approver=user)
        ).order_by('-created_at')

    def get_serializer_class(self):
        if self.action in ('create',):
            return DCRCreateSerializer
        if self.action in ('retrieve',):
            return DCRDetailSerializer
        return DCRListSerializer

    def create(self, request, *args, **kwargs):
        """Submit a new Document Change Request (Form DKI/MR/F/05)."""
        if not request.user.has_access('document.dcr.create'):
            return Response(
                {'error': 'Change request creation access required.'},
                status=status.HTTP_403_FORBIDDEN
            )

        serializer = DCRCreateSerializer(data=request.data, context={'request': request})
        serializer.is_valid(raise_exception=True)

        target_doc = serializer.validated_data.get('document')
        is_manager = request.user.is_superuser or getattr(request.user, 'role', '') == 'admin'
        is_owner = target_doc and target_doc.uploaded_by_id == request.user.id
        has_edit_perm = target_doc and DocumentUserPermission.objects.filter(
            document=target_doc, user=request.user, can_edit=True
        ).exists()

        if not (is_manager or is_owner or has_edit_perm):
            return Response(
                {'error': 'You do not have permission to propose changes (DCR) for this document.'},
                status=status.HTTP_403_FORBIDDEN
            )

        with transaction.atomic():
            dcr = serializer.save(
                raised_by=request.user,
                status=DocumentChangeRequest.Status.AWAITING_REVIEW,
                date_of_receipt=timezone.now().date(),
            )
            DocumentActivity.objects.create(
                document=dcr.document,
                action='submitted_review',
                performed_by=request.user,
                comment=f"DCR Note {dcr.dcr_number} submitted by {request.user.username}.",
            )

        # Trigger In-App Notification and Asynchronous Email via Mailjet
        notify_dcr_submitted(dcr)

        return Response(DCRDetailSerializer(dcr).data, status=status.HTTP_201_CREATED)

    @action(detail=False, methods=['post'], url_path='submit')
    def submit(self, request, *args, **kwargs):
        """Alias for submit."""
        return self.create(request, *args, **kwargs)

    @action(detail=True, methods=['post'], url_path='submit-review')
    def submit_review(self, request, pk=None):
        """Assigned CFT Reviewer approves review and forwards DCR to Approver."""
        dcr = self.get_object()
        user = request.user

        is_assigned = (dcr.assigned_cft_reviewer_id == user.id)
        if not (is_assigned and user.has_access('document.dcr.review')):
            return Response({'error': 'Only the assigned CFT Reviewer or Admin can review this DCR.'}, status=403)

        if dcr.status != DocumentChangeRequest.Status.AWAITING_REVIEW:
            return Response({'error': f'DCR cannot be reviewed in status {dcr.status}.'}, status=400)

        serializer = DCRReviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        with transaction.atomic():
            dcr.review_remark = serializer.validated_data['review_remark']
            dcr.implementation_date = serializer.validated_data.get('implementation_date')
            dcr.cft_remarks = serializer.validated_data.get('cft_remarks', '')
            dcr.calibrator_remarks = serializer.validated_data.get('calibrator_remarks', '')
            dcr.reviewed_by = user
            dcr.date_of_review = timezone.now()
            dcr.status = DocumentChangeRequest.Status.AWAITING_APPROVAL
            dcr.save()

            DocumentActivity.objects.create(
                document=dcr.document,
                action='comment',
                performed_by=user,
                comment=f"DCR {dcr.dcr_number} reviewed by {user.username}. Forwarded for final approval.",
            )

        # Notify assigned Approver via in-app notification & Mailjet email
        notify_dcr_reviewed(dcr)

        return Response(DCRDetailSerializer(dcr).data)

    @action(detail=True, methods=['post'], url_path='submit_review')
    def submit_review_alias(self, request, pk=None):
        return self.submit_review(request, pk=pk)

    @action(detail=True, methods=['post'], url_path='reject-review')
    def reject_review(self, request, pk=None):
        """CFT Reviewer rejects the DCR (workflow terminates, requestor notified)."""
        dcr = self.get_object()
        user = request.user

        is_assigned = (dcr.assigned_cft_reviewer_id == user.id)
        if not (is_assigned and user.has_access('document.dcr.review')):
            return Response({'error': 'Only the assigned CFT Reviewer or Admin can reject this DCR.'}, status=403)

        serializer = DCRRejectSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        reason = serializer.validated_data['rejection_reason']

        with transaction.atomic():
            dcr.rejection_stage = 'review'
            dcr.rejection_reason = reason
            dcr.rejected_by = user
            dcr.date_of_rejection = timezone.now()
            dcr.status = DocumentChangeRequest.Status.REJECTED
            dcr.save()

            DocumentActivity.objects.create(
                document=dcr.document,
                action='rejected',
                performed_by=user,
                comment=f"DCR {dcr.dcr_number} rejected at CFT Review by {user.username}. Reason: {reason}",
            )

        notify_dcr_rejected(dcr, 'review', user, reason)

        return Response(DCRDetailSerializer(dcr).data)

    @action(detail=True, methods=['post'], url_path='reject_review')
    def reject_review_alias(self, request, pk=None):
        return self.reject_review(request, pk=pk)

    @action(detail=True, methods=['post'], url_path='approve')
    def approve(self, request, pk=None):
        """Assigned Approver grants final authorization for DCR."""
        dcr = self.get_object()
        user = request.user

        is_assigned = (dcr.assigned_approver_id == user.id)
        if not (is_assigned and user.has_access('document.dcr.approve')):
            return Response({'error': 'Only the assigned Approver or Admin can grant final DCR approval.'}, status=403)

        if dcr.status != DocumentChangeRequest.Status.AWAITING_APPROVAL:
            return Response({'error': f'DCR cannot be approved in status {dcr.status}. Review must be completed first.'}, status=400)

        serializer = DCRApproveSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        with transaction.atomic():
            dcr.mr_remarks = serializer.validated_data.get('mr_remarks', '')
            dcr.approved_by = user
            dcr.date_of_approval = timezone.now()
            dcr.status = DocumentChangeRequest.Status.APPROVED
            dcr.save()

            # Update document status to approved
            doc = dcr.document
            doc.status = Document.Status.APPROVED
            doc.save(update_fields=['status'])

            DocumentActivity.objects.create(
                document=dcr.document,
                action='approved',
                performed_by=user,
                comment=f"DCR {dcr.dcr_number} approved by {user.username}. Unlocked for new revision upload.",
            )

        notify_dcr_approved(dcr)

        return Response(DCRDetailSerializer(dcr).data)

    @action(detail=True, methods=['post'], url_path='reject-approval')
    def reject_approval(self, request, pk=None):
        """Approver rejects DCR at final approval stage."""
        dcr = self.get_object()
        user = request.user

        is_assigned = (dcr.assigned_approver_id == user.id)
        if not (is_assigned and user.has_access('document.dcr.approve')):
            return Response({'error': 'Only the assigned Approver or Admin can reject DCR at approval stage.'}, status=403)

        serializer = DCRRejectSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        reason = serializer.validated_data['rejection_reason']

        with transaction.atomic():
            dcr.rejection_stage = 'approval'
            dcr.rejection_reason = reason
            dcr.rejected_by = user
            dcr.date_of_rejection = timezone.now()
            dcr.status = DocumentChangeRequest.Status.REJECTED
            dcr.save()

            DocumentActivity.objects.create(
                document=dcr.document,
                action='rejected',
                performed_by=user,
                comment=f"DCR {dcr.dcr_number} rejected at final approval by {user.username}. Reason: {reason}",
            )

        notify_dcr_rejected(dcr, 'approval', user, reason)

        return Response(DCRDetailSerializer(dcr).data)

    @action(detail=True, methods=['post'], url_path='reject_approval')
    def reject_approval_alias(self, request, pk=None):
        return self.reject_approval(request, pk=pk)

    @action(detail=True, methods=['get'], url_path='pdf')
    def pdf(self, request, pk=None):
        """Download Form DKI/MR/F/05 formatted PDF."""
        dcr = self.get_object()
        pdf_bytes = generate_dcr_pdf(dcr)
        response = HttpResponse(pdf_bytes, content_type='application/pdf')
        filename = f"{dcr.dcr_number.replace('/', '_')}.pdf"
        response['Content-Disposition'] = f'inline; filename="{filename}"'
        return response

    @action(detail=False, methods=['get'], url_path='assignable-users')
    def assignable_users(self, request):
        """Returns all active users so anyone can be selected as reviewer or approver."""
        qs = User.objects.filter(is_active=True)
        if request.user and request.user.is_authenticated:
            qs = qs.exclude(id=request.user.id)
        eligible_users = qs.order_by('first_name', 'username')

        result = []
        for u in eligible_users:
            can_review = u.has_access('document.dcr.review')
            can_approve = u.has_access('document.dcr.approve')
            if not (can_review or can_approve):
                continue
            full_name = u.get_full_name() or u.username
            result.append({
                'id': u.id,
                'name': full_name,
                'username': u.username,
                'role': u.role,
                'can_review': can_review,
                'can_approve': can_approve,
                'email': u.email,
            })
        return Response(result)

    @action(detail=False, methods=['get'], url_path='assignable_users')
    def assignable_users_alias(self, request):
        return self.assignable_users(request)


# ─────────────────────────────────────────────────────────────────────────────
# 4. DCRNotification ViewSet (Realtime Notification Popups & Bell)
# ─────────────────────────────────────────────────────────────────────────────

class DCRNotificationViewSet(viewsets.ReadOnlyModelViewSet):
    """Provides realtime in-app notifications for the logged-in user."""
    serializer_class = DCRNotificationSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = DCRNotification.objects.filter(recipient=self.request.user).order_by('-created_at')
        is_read_param = self.request.query_params.get('is_read')
        if is_read_param is not None:
            if is_read_param.lower() in ('true', '1'):
                qs = qs.filter(is_read=True)
            elif is_read_param.lower() in ('false', '0'):
                qs = qs.filter(is_read=False)

        all_param = self.request.query_params.get('all', '').lower()
        # Detail actions call get_object(), which must filter before slicing.
        if getattr(self, 'action', None) != 'list':
            return qs

        if all_param in ('true', '1', 'yes'):
            return qs[:250]

        limit = self.request.query_params.get('limit')
        if limit:
            try:
                return qs[:int(limit)]
            except (ValueError, TypeError):
                pass

        return qs[:30]

    @action(detail=True, methods=['post'], url_path='mark-unread')
    def mark_unread(self, request, pk=None):
        notif = self.get_object()
        notif.is_read = False
        notif.save(update_fields=['is_read'])
        return Response({'status': 'marked_unread'})

    @action(detail=False, methods=['get'], url_path='unread-count')
    def unread_count(self, request):
        count = DCRNotification.objects.filter(recipient=request.user, is_read=False).count()
        return Response({'unread_count': count})

    @action(detail=False, methods=['get'], url_path='unread_count')
    def unread_count_alias(self, request):
        return self.unread_count(request)

    @action(detail=True, methods=['post'], url_path='mark-read')
    def mark_read(self, request, pk=None):
        notif = self.get_object()
        notif.is_read = True
        notif.save(update_fields=['is_read'])
        return Response({'status': 'marked_read'})

    @action(detail=True, methods=['post'], url_path='mark_read')
    def mark_read_alias(self, request, pk=None):
        return self.mark_read(request, pk=pk)

    @action(detail=False, methods=['post'], url_path='mark-all-read')
    def mark_all_read(self, request):
        DCRNotification.objects.filter(recipient=request.user, is_read=False).update(is_read=True)
        return Response({'status': 'all_marked_read'})

    @action(detail=False, methods=['post'], url_path='mark_all_read')
    def mark_all_read_alias(self, request):
        return self.mark_all_read(request)
