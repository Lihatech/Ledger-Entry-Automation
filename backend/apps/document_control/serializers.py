"""
Serializers for the Document Control module.
"""

import json

from django.db import models
from rest_framework import serializers
from .models import (
    Document,
    DocumentActivity,
    DocumentChangeRequest,
    DCRNotification,
    DocumentUserPermission,
)
from apps.users.models import AccessRole
from .storage import document_delivery_url


def get_user_display(user):
    if not user:
        return ''
    name = f"{user.first_name} {user.last_name}".strip()
    return name or user.username


class DocumentActivitySerializer(serializers.ModelSerializer):
    performed_by_name = serializers.SerializerMethodField()

    class Meta:
        model = DocumentActivity
        fields = ['id', 'action', 'performed_by', 'performed_by_name', 'comment', 'timestamp']
        read_only_fields = fields

    def get_performed_by_name(self, obj):
        return get_user_display(obj.performed_by) or 'System'


class DocumentListSerializer(serializers.ModelSerializer):
    """Lightweight serializer for document list views."""
    doc_level_display = serializers.CharField(source='get_doc_level_display', read_only=True)
    uploaded_by_name  = serializers.SerializerMethodField()
    reviewed_by_name  = serializers.SerializerMethodField()
    approved_by_name  = serializers.SerializerMethodField()
    allowed_roles     = serializers.SerializerMethodField()
    delivery_url      = serializers.SerializerMethodField()
    cloudinary_url    = serializers.SerializerMethodField()
    file_size_display = serializers.ReadOnlyField()
    my_permissions    = serializers.SerializerMethodField()

    class Meta:
        model = Document
        fields = [
            'id', 'document_number', 'title', 'description',
            'doc_level', 'doc_level_display',
            'status', 'revision', 'revision_number', 'is_latest_revision',
            'cloudinary_url', 'delivery_url', 'file_name', 'file_size', 'file_size_display', 'file_type',
            'uploaded_by', 'uploaded_by_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at',
            'approved_by', 'approved_by_name', 'approved_at',
            'allowed_roles',
            'my_permissions',
            'revision_date', 'effective_date', 'expiry_date',
            'created_at', 'updated_at',
        ]
        read_only_fields = fields

    def get_uploaded_by_name(self, obj):
        return get_user_display(obj.uploaded_by)

    def get_reviewed_by_name(self, obj):
        return get_user_display(obj.reviewed_by)

    def get_approved_by_name(self, obj):
        return get_user_display(obj.approved_by)

    def _get_user_perm(self, obj):
        request = self.context.get('request')
        if not request or not request.user or not request.user.is_authenticated:
            return None
        cache_attr = f'_doc_perm_{obj.id}'
        if hasattr(request, cache_attr):
            return getattr(request, cache_attr)
        try:
            perm = DocumentUserPermission.objects.get(document=obj, user=request.user)
        except DocumentUserPermission.DoesNotExist:
            perm = None
        setattr(request, cache_attr, perm)
        return perm

    def _user_can_preview(self, obj):
        request = self.context.get('request')
        if not request or not request.user or not request.user.is_authenticated:
            return False
        user = request.user
        is_admin = user.is_superuser or getattr(user, 'role', '') == 'admin'
        is_uploader = obj.uploaded_by_id == user.id
        is_reviewer_or_approver = (obj.reviewed_by_id == user.id) or (obj.approved_by_id == user.id)
        if is_admin or is_uploader or is_reviewer_or_approver:
            return True

        perm = self._get_user_perm(obj)
        if perm and perm.can_preview:
            return True

        # Approved documents require an explicit allowed role. Empty role
        # assignments must not expose private document URLs by default.
        if obj.status == Document.Status.APPROVED:
            allowed_role_slugs = [role.slug for role in obj.allowed_roles.all()]
            user_role = getattr(user, 'role', '')
            if allowed_role_slugs and user_role in allowed_role_slugs:
                return True

        return False

    def get_delivery_url(self, obj):
        if self._user_can_preview(obj):
            return document_delivery_url(obj)
        return None

    def get_cloudinary_url(self, obj):
        if self._user_can_preview(obj):
            return obj.cloudinary_url
        return None

    def get_allowed_roles(self, obj):
        return [
            {'slug': role.slug, 'name': role.name}
            for role in obj.allowed_roles.all()
        ]

    def get_my_permissions(self, obj):
        """Return the logged-in user's permission flags for this document."""
        request = self.context.get('request')
        if not request or not request.user or not request.user.is_authenticated:
            return None
        user = request.user
        # Admins and the uploader always have full access
        is_admin = user.is_superuser or getattr(user, 'role', '') == 'admin'
        is_uploader = obj.uploaded_by_id == user.id
        if is_admin or is_uploader:
            return {
                'can_preview': True, 'can_download': True,
                'can_print': True, 'can_edit': True, 'can_delete': True,
                'can_manage_access': True,
            }
        is_reviewer_or_approver = (obj.reviewed_by_id == user.id) or (obj.approved_by_id == user.id)

        # Check role-based permission for approved documents
        is_approved = obj.status == Document.Status.APPROVED
        role_allowed = False
        if is_approved:
            allowed_role_slugs = [role.slug for role in obj.allowed_roles.all()]
            user_role = getattr(user, 'role', '')
            role_allowed = user_role in allowed_role_slugs

        can_view_approved = is_approved and role_allowed

        perm = self._get_user_perm(obj)
        if perm:
            return {
                'can_preview':  perm.can_preview or is_reviewer_or_approver or can_view_approved,
                'can_download': perm.can_download or can_view_approved,
                'can_print':    perm.can_print or can_view_approved,
                'can_edit':     perm.can_edit,
                'can_delete':   perm.can_delete,
                'can_manage_access': False,
            }
        return {
            'can_preview': is_reviewer_or_approver or can_view_approved,
            'can_download': can_view_approved,
            'can_print': can_view_approved,
            'can_edit': False,
            'can_delete': False,
            'can_manage_access': False,
        }

