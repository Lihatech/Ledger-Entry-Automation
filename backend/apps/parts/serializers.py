from rest_framework import serializers
from .models import (
    Part, InspectionTemplate, InspectionParameter, ProcessParameter,
    DrawingDocument, DrawingVersion, ControlPlanDocument, ControlPlanVersion,
    TemplateChangeRequest
)


class ProcessParameterSerializer(serializers.ModelSerializer):
    class Meta:
        model  = ProcessParameter
        fields = [
            'id', 'template', 'parameter_code', 'parameter_name', 'description',
            'data_type', 'measurement_type', 'unit', 'specification',
            'nominal_value', 'upper_tolerance', 'lower_tolerance',
            'upper_limit', 'lower_limit',
            'is_required', 'is_active', 'sequence_order',
        ]
        read_only_fields = ['upper_limit', 'lower_limit']



class InspectionParameterSerializer(serializers.ModelSerializer):
    tolerance_range = serializers.ReadOnlyField()

    class Meta:
        model  = InspectionParameter
        fields = [
            'id', 'parameter_code', 'parameter_name', 'unit',
            'nominal_value', 'upper_tolerance', 'lower_tolerance',
            'upper_limit', 'lower_limit',
            'measurement_type', 'is_critical', 'sequence_order',
            'measurement_technique', 'sample_size', 'control_method',
            'voice_prompt', 'tolerance_range',
        ]
        read_only_fields = ['upper_limit', 'lower_limit']


def get_user_display(user):
    if not user:
        return ''
    name = f"{user.first_name} {user.last_name}".strip()
    return name or user.username


class InspectionTemplateSerializer(serializers.ModelSerializer):
    parameters         = InspectionParameterSerializer(many=True, read_only=True)
    process_parameters = ProcessParameterSerializer(many=True, read_only=True)
    part_number        = serializers.CharField(source='part.part_number', read_only=True)
    part_name          = serializers.CharField(source='part.part_name', read_only=True)
    created_by_name    = serializers.SerializerMethodField()
    assigned_reviewer_name = serializers.SerializerMethodField()
    reviewed_by_name   = serializers.SerializerMethodField()
    assigned_approver_name = serializers.SerializerMethodField()
    approved_by_name   = serializers.SerializerMethodField()
    rejected_by_name   = serializers.SerializerMethodField()
    status_display     = serializers.CharField(source='get_status_display', read_only=True)
    configured_parameter_count = serializers.ReadOnlyField()
    is_configuration_complete = serializers.ReadOnlyField()
    active_dcrs_count  = serializers.SerializerMethodField()
    has_pending_dcr    = serializers.SerializerMethodField()

    class Meta:
        model  = InspectionTemplate
        fields = [
            'id', 'name', 'part', 'part_number', 'part_name',
            'inspection_type', 'version', 'operation_key', 'target_parameter_count',
            'configured_parameter_count', 'is_configuration_complete',
            'is_active', 'is_published', 'published_at', 'cycle_time_mins',
            'status', 'status_display',
            'created_by', 'created_by_name', 'created_at',
            'assigned_reviewer', 'assigned_reviewer_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'review_comments',
            'assigned_approver', 'assigned_approver_name',
            'approved_by', 'approved_by_name', 'approved_at', 'approval_comments',
            'rejected_by', 'rejected_by_name', 'rejection_reason',
            'active_dcrs_count', 'has_pending_dcr',
            'parameters', 'process_parameters',
        ]
        read_only_fields = [
            'part', 'version', 'operation_key', 'created_at', 'published_at',
            'reviewed_at', 'approved_at', 'status_display'
        ]

    def get_active_dcrs_count(self, obj):
        return obj.change_requests.filter(status__in=['submitted', 'awaiting_review', 'reviewed']).count()

    def get_has_pending_dcr(self, obj):
        return obj.change_requests.filter(status__in=['submitted', 'awaiting_review', 'reviewed']).exists()

    def get_created_by_name(self, obj):
        return get_user_display(obj.created_by)

    def get_assigned_reviewer_name(self, obj):
        return get_user_display(obj.assigned_reviewer)

    def get_reviewed_by_name(self, obj):
        return get_user_display(obj.reviewed_by)

    def get_assigned_approver_name(self, obj):
        return get_user_display(obj.assigned_approver)

    def get_approved_by_name(self, obj):
        return get_user_display(obj.approved_by)

    def get_rejected_by_name(self, obj):
        return get_user_display(obj.rejected_by)