class DocumentDetailSerializer(DocumentListSerializer):
    """Full detail serializer including activities, revision tree, and links."""
    activities           = DocumentActivitySerializer(many=True, read_only=True)
    revisions            = serializers.SerializerMethodField()
    related_part_name    = serializers.CharField(source='related_part.name', read_only=True, default=None)
    related_machine_name = serializers.CharField(source='related_machine.name', read_only=True, default=None)

    class Meta(DocumentListSerializer.Meta):
        fields = DocumentListSerializer.Meta.fields + [
            'activities', 'revisions',
            'related_part', 'related_part_name',
            'related_machine', 'related_machine_name',
            'parent_document',
        ]
        read_only_fields = fields

    def get_revisions(self, obj):
        """Return all revisions in this document chain (oldest first)."""
        root = obj.parent_document if obj.parent_document else obj
        qs = Document.objects.filter(
            models.Q(id=root.id) | models.Q(parent_document=root)
        ).order_by('revision_number').values(
            'id', 'revision', 'revision_number', 'status',
            'created_at', 'is_latest_revision', 'uploaded_by__username'
        )
        return list(qs)


class DocumentCreateSerializer(serializers.ModelSerializer):
    """
    Used for POST (upload) : accepts multipart/form-data.
    The file payload is handled directly in the view.
    """
    document_number = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    revision        = serializers.CharField(required=False, allow_blank=True, default='0')
    revision_date   = serializers.DateField(required=False, allow_null=True)
    status          = serializers.CharField(required=False, allow_blank=True, default='draft')
    allowed_role_slugs = serializers.ListField(
        child=serializers.CharField(), required=False, allow_empty=True, write_only=True
    )

    class Meta:
        model = Document
        fields = [
            'document_number', 'title', 'description', 'doc_level',
            'revision', 'revision_date',
            'effective_date', 'expiry_date',
            'reviewed_by', 'approved_by', 'status',
            'related_part', 'related_machine',
            'allowed_role_slugs',
        ]

    def to_internal_value(self, data):
        # Multipart requests arrive as a QueryDict. Convert it to a regular
        # mapping before replacing the JSON role list; assigning a Python list
        # back into QueryDict turns it into a string and ListField rejects it.
        if hasattr(data, 'items'):
            data = {key: value for key, value in data.items()}
        else:
            data = dict(data)
        raw_roles = data.get('allowed_role_slugs')
        if isinstance(raw_roles, str):
            try:
                data['allowed_role_slugs'] = json.loads(raw_roles)
            except (TypeError, ValueError):
                data['allowed_role_slugs'] = [slug.strip() for slug in raw_roles.split(',') if slug.strip()]
        return super().to_internal_value(data)

    def validate_allowed_role_slugs(self, value):
        slugs = sorted(set(value))
        roles = list(AccessRole.objects.filter(slug__in=slugs))
        found = {role.slug for role in roles}
        unknown = sorted(set(slugs) - found)
        if unknown:
            raise serializers.ValidationError(f'Unknown roles: {", ".join(unknown)}')
        return roles

    def validate(self, attrs):
        request = self.context.get('request')
        user = getattr(request, 'user', None)
        if user and user.is_authenticated:
            reviewed_by = attrs.get('reviewed_by')
            approved_by = attrs.get('approved_by')
            if reviewed_by and reviewed_by.id == user.id:
                raise serializers.ValidationError({"reviewed_by": "You cannot assign yourself as the reviewer."})
            if approved_by and approved_by.id == user.id:
                raise serializers.ValidationError({"approved_by": "You cannot assign yourself as the approver."})
        return attrs

    def create(self, validated_data):
        roles = validated_data.pop('allowed_role_slugs', [])
        document = super().create(validated_data)
        document.allowed_roles.set(roles)
        return document


class DocumentAccessSerializer(serializers.Serializer):
    """Validates the role allow-list edited after a document is uploaded."""

    allowed_role_slugs = serializers.ListField(
        child=serializers.CharField(), required=True, allow_empty=True
    )

    def validate_allowed_role_slugs(self, value):
        slugs = sorted(set(value))
        roles = list(AccessRole.objects.filter(slug__in=slugs))
        found = {role.slug for role in roles}
        unknown = sorted(set(slugs) - found)
        if unknown:
            raise serializers.ValidationError(f'Unknown roles: {", ".join(unknown)}')
        return roles

# ── New per-user document permission serializers ───────────────────────────────

class DocumentUserPermissionReadSerializer(serializers.ModelSerializer):
    """Read serializer — populates the Access modal user table."""
    user_id   = serializers.UUIDField(source='user.id', read_only=True)
    full_name = serializers.SerializerMethodField()
    username  = serializers.CharField(source='user.username', read_only=True)
    role      = serializers.CharField(source='user.role', read_only=True)

    class Meta:
        model = DocumentUserPermission
        fields = [
            'user_id', 'full_name', 'username', 'role',
            'can_preview', 'can_download', 'can_print', 'can_edit', 'can_delete',
        ]

    def get_full_name(self, obj):
        return get_user_display(obj.user)


class BulkDocumentAccessSerializer(serializers.Serializer):
    """Accepts the full permission matrix for one document in a single PATCH."""

    class PermissionEntrySerializer(serializers.Serializer):
        user_id      = serializers.IntegerField()
        can_preview  = serializers.BooleanField(default=False)
        can_download = serializers.BooleanField(default=False)
        can_print    = serializers.BooleanField(default=False)
        can_edit     = serializers.BooleanField(default=False)
        can_delete   = serializers.BooleanField(default=False)

    permissions = PermissionEntrySerializer(many=True)


# ── DCR Serializers (DKI/MR/F/05) ─────────────────────────────────────────────