class InspectionTemplateListSerializer(serializers.ModelSerializer):
    """Lightweight : for listing templates without parameter details."""
    part_number = serializers.CharField(source='part.part_number', read_only=True)
    parameter_count = serializers.IntegerField(source='parameters.count', read_only=True)
    configured_parameter_count = serializers.ReadOnlyField()
    is_configuration_complete = serializers.ReadOnlyField()
    status_display = serializers.CharField(source='get_status_display', read_only=True)
    created_by_name = serializers.SerializerMethodField()
    assigned_reviewer_name = serializers.SerializerMethodField()
    reviewed_by_name = serializers.SerializerMethodField()
    assigned_approver_name = serializers.SerializerMethodField()
    approved_by_name = serializers.SerializerMethodField()
    rejected_by_name = serializers.SerializerMethodField()
    active_dcrs_count = serializers.SerializerMethodField()
    has_pending_dcr   = serializers.SerializerMethodField()

    class Meta:
        model  = InspectionTemplate
        fields = [
            'id', 'name', 'part_number', 'inspection_type', 'version', 'operation_key', 'is_active',
            'is_published', 'published_at', 'cycle_time_mins',
            'status', 'status_display',
            'created_by', 'created_by_name', 'created_at',
            'assigned_reviewer', 'assigned_reviewer_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'review_comments',
            'assigned_approver', 'assigned_approver_name',
            'approved_by', 'approved_by_name', 'approved_at', 'approval_comments',
            'rejected_by', 'rejected_by_name', 'rejection_reason',
            'active_dcrs_count', 'has_pending_dcr',
            'parameter_count', 'target_parameter_count',
            'configured_parameter_count', 'is_configuration_complete'
        ]

    def get_active_dcrs_count(self, obj):
        return obj.change_requests.filter(status__in=['submitted', 'awaiting_review', 'reviewed']).count()

    def get_has_pending_dcr(self, obj):
        return obj.change_requests.filter(status__in=['submitted', 'awaiting_review', 'reviewed']).exists()

    def get_created_by_name(self, obj):
        return get_user_display(obj.created_by)

    def get_assigned_reviewer_name(self, obj):
        return get_user_display(obj.assigned_reviewer)

    def get_reviewed_by_name(self, obj):
        return get_user_display(obj.reviewed_by)

    def get_assigned_approver_name(self, obj):
        return get_user_display(obj.assigned_approver)

    def get_approved_by_name(self, obj):
        return get_user_display(obj.approved_by)

    def get_rejected_by_name(self, obj):
        return get_user_display(obj.rejected_by)


class PartSerializer(serializers.ModelSerializer):
    machine_name = serializers.CharField(source='machine.name', read_only=True)
    machine_code = serializers.CharField(source='machine.machine_code', read_only=True)
    created_by_name = serializers.CharField(source='created_by.get_full_name', read_only=True)
    templates    = InspectionTemplateListSerializer(many=True, read_only=True)

    class Meta:
        model  = Part
        fields = [
            'id', 'part_number', 'part_name', 'description',
            'drawing_number', 'revision',
            'machine', 'machine_name', 'machine_code',
            'is_active', 'created_by', 'created_by_name',
            'created_at', 'templates',
        ]
        read_only_fields = ['created_at']


class PartListSerializer(serializers.ModelSerializer):
    """Lightweight : for dropdowns on Flutter."""
    machine_code = serializers.CharField(source='machine.machine_code', read_only=True)

    class Meta:
        model  = Part
        fields = ['id', 'part_number', 'part_name', 'machine_code', 'revision']


class GlobalInspectionParameterSerializer(InspectionParameterSerializer):
    template_name = serializers.CharField(source='template.name', read_only=True)
    part_number = serializers.CharField(source='template.part.part_number', read_only=True)
    machine_code = serializers.CharField(source='template.part.machine.machine_code', read_only=True)
    created_by_name = serializers.CharField(source='template.created_by.get_full_name', read_only=True)
    created_at = serializers.DateTimeField(source='template.created_at', read_only=True, format='%d %b %Y, %I:%M %p')

    class Meta(InspectionParameterSerializer.Meta):
        fields = InspectionParameterSerializer.Meta.fields + ['template_name', 'part_number', 'machine_code', 'created_by_name', 'created_at']

class GlobalProcessParameterSerializer(ProcessParameterSerializer):
    template_name = serializers.CharField(source='template.name', read_only=True)
    part_number = serializers.CharField(source='template.part.part_number', read_only=True)
    machine_code = serializers.CharField(source='template.part.machine.machine_code', read_only=True)
    created_by_name = serializers.CharField(source='template.created_by.get_full_name', read_only=True)
    created_at = serializers.DateTimeField(source='template.created_at', read_only=True, format='%d %b %Y, %I:%M %p')

    class Meta(ProcessParameterSerializer.Meta):
        fields = ProcessParameterSerializer.Meta.fields + ['template_name', 'part_number', 'machine_code', 'created_by_name', 'created_at']