class DCRCreateSerializer(serializers.ModelSerializer):
    """
    Serializer for creating a new Document Change Request.
    Validates that requestor and assigned reviewers meet role criteria.
    """
    class Meta:
        model = DocumentChangeRequest
        fields = [
            'document', 'document_description', 'basis_for_change',
            'form_doc_no', 'issue_no_date', 'rev_no_date',
            'assigned_cft_reviewer', 'assigned_calibrator', 'assigned_approver',
        ]

    def to_internal_value(self, data):
        data = data.copy() if hasattr(data, 'copy') else dict(data)
        if 'document_id' in data and 'document' not in data:
            data['document'] = data['document_id']
        if 'reason_for_change' in data and 'basis_for_change' not in data:
            data['basis_for_change'] = data['reason_for_change']
        if 'nature_of_change' in data and 'document_description' not in data:
            data['document_description'] = data['nature_of_change'] or data.get('reason_for_change', 'Document change requested')
        elif not data.get('document_description') and data.get('basis_for_change'):
            data['document_description'] = data['basis_for_change']
        if 'reviewer_id' in data and 'assigned_cft_reviewer' not in data:
            data['assigned_cft_reviewer'] = data['reviewer_id']
        if 'calibrator_id' in data and 'assigned_calibrator' not in data:
            data['assigned_calibrator'] = data['calibrator_id']
        if 'approver_id' in data and 'assigned_approver' not in data:
            data['assigned_approver'] = data['approver_id']
        return super().to_internal_value(data)

    def validate(self, attrs):
        user = self.context['request'].user
        if not user.has_access('document.dcr.create'):
            raise serializers.ValidationError(
                "Change request creation access required."
            )

        cft = attrs.get('assigned_cft_reviewer')
        cal = attrs.get('assigned_calibrator')
        app = attrs.get('assigned_approver')

        if not cft:
            raise serializers.ValidationError({"assigned_cft_reviewer": "A CFT Reviewer must be assigned."})
        if cft.id == user.id:
            raise serializers.ValidationError({"assigned_cft_reviewer": "You cannot assign yourself as the CFT Reviewer for your own change request."})
        if not cft.has_access('document.dcr.review'):
            raise serializers.ValidationError({"assigned_cft_reviewer": "Reviewer needs change request review access."})

        if cal and not cal.has_access('document.dcr.review'):
            raise serializers.ValidationError({"assigned_calibrator": "Calibrator needs change request review access."})

        if not app:
            raise serializers.ValidationError({"assigned_approver": "An Approver must be assigned."})
        if app.id == user.id:
            raise serializers.ValidationError({"assigned_approver": "You cannot assign yourself as the Approver for your own change request."})
        if not app.has_access('document.dcr.approve'):
            raise serializers.ValidationError({"assigned_approver": "Approver needs change request approval access."})

        return attrs


class DCRReviewSerializer(serializers.Serializer):
    """Payload when assigned CFT Reviewer submits their review."""
    review_remark = serializers.CharField(required=False, allow_blank=True)
    implementation_date = serializers.DateField(required=False, allow_null=True)
    cft_remarks = serializers.CharField(required=False, allow_blank=True)
    calibrator_remarks = serializers.CharField(required=False, allow_blank=True)

    def to_internal_value(self, data):
        data = data.copy() if hasattr(data, 'copy') else dict(data)
        if 'comments' in data and not data.get('review_remark'):
            data['review_remark'] = data['comments']
        res = super().to_internal_value(data)
        if not res.get('review_remark'):
            res['review_remark'] = 'Review completed and verified.'
        return res


class DCRApproveSerializer(serializers.Serializer):
    """Payload when assigned Approver stamps final approval."""
    mr_remarks = serializers.CharField(required=False, allow_blank=True)

    def to_internal_value(self, data):
        data = data.copy() if hasattr(data, 'copy') else dict(data)
        if 'comments' in data and not data.get('mr_remarks'):
            data['mr_remarks'] = data['comments']
        return super().to_internal_value(data)


class DCRRejectSerializer(serializers.Serializer):
    """Payload when either Reviewer or Approver rejects the DCR."""
    rejection_reason = serializers.CharField(required=False, allow_blank=True)

    def to_internal_value(self, data):
        data = data.copy() if hasattr(data, 'copy') else dict(data)
        if 'rejected_reason' in data and not data.get('rejection_reason'):
            data['rejection_reason'] = data['rejected_reason']
        res = super().to_internal_value(data)
        if not res.get('rejection_reason'):
            raise serializers.ValidationError({'rejection_reason': 'Rejection reason is required.'})
        return res


class DCRListSerializer(serializers.ModelSerializer):
    """List serializer for DCR records."""
    document_title       = serializers.CharField(source='document.title', read_only=True)
    document_number      = serializers.CharField(source='document.document_number', read_only=True)
    document_revision    = serializers.CharField(source='document.revision', read_only=True)
    document_level       = serializers.CharField(source='document.doc_level', read_only=True)
    raised_by_name       = serializers.SerializerMethodField()
    cft_reviewer_name    = serializers.SerializerMethodField()
    calibrator_name      = serializers.SerializerMethodField()
    approver_name        = serializers.SerializerMethodField()

    class Meta:
        model = DocumentChangeRequest
        fields = [
            'id', 'dcr_number', 'document',
            'form_doc_no', 'issue_no_date', 'rev_no_date',
            'document_title', 'document_number', 'document_revision', 'document_level',
            'raised_by', 'raised_by_name', 'date_of_receipt',
            'assigned_cft_reviewer', 'cft_reviewer_name',
            'assigned_calibrator', 'calibrator_name',
            'assigned_approver', 'approver_name',
            'status', 'created_at', 'updated_at',
        ]
        read_only_fields = fields

    def get_raised_by_name(self, obj):
        return get_user_display(obj.raised_by)

    def get_cft_reviewer_name(self, obj):
        return get_user_display(obj.assigned_cft_reviewer)

    def get_calibrator_name(self, obj):
        return get_user_display(obj.assigned_calibrator)

    def get_approver_name(self, obj):
        return get_user_display(obj.assigned_approver)


class DCRDetailSerializer(DCRListSerializer):
    """Full detail view matching Form DKI/MR/F/05."""
    reviewed_by_name   = serializers.SerializerMethodField()
    approved_by_name   = serializers.SerializerMethodField()
    rejected_by_name   = serializers.SerializerMethodField()
    implemented_by_name = serializers.SerializerMethodField()
    cloudinary_url     = serializers.CharField(source='document.cloudinary_url', read_only=True)
    company_name       = serializers.SerializerMethodField()
    company_logo_url   = serializers.SerializerMethodField()

    class Meta(DCRListSerializer.Meta):
        fields = DCRListSerializer.Meta.fields + [
            'document_description', 'basis_for_change',
            'review_remark', 'implementation_date', 'cft_remarks', 'calibrator_remarks',
            'reviewed_by', 'reviewed_by_name', 'date_of_review',
            'mr_remarks', 'approved_by', 'approved_by_name', 'date_of_approval',
            'rejection_stage', 'rejection_reason', 'rejected_by', 'rejected_by_name', 'date_of_rejection',
            'implemented_revision', 'implemented_notes', 'implemented_by', 'implemented_by_name', 'implemented_at',
            'cloudinary_url', 'company_name', 'company_logo_url',
        ]
        read_only_fields = fields

    def get_company_name(self, obj):
        from apps.machines.models import Factory
        f = Factory.objects.filter(is_active=True).first() or Factory.objects.first()
        return f.name if (f and f.name) else 'Company Name'

    def get_company_logo_url(self, obj):
        from apps.machines.models import Factory
        f = Factory.objects.filter(is_active=True).first() or Factory.objects.first()
        return f.logo_url if (f and f.logo_url) else ''

    def get_reviewed_by_name(self, obj):
        return get_user_display(obj.reviewed_by)

    def get_approved_by_name(self, obj):
        return get_user_display(obj.approved_by)

    def get_rejected_by_name(self, obj):
        return get_user_display(obj.rejected_by)

    def get_implemented_by_name(self, obj):
        return get_user_display(obj.implemented_by)


class DCRNotificationSerializer(serializers.ModelSerializer):
    """Serializer for in-app notification bell (both DCRs and Direct Documents)."""
    dcr_number = serializers.CharField(source='dcr.dcr_number', read_only=True, default='')
    document_title = serializers.SerializerMethodField()

    class Meta:
        model = DCRNotification
        fields = [
            'id', 'dcr', 'dcr_number', 'document', 'document_title',
            'recipient', 'title', 'message', 'action_type',
            'action_url', 'is_read', 'created_at',
        ]
        read_only_fields = fields

    def get_document_title(self, obj):
        if obj.document:
            return obj.document.title
        if obj.dcr and obj.dcr.document:
            return obj.dcr.document.title
        return ''