# ─────────────────────────────────────────────────────────────
# Drawing & Control Plan Serializers
# ─────────────────────────────────────────────────────────────

class DrawingVersionSerializer(serializers.ModelSerializer):
    uploaded_by_name = serializers.CharField(source='uploaded_by.get_full_name', read_only=True)
    file_url = serializers.SerializerMethodField()

    class Meta:
        model = DrawingVersion
        fields = [
            'id', 'drawing', 'revision_code', 'file', 'file_url',
            'file_name', 'file_size', 'change_type', 'change_notes',
            'uploaded_by', 'uploaded_by_name', 'uploaded_at',
        ]
        read_only_fields = ['id', 'drawing', 'file_name', 'file_size', 'uploaded_by', 'uploaded_at']
        extra_kwargs = {'file': {'write_only': True, 'required': False}}

    def get_file_url(self, obj):
        request = self.context.get('request')
        if obj.file and hasattr(obj.file, 'url'):
            download_path = f"/api/parts/drawings/{obj.drawing_id}/versions/{obj.pk}/download/"
            if request is not None:
                return request.build_absolute_uri(download_path)
            return download_path
        return None


class DrawingDocumentSerializer(serializers.ModelSerializer):
    part_number = serializers.CharField(source='part.part_number', read_only=True, default=None)
    part_name = serializers.CharField(source='part.part_name', read_only=True, default=None)
    created_by_name = serializers.CharField(source='created_by.get_full_name', read_only=True)
    status_display = serializers.CharField(source='get_status_display', read_only=True)
    doc_type_display = serializers.CharField(source='get_doc_type_display', read_only=True)
    assigned_reviewer_name = serializers.CharField(source='assigned_reviewer.get_full_name', read_only=True)
    assigned_approver_name = serializers.CharField(source='assigned_approver.get_full_name', read_only=True)
    reviewed_by_name = serializers.CharField(source='reviewed_by.get_full_name', read_only=True)
    approved_by_name = serializers.CharField(source='approved_by.get_full_name', read_only=True)
    rejected_by_name = serializers.CharField(source='rejected_by.get_full_name', read_only=True)
    versions = DrawingVersionSerializer(many=True, read_only=True)
    latest_version = serializers.SerializerMethodField()

    class Meta:
        model = DrawingDocument
        fields = [
            'id', 'part', 'part_number', 'part_name',
            'drawing_number', 'title', 'description',
            'doc_type', 'doc_type_display',
            'current_revision', 'status', 'status_display',
            'created_by', 'created_by_name',
            'created_at', 'updated_at',
            'assigned_reviewer', 'assigned_reviewer_name',
            'assigned_approver', 'assigned_approver_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'review_comments',
            'approved_by', 'approved_by_name', 'approved_at', 'approval_comments',
            'rejected_by', 'rejected_by_name', 'rejection_reason',
            'versions', 'latest_version',
        ]
        read_only_fields = [
            'id', 'current_revision', 'created_by', 'created_at', 'updated_at',
            'status', 'reviewed_by', 'reviewed_at', 'approved_by', 'approved_at',
            'rejected_by'
        ]

    def get_latest_version(self, obj):
        latest = obj.versions.first()
        if latest:
            return DrawingVersionSerializer(latest, context=self.context).data
        return None


class ControlPlanVersionSerializer(serializers.ModelSerializer):
    uploaded_by_name = serializers.CharField(source='uploaded_by.get_full_name', read_only=True)
    file_url = serializers.SerializerMethodField()

    class Meta:
        model = ControlPlanVersion
        fields = [
            'id', 'control_plan', 'revision_code', 'file', 'file_url',
            'file_name', 'file_size', 'change_type', 'change_notes',
            'uploaded_by', 'uploaded_by_name', 'uploaded_at',
        ]
        read_only_fields = ['id', 'control_plan', 'file_name', 'file_size', 'uploaded_by', 'uploaded_at']
        extra_kwargs = {'file': {'write_only': True, 'required': False}}

    def get_file_url(self, obj):
        request = self.context.get('request')
        if obj.file and hasattr(obj.file, 'url'):
            download_path = f"/api/parts/control-plans/{obj.control_plan_id}/versions/{obj.pk}/download/"
            if request is not None:
                return request.build_absolute_uri(download_path)
            return download_path
        return None


class ControlPlanDocumentSerializer(serializers.ModelSerializer):
    part_number = serializers.CharField(source='part.part_number', read_only=True, default=None)
    part_name = serializers.CharField(source='part.part_name', read_only=True, default=None)
    created_by_name = serializers.CharField(source='created_by.get_full_name', read_only=True)
    status_display = serializers.CharField(source='get_status_display', read_only=True)
    phase_display = serializers.CharField(source='get_phase_display', read_only=True)
    assigned_reviewer_name = serializers.CharField(source='assigned_reviewer.get_full_name', read_only=True)
    assigned_approver_name = serializers.CharField(source='assigned_approver.get_full_name', read_only=True)
    reviewed_by_name = serializers.CharField(source='reviewed_by.get_full_name', read_only=True)
    approved_by_name = serializers.CharField(source='approved_by.get_full_name', read_only=True)
    rejected_by_name = serializers.CharField(source='rejected_by.get_full_name', read_only=True)
    versions = ControlPlanVersionSerializer(many=True, read_only=True)
    latest_version = serializers.SerializerMethodField()

    class Meta:
        model = ControlPlanDocument
        fields = [
            'id', 'part', 'part_number', 'part_name',
            'control_plan_number', 'title', 'description',
            'phase', 'phase_display',
            'current_revision', 'status', 'status_display',
            'created_by', 'created_by_name',
            'created_at', 'updated_at',
            'assigned_reviewer', 'assigned_reviewer_name',
            'assigned_approver', 'assigned_approver_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'review_comments',
            'approved_by', 'approved_by_name', 'approved_at', 'approval_comments',
            'rejected_by', 'rejected_by_name', 'rejection_reason',
            'versions', 'latest_version',
        ]
        read_only_fields = [
            'id', 'current_revision', 'created_by', 'created_at', 'updated_at',
            'status', 'reviewed_by', 'reviewed_at', 'approved_by', 'approved_at',
            'rejected_by'
        ]

    def get_latest_version(self, obj):
        latest = obj.versions.first()
        if latest:
            return ControlPlanVersionSerializer(latest, context=self.context).data
        return None


class TemplateChangeRequestSerializer(serializers.ModelSerializer):
    template_name = serializers.CharField(source='template.name', read_only=True)
    part_number = serializers.CharField(source='template.part.part_number', read_only=True)
    machine_code = serializers.CharField(source='template.part.machine.machine_code', read_only=True)
    status_display = serializers.CharField(source='get_status_display', read_only=True)
    change_type_display = serializers.CharField(source='get_change_type_display', read_only=True)
    raised_by_name = serializers.SerializerMethodField()
    assigned_reviewer_name = serializers.SerializerMethodField()
    reviewed_by_name = serializers.SerializerMethodField()
    assigned_approver_name = serializers.SerializerMethodField()
    approved_by_name = serializers.SerializerMethodField()
    rejected_by_name = serializers.SerializerMethodField()

    class Meta:
        model = TemplateChangeRequest
        fields = [
            'id', 'dcr_number', 'form_doc_no', 'template', 'template_name',
            'part_number', 'machine_code',
            'change_type', 'change_type_display',
            'parameter', 'process_parameter', 'is_process_parameter',
            'parameter_code', 'parameter_name',
            'current_specification', 'proposed_specification',
            'basis_for_change',
            'status', 'status_display',
            'raised_by', 'raised_by_name', 'created_at',
            'assigned_reviewer', 'assigned_reviewer_name',
            'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'review_remarks',
            'assigned_approver', 'assigned_approver_name',
            'approved_by', 'approved_by_name', 'approved_at', 'approval_remarks',
            'rejected_by', 'rejected_by_name', 'rejection_reason',
            'implemented_at',
        ]
        read_only_fields = [
            'id', 'dcr_number', 'status', 'status_display', 'change_type_display',
            'raised_by', 'created_at', 'reviewed_at', 'approved_at', 'implemented_at'
        ]

    def get_raised_by_name(self, obj):
        return get_user_display(obj.raised_by)

    def get_assigned_reviewer_name(self, obj):
        return get_user_display(obj.assigned_reviewer)

    def get_reviewed_by_name(self, obj):
        return get_user_display(obj.reviewed_by)

    def get_assigned_approver_name(self, obj):
        return get_user_display(obj.assigned_approver)

    def get_approved_by_name(self, obj):
        return get_user_display(obj.approved_by)

    def get_rejected_by_name(self, obj):
        return get_user_display(obj.rejected_by)


