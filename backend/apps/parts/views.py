import logging
from decimal import Decimal
from django.utils import timezone
from django.http import FileResponse
from django.shortcuts import get_object_or_404
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (
    Part, InspectionTemplate, InspectionParameter, ProcessParameter,
    TemplateChangeRequest
)
from .serializers import (
    PartSerializer, PartListSerializer,
    InspectionTemplateSerializer, InspectionTemplateListSerializer,
    InspectionParameterSerializer, ProcessParameterSerializer,
    TemplateChangeRequestSerializer
)
from apps.users.permissions import HasAccess
from .services.template_mailer import (
    notify_template_submitted,
    notify_template_reviewed,
    notify_template_approved,
    notify_template_dcr_event,
    notify_drawing_submitted,
    notify_drawing_reviewed,
    notify_drawing_approved,
    notify_control_plan_submitted,
    notify_control_plan_reviewed,
    notify_control_plan_approved,
)

logger = logging.getLogger('apps.parts')
from apps.users.access import OPERATIONAL_READ


# ─── Parts ────────────────────────────────────────────────────────────────
class PartListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/parts/              → list all active parts
    GET  /api/parts/?machine=1    → filter by machine
    POST /api/parts/              → create part (QE / Admin)
    """
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_serializer_class(self):
        if self.request.method == 'GET':
            return PartListSerializer
        return PartSerializer

    def get_queryset(self):
        qs = Part.objects.select_related('machine').filter(is_active=True)
        if getattr(self.request.user, 'plant_id', None):
            qs = qs.filter(machine__plant_id=self.request.user.plant_id)
        machine_id = self.request.query_params.get('machine')
        if machine_id:
            qs = qs.filter(machine_id=machine_id)
        return qs

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('quality.parts.manage')]
        return [HasAccess(('inventory.manage', *OPERATIONAL_READ))]


class PartDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/parts/<part_number>/"""
    serializer_class   = PartSerializer
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ
    queryset           = Part.objects.select_related('machine').all()
    lookup_field       = 'part_number'

    def get_permissions(self):
        if self.request.method in ['PUT', 'PATCH', 'DELETE']:
            return [HasAccess('quality.parts.manage')]
        return [HasAccess(OPERATIONAL_READ)]

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        instance.is_active = False
        instance.save()
        return Response({'message': f'Part {instance.part_number} deactivated successfully.'}, status=status.HTTP_204_NO_CONTENT)


# ─── Inspection Templates ──────────────────────────────────────────────────
class TemplateListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/parts/<part_number>/templates/                     → all templates for part
    GET  /api/parts/<part_number>/templates/?type=first_piece    → filter by type
    POST /api/parts/<part_number>/templates/                     → create template (Supervisor/QE/Admin)
    """
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_serializer_class(self):
        if self.request.method == 'GET':
            return InspectionTemplateListSerializer
        return InspectionTemplateSerializer

    def get_queryset(self):
        from urllib.parse import unquote
        part_number = unquote(self.kwargs['part_number'])
        qs = InspectionTemplate.objects.filter(
            part__part_number=part_number,
            is_active=True,
        )
        if getattr(self.request.user, 'plant_id', None):
            qs = qs.filter(part__machine__plant_id=self.request.user.plant_id)
        inspection_type = self.request.query_params.get('type')
        if inspection_type:
            qs = qs.filter(inspection_type=inspection_type)
        return qs

    def perform_create(self, serializer):
        from urllib.parse import unquote
        part_number = unquote(self.kwargs['part_number'])
        part = Part.objects.get(part_number=part_number)
        # Auto-increment version
        last_version = InspectionTemplate.objects.filter(
            part=part,
            inspection_type=serializer.validated_data['inspection_type']
        ).count()
        template_name = (serializer.validated_data.get('name') or '').strip()
        operation_key = None
        if template_name:
            sibling = InspectionTemplate.objects.filter(
                part=part,
                name__iexact=template_name,
            ).order_by('id').first()
            if sibling:
                operation_key = sibling.operation_key

        save_kwargs = {
            'part': part,
            'created_by': self.request.user,
            'version': last_version + 1,
        }
        if operation_key:
            save_kwargs['operation_key'] = operation_key
        serializer.save(**save_kwargs)

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('quality.templates.manage')]
        return [HasAccess(('inventory.manage', *OPERATIONAL_READ))]


class TemplateDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/parts/templates/<id>/"""
    serializer_class   = InspectionTemplateSerializer
    queryset           = InspectionTemplate.objects.all()

    def get_permissions(self):
        if self.request.method in ['PUT', 'PATCH', 'DELETE']:
            return [HasAccess('quality.templates.manage')]
        return [HasAccess(OPERATIONAL_READ)]

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        instance.is_active = False
        instance.save()
        return Response({'message': 'Operation template deactivated successfully.'}, status=status.HTTP_204_NO_CONTENT)


class TemplatePublishView(APIView):
    """
    POST /api/parts/templates/<id>/publish/
    Publishes and broadcasts the configured template to shop floor operators and quality inspectors.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.templates.manage'

    def post(self, request, pk):
        try:
            template = InspectionTemplate.objects.prefetch_related('parameters', 'part__machine').get(pk=pk)
            template.is_active = True
            template.is_published = True
            template.published_at = timezone.now()
            template.status = InspectionTemplate.Status.APPROVED
            if not template.approved_by:
                template.approved_by = request.user
                template.approved_at = timezone.now()
                template.approval_comments = f"Directly published by {request.user.username}"
            template.save()

            serializer = InspectionTemplateSerializer(template, context={'request': request})
            return Response({
                'success': True,
                'message': f"Operation '{template.name or template.get_inspection_type_display()}' published and dispatched to mobile successfully!",
                'template': serializer.data,
                'published_at': template.published_at,
                'parameters_count': template.parameters.count(),
            }, status=status.HTTP_200_OK)
        except InspectionTemplate.DoesNotExist:
            return Response(
                {'error': f'Inspection template with ID {pk} not found.'},
                status=status.HTTP_404_NOT_FOUND,
            )


class TemplateSubmitReviewView(APIView):
    """
    POST /api/parts/templates/<id>/submit-review/
    Submits an inspection template for review, optionally assigning reviewer and approver.
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def post(self, request, pk):
        template = get_object_or_404(
            InspectionTemplate.objects.prefetch_related('parameters', 'process_parameters'),
            pk=pk
        )
        total_params = template.parameters.count() + template.process_parameters.count()
        if total_params == 0:
            return Response(
                {'error': 'Cannot submit template with 0 parameters for review. Please add at least one parameter.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        assigned_reviewer_id = request.data.get('assigned_reviewer')
        assigned_approver_id = request.data.get('assigned_approver')

        if assigned_reviewer_id:
            template.assigned_reviewer_id = assigned_reviewer_id
        if assigned_approver_id:
            template.assigned_approver_id = assigned_approver_id

        template.status = InspectionTemplate.Status.UNDER_REVIEW
        template.save()

        notes = request.data.get('notes') or request.data.get('remarks') or ''
        try:
            notify_template_submitted(template, submitter_notes=notes)
        except Exception as e:
            logger.error("Error triggering template submission notification: %s", str(e))

        serializer = InspectionTemplateSerializer(template, context={'request': request})
        return Response({
            'success': True,
            'message': 'Inspection template submitted for review successfully.',
            'template': serializer.data,
        }, status=status.HTTP_200_OK)


class TemplateReviewActionView(APIView):
    """
    POST /api/parts/templates/<id>/review/
    Reviewer submits recommendation or rejection.
    Body:
        action: 'recommend' | 'reject'
        comments: str
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def post(self, request, pk):
        template = get_object_or_404(InspectionTemplate, pk=pk)
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'recommend':
            template.status = InspectionTemplate.Status.REVIEWED
            template.reviewed_by = request.user
            template.reviewed_at = timezone.now()
            template.review_comments = comments
            message = 'Inspection template reviewed and recommended for final approval.'
        elif action == 'reject':
            template.status = InspectionTemplate.Status.REJECTED
            template.rejected_by = request.user
            template.rejection_reason = comments or 'Rejected during review.'
            message = 'Inspection template rejected and sent back to draft.'
        else:
            return Response(
                {'error': "Invalid action. Must be 'recommend' or 'reject'."},
                status=status.HTTP_400_BAD_REQUEST
            )

        template.save()

        try:
            notify_template_reviewed(template, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering template review notification: %s", str(e))

        serializer = InspectionTemplateSerializer(template, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'template': serializer.data,
        }, status=status.HTTP_200_OK)


class TemplateApproveActionView(APIView):
    """
    POST /api/parts/templates/<id>/approve/
    Approver conducts final approval or rejection. Approving automatically publishes the template.
    Body:
        action: 'approve' | 'reject'
        comments: str
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def post(self, request, pk):
        template = get_object_or_404(InspectionTemplate, pk=pk)
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'approve':
            template.status = InspectionTemplate.Status.APPROVED
            template.approved_by = request.user
            template.approved_at = timezone.now()
            template.approval_comments = comments
            # Final approval also activates and publishes template to mobile shop floor
            template.is_active = True
            template.is_published = True
            template.published_at = timezone.now()
            message = 'Inspection template approved and published to shop floor successfully.'
        elif action == 'reject':
            template.status = InspectionTemplate.Status.REJECTED
            template.rejected_by = request.user
            template.rejection_reason = comments or 'Rejected during final approval.'
            message = 'Inspection template rejected and sent back to draft.'
        else:
            return Response(
                {'error': "Invalid action. Must be 'approve' or 'reject'."},
                status=status.HTTP_400_BAD_REQUEST
            )

        template.save()

        try:
            notify_template_approved(template, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering template approval notification: %s", str(e))

        serializer = InspectionTemplateSerializer(template, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'template': serializer.data,
        }, status=status.HTTP_200_OK)


# ─── Template Change Requests (DCR - Form DKI/MR/F/05) ────────────────────
class TemplateChangeRequestListCreateView(APIView):
    """
    GET  /api/parts/templates/<template_id>/change-requests/  -> List DCRs for template
    POST /api/parts/templates/<template_id>/change-requests/  -> Raise a new DCR
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def get_permissions(self):
        if self.request.method == 'GET':
            return [HasAccess('development.parameters.view')]
        return super().get_permissions()

    def get(self, request, template_id):
        template = get_object_or_404(InspectionTemplate, pk=template_id)
        dcrs = TemplateChangeRequest.objects.filter(template=template).order_by('-created_at')
        serializer = TemplateChangeRequestSerializer(dcrs, many=True, context={'request': request})
        return Response(serializer.data)

    def post(self, request, template_id):
        template = get_object_or_404(InspectionTemplate, pk=template_id)
        data = request.data

        dcr = TemplateChangeRequest.objects.create(
            form_doc_no=data.get('form_doc_no', 'DKI/MR/F/05'),
            template=template,
            change_type=data.get('change_type', TemplateChangeRequest.ChangeType.MODIFICATION),
            parameter_id=data.get('parameter_id') or None,
            process_parameter_id=data.get('process_parameter_id') or None,
            is_process_parameter=data.get('is_process_parameter', False),
            parameter_code=data.get('parameter_code', ''),
            parameter_name=data.get('parameter_name', ''),
            current_specification=data.get('current_specification', {}),
            proposed_specification=data.get('proposed_specification', {}),
            basis_for_change=data.get('basis_for_change', ''),
            status=TemplateChangeRequest.Status.AWAITING_REVIEW,
            raised_by=request.user,
            assigned_reviewer_id=data.get('assigned_reviewer') or template.assigned_reviewer_id,
            assigned_approver_id=data.get('assigned_approver') or template.assigned_approver_id,
        )

        try:
            notify_template_dcr_event(dcr, 'submitted', request.user)
        except Exception as e:
            logger.error("Error triggering DCR submission notification: %s", str(e))

        serializer = TemplateChangeRequestSerializer(dcr, context={'request': request})
        return Response({
            'success': True,
            'message': f"Document Change Request {dcr.dcr_number} submitted successfully for review.",
            'dcr': serializer.data
        }, status=status.HTTP_201_CREATED)


class TemplateChangeRequestReviewView(APIView):
    """
    POST /api/parts/change-requests/<pk>/review/
    Reviewer submits recommendation or rejection on a DCR.
    Body:
        action: 'recommend' | 'reject'
        remarks: str
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def post(self, request, pk):
        dcr = get_object_or_404(TemplateChangeRequest, pk=pk)
        action = request.data.get('action')
        remarks = (request.data.get('remarks') or request.data.get('review_remarks') or '').strip()

        if action == 'recommend':
            dcr.status = TemplateChangeRequest.Status.REVIEWED
            dcr.reviewed_by = request.user
            dcr.reviewed_at = timezone.now()
            dcr.review_remarks = remarks
            message = f"DCR {dcr.dcr_number} reviewed and recommended for final approval."
        elif action == 'reject':
            dcr.status = TemplateChangeRequest.Status.REJECTED
            dcr.rejected_by = request.user
            dcr.rejection_reason = remarks or 'Rejected during review.'
            message = f"DCR {dcr.dcr_number} rejected."
        else:
            return Response({'error': "Invalid action. Must be 'recommend' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        dcr.save()

        try:
            notify_template_dcr_event(dcr, 'reviewed' if action == 'recommend' else 'rejected', request.user, remarks)
        except Exception as e:
            logger.error("Error triggering DCR review notification: %s", str(e))

        serializer = TemplateChangeRequestSerializer(dcr, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'dcr': serializer.data
        }, status=status.HTTP_200_OK)


class TemplateChangeRequestApproveView(APIView):
    """
    POST /api/parts/change-requests/<pk>/approve/
    Approver authorizes DCR and applies parameter changes.
    Body:
        action: 'approve' | 'reject'
        remarks: str
    """
    permission_classes = [HasAccess]
    access_key = 'development.parameters.manage'

    def post(self, request, pk):
        dcr = get_object_or_404(TemplateChangeRequest, pk=pk)
        action = request.data.get('action')
        remarks = (request.data.get('remarks') or request.data.get('approval_remarks') or '').strip()

        if action == 'reject':
            dcr.status = TemplateChangeRequest.Status.REJECTED
            dcr.rejected_by = request.user
            dcr.rejection_reason = remarks or 'Rejected during final approval.'
            dcr.save()

            try:
                notify_template_dcr_event(dcr, 'rejected', request.user, remarks)
            except Exception as e:
                logger.error("Error triggering DCR rejection notification: %s", str(e))

            serializer = TemplateChangeRequestSerializer(dcr, context={'request': request})
            return Response({
                'success': True,
                'message': f"DCR {dcr.dcr_number} rejected.",
                'dcr': serializer.data
            }, status=status.HTTP_200_OK)

        if action != 'approve':
            return Response({'error': "Invalid action. Must be 'approve' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        dcr.status = TemplateChangeRequest.Status.APPROVED
        dcr.approved_by = request.user
        dcr.approved_at = timezone.now()
        dcr.approval_remarks = remarks

        # Apply change to parameter
        proposed = dcr.proposed_specification
        if dcr.change_type == TemplateChangeRequest.ChangeType.MODIFICATION:
            if dcr.parameter:
                param = dcr.parameter
                if 'nominal_value' in proposed: param.nominal_value = Decimal(str(proposed['nominal_value']))
                if 'upper_tolerance' in proposed: param.upper_tolerance = Decimal(str(proposed['upper_tolerance']))
                if 'lower_tolerance' in proposed: param.lower_tolerance = Decimal(str(proposed['lower_tolerance']))
                if 'unit' in proposed: param.unit = proposed['unit']
                if 'measurement_type' in proposed: param.measurement_type = proposed['measurement_type']
                if 'is_critical' in proposed: param.is_critical = bool(proposed['is_critical'])
                if 'measurement_technique' in proposed: param.measurement_technique = proposed['measurement_technique']
                if 'sample_size' in proposed: param.sample_size = proposed['sample_size']
                if 'control_method' in proposed: param.control_method = proposed['control_method']
                param.save()
            elif dcr.process_parameter:
                proc = dcr.process_parameter
                if 'nominal_value' in proposed and proposed['nominal_value'] is not None:
                    proc.nominal_value = Decimal(str(proposed['nominal_value']))
                if 'upper_tolerance' in proposed and proposed['upper_tolerance'] is not None:
                    proc.upper_tolerance = Decimal(str(proposed['upper_tolerance']))
                if 'lower_tolerance' in proposed and proposed['lower_tolerance'] is not None:
                    proc.lower_tolerance = Decimal(str(proposed['lower_tolerance']))
                if 'unit' in proposed: proc.unit = proposed['unit']
                if 'specification' in proposed: proc.specification = proposed['specification']
                proc.save()

        elif dcr.change_type == TemplateChangeRequest.ChangeType.ADDITION:
            if dcr.is_process_parameter:
                ProcessParameter.objects.create(
                    template=dcr.template,
                    parameter_code=dcr.parameter_code,
                    parameter_name=dcr.parameter_name,
                    data_type=proposed.get('data_type', 'numeric'),
                    measurement_type=proposed.get('measurement_type', 'machine_setting'),
                    unit=proposed.get('unit', ''),
                    specification=proposed.get('specification', ''),
                    nominal_value=Decimal(str(proposed['nominal_value'])) if proposed.get('nominal_value') else None,
                    upper_tolerance=Decimal(str(proposed['upper_tolerance'])) if proposed.get('upper_tolerance') else None,
                    lower_tolerance=Decimal(str(proposed['lower_tolerance'])) if proposed.get('lower_tolerance') else None,
                )
            else:
                InspectionParameter.objects.create(
                    template=dcr.template,
                    parameter_code=dcr.parameter_code,
                    parameter_name=dcr.parameter_name,
                    unit=proposed.get('unit', 'mm'),
                    nominal_value=Decimal(str(proposed.get('nominal_value', '0.00'))),
                    upper_tolerance=Decimal(str(proposed.get('upper_tolerance', '0.00'))),
                    lower_tolerance=Decimal(str(proposed.get('lower_tolerance', '0.00'))),
                    measurement_type=proposed.get('measurement_type', 'dimensional'),
                    is_critical=bool(proposed.get('is_critical', False)),
                    measurement_technique=proposed.get('measurement_technique', ''),
                    sample_size=proposed.get('sample_size', ''),
                    control_method=proposed.get('control_method', ''),
                )

        elif dcr.change_type == TemplateChangeRequest.ChangeType.DELETION:
            if dcr.parameter:
                dcr.parameter.delete()
            elif dcr.process_parameter:
                dcr.process_parameter.delete()

        dcr.status = TemplateChangeRequest.Status.IMPLEMENTED
        dcr.implemented_at = timezone.now()
        dcr.save()

        try:
            notify_template_dcr_event(dcr, 'approved', request.user, remarks)
        except Exception as e:
            logger.error("Error triggering DCR approval notification: %s", str(e))

        serializer = TemplateChangeRequestSerializer(dcr, context={'request': request})
        return Response({
            'success': True,
            'message': f"DCR {dcr.dcr_number} approved and implemented successfully on shop floor.",
            'dcr': serializer.data
        }, status=status.HTTP_200_OK)


class ActiveTemplateView(APIView):
    """
    GET /api/parts/<part_number>/template/<inspection_type>/
    Returns the active template for a part + inspection type.
    This is the primary endpoint called by Flutter before starting inspection.
    """
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get(self, request, part_number, inspection_type):
        from urllib.parse import unquote
        part_number = unquote(part_number)
        try:
            template = InspectionTemplate.objects.prefetch_related('parameters').get(
                part__part_number=part_number,
                inspection_type=inspection_type,
                is_active=True,
            )
            serializer = InspectionTemplateSerializer(template, context={'request': request})
            return Response(serializer.data)
        except InspectionTemplate.DoesNotExist:
            return Response(
                {'error': f'No active {inspection_type} template for part {part_number}'},
                status=status.HTTP_404_NOT_FOUND,
            )
        except InspectionTemplate.MultipleObjectsReturned:
            # Return the latest version
            template = InspectionTemplate.objects.prefetch_related('parameters').filter(
                part__part_number=part_number,
                inspection_type=inspection_type,
                is_active=True,
            ).order_by('-version').first()
            serializer = InspectionTemplateSerializer(template, context={'request': request})
            return Response(serializer.data)


# ─── Parameters ───────────────────────────────────────────────────────────
class ParameterListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/parts/templates/<template_id>/parameters/
    POST /api/parts/templates/<template_id>/parameters/  → add parameter (Supervisor/QE/Admin)
    """
    serializer_class   = InspectionParameterSerializer
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_queryset(self):
        return InspectionParameter.objects.filter(
            template_id=self.kwargs['template_id']
        ).order_by('sequence_order')

    def perform_create(self, serializer):
        template = InspectionTemplate.objects.get(pk=self.kwargs['template_id'])
        serializer.save(template=template)

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess(('quality.parameters.manage', 'development.parameters.manage'))]
        return [HasAccess(OPERATIONAL_READ)]


class ParameterDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/parts/parameters/<id>/"""
    serializer_class   = InspectionParameterSerializer
    queryset           = InspectionParameter.objects.all()

    def get_permissions(self):
        if self.request.method in ['PUT', 'PATCH', 'DELETE']:
            return [HasAccess(('quality.parameters.manage', 'development.parameters.manage'))]
        return [HasAccess(OPERATIONAL_READ)]


# ─── Process Parameters ───────────────────────────────────────────────────
class ProcessParameterListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/parts/templates/<template_id>/process-parameters/
    POST /api/parts/templates/<template_id>/process-parameters/  → add process parameter (Supervisor/Admin)
    """
    serializer_class   = ProcessParameterSerializer
    permission_classes = [HasAccess]
    access_key = OPERATIONAL_READ

    def get_queryset(self):
        template_id = self.kwargs['template_id']
        return ProcessParameter.objects.filter(template_id=template_id).order_by('sequence_order')

    def perform_create(self, serializer):
        template = InspectionTemplate.objects.get(pk=self.kwargs['template_id'])
        serializer.save(template=template)

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess(('quality.parameters.manage', 'development.parameters.manage'))]
        return [HasAccess(OPERATIONAL_READ)]


class ProcessParameterDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/DELETE /api/parts/process-parameters/<id>/"""
    serializer_class   = ProcessParameterSerializer
    queryset           = ProcessParameter.objects.all()

    def get_permissions(self):
        if self.request.method in ['PUT', 'PATCH', 'DELETE']:
            return [HasAccess(('quality.parameters.manage', 'development.parameters.manage'))]
        return [HasAccess(OPERATIONAL_READ)]


class AllParameterListView(generics.ListAPIView):
    """GET /api/parts/parameters/all/"""
    from .serializers import GlobalInspectionParameterSerializer
    serializer_class = GlobalInspectionParameterSerializer
    permission_classes = [HasAccess]
    access_key = 'development.parameters.view'
    pagination_class = None
    queryset = InspectionParameter.objects.select_related('template__part__machine', 'template__created_by').all().order_by('-id')


class AllProcessParameterListView(generics.ListAPIView):
    """GET /api/parts/process-parameters/all/"""
    from .serializers import GlobalProcessParameterSerializer
    serializer_class = GlobalProcessParameterSerializer
    permission_classes = [HasAccess]
    access_key = 'development.parameters.view'
    pagination_class = None
    queryset = ProcessParameter.objects.select_related('template__part__machine', 'template__created_by').all().order_by('-id')


# ─────────────────────────────────────────────────────────────
# Drawings & Control Plans Management (Supervisors & Admins)
# ─────────────────────────────────────────────────────────────
from django.db import transaction
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from .models import DrawingDocument, DrawingVersion, ControlPlanDocument, ControlPlanVersion
from .serializers import (
    DrawingDocumentSerializer, DrawingVersionSerializer,
    ControlPlanDocumentSerializer, ControlPlanVersionSerializer
)

class DrawingViewSet(viewsets.ModelViewSet):
    """
    API for managing Engineering Drawings and their Revision Histories.
    Accessible to Supervisors, Quality Engineers, and Administrators.
    """
    queryset = DrawingDocument.objects.select_related(
        'part', 'created_by', 'assigned_reviewer', 'assigned_approver',
        'reviewed_by', 'approved_by', 'rejected_by'
    ).prefetch_related('versions__uploaded_by').all()
    serializer_class = DrawingDocumentSerializer
    permission_classes = [HasAccess]
    access_key = 'development.drawings.manage'
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def get_permissions(self):
        if self.action in ('list', 'retrieve', 'history', 'download_file'):
            return [HasAccess('development.drawings.view')]
        return super().get_permissions()

    @transaction.atomic
    def perform_create(self, serializer):
        drawing = serializer.save(
            created_by=self.request.user,
            status=DrawingDocument.Status.DRAFT
        )
        file_obj = self.request.FILES.get('file')
        revision_code = self.request.data.get('revision_code', drawing.current_revision or 'Rev A')
        change_notes = self.request.data.get('change_notes', 'Initial drawing upload')
        change_type = self.request.data.get('change_type', 'initial')
        if file_obj:
            DrawingVersion.objects.create(
                drawing=drawing,
                revision_code=revision_code,
                file=file_obj,
                file_name=file_obj.name,
                file_size=file_obj.size,
                change_type=change_type,
                change_notes=change_notes,
                uploaded_by=self.request.user,
            )
            if drawing.current_revision != revision_code:
                drawing.current_revision = revision_code
                drawing.save(update_fields=['current_revision'])

    @action(detail=True, methods=['post'], url_path='submit-review')
    def submit_review(self, request, pk=None):
        """POST /api/parts/drawings/{id}/submit-review/"""
        drawing = self.get_object()
        assigned_reviewer_id = request.data.get('assigned_reviewer')
        assigned_approver_id = request.data.get('assigned_approver')
        notes = (request.data.get('notes') or request.data.get('remarks') or '').strip()

        if assigned_reviewer_id:
            drawing.assigned_reviewer_id = assigned_reviewer_id
        if assigned_approver_id:
            drawing.assigned_approver_id = assigned_approver_id

        drawing.status = DrawingDocument.Status.UNDER_REVIEW
        drawing.save()

        try:
            notify_drawing_submitted(drawing, submitter_notes=notes)
        except Exception as e:
            logger.error("Error triggering drawing submission notification: %s", str(e))

        serializer = DrawingDocumentSerializer(drawing, context={'request': request})
        return Response({
            'success': True,
            'message': f"Drawing '{drawing.drawing_number}' submitted for review successfully.",
            'drawing': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], url_path='review')
    def review(self, request, pk=None):
        """POST /api/parts/drawings/{id}/review/"""
        drawing = self.get_object()
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'recommend':
            drawing.status = DrawingDocument.Status.REVIEWED
            drawing.reviewed_by = request.user
            drawing.reviewed_at = timezone.now()
            drawing.review_comments = comments
            message = f"Drawing '{drawing.drawing_number}' reviewed and recommended for final approval."
        elif action == 'reject':
            drawing.status = DrawingDocument.Status.REJECTED
            drawing.rejected_by = request.user
            drawing.rejection_reason = comments or 'Rejected during review.'
            message = f"Drawing '{drawing.drawing_number}' returned for revision."
        else:
            return Response({'error': "Invalid action. Must be 'recommend' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        drawing.save()

        try:
            notify_drawing_reviewed(drawing, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering drawing review notification: %s", str(e))

        serializer = DrawingDocumentSerializer(drawing, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'drawing': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], url_path='approve')
    def approve(self, request, pk=None):
        """POST /api/parts/drawings/{id}/approve/"""
        drawing = self.get_object()
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'approve':
            drawing.status = DrawingDocument.Status.APPROVED
            drawing.approved_by = request.user
            drawing.approved_at = timezone.now()
            drawing.approval_comments = comments
            message = f"Drawing '{drawing.drawing_number}' approved and released successfully."
        elif action == 'reject':
            drawing.status = DrawingDocument.Status.REJECTED
            drawing.rejected_by = request.user
            drawing.rejection_reason = comments or 'Rejected during final approval.'
            message = f"Drawing '{drawing.drawing_number}' rejected."
        else:
            return Response({'error': "Invalid action. Must be 'approve' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        drawing.save()

        try:
            notify_drawing_approved(drawing, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering drawing approval notification: %s", str(e))

        serializer = DrawingDocumentSerializer(drawing, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'drawing': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], parser_classes=[MultiPartParser, FormParser])
    def upload_version(self, request, pk=None):
        """POST /api/parts/drawings/{id}/upload_version/"""
        drawing = self.get_object()
        file_obj = request.FILES.get('file')
        revision_code = request.data.get('revision_code')
        change_notes = request.data.get('change_notes', '')
        change_type = request.data.get('change_type', 'engineering_change')
        assigned_reviewer_id = request.data.get('assigned_reviewer')
        assigned_approver_id = request.data.get('assigned_approver')

        if not file_obj:
            return Response({'error': 'A drawing file is required.'}, status=status.HTTP_400_BAD_REQUEST)
        if not revision_code:
            return Response({'error': 'A revision code is required (e.g. Rev B).'}, status=status.HTTP_400_BAD_REQUEST)

        with transaction.atomic():
            DrawingVersion.objects.create(
                drawing=drawing,
                revision_code=revision_code,
                file=file_obj,
                file_name=file_obj.name,
                file_size=file_obj.size,
                change_type=change_type,
                change_notes=change_notes,
                uploaded_by=request.user,
            )
            drawing.current_revision = revision_code

            # In manufacturing change control, new revisions on approved documents require review sign-off
            if drawing.status == DrawingDocument.Status.APPROVED:
                drawing.status = DrawingDocument.Status.UNDER_REVIEW
                if assigned_reviewer_id:
                    drawing.assigned_reviewer_id = assigned_reviewer_id
                if assigned_approver_id:
                    drawing.assigned_approver_id = assigned_approver_id
                drawing.reviewed_by = None
                drawing.reviewed_at = None
                drawing.approved_by = None
                drawing.approved_at = None
                drawing.save()
                try:
                    notify_drawing_submitted(drawing, submitter_notes=f"New Revision {revision_code} uploaded: {change_notes}")
                except Exception as e:
                    logger.error("Error triggering revision notification: %s", str(e))
            else:
                drawing.save(update_fields=['current_revision'])

        return Response(DrawingDocumentSerializer(drawing, context={'request': request}).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=['get'])
    def history(self, request, pk=None):
        """GET /api/parts/drawings/{id}/history/"""
        drawing = self.get_object()
        versions = drawing.versions.select_related('uploaded_by').all()
        serializer = DrawingVersionSerializer(versions, many=True, context={'request': request})
        return Response(serializer.data)

    @action(detail=True, methods=['get'], url_path=r'versions/(?P<version_id>\d+)/download')
    def download_file(self, request, pk=None, version_id=None):
        """GET /api/parts/drawings/{id}/versions/{version_id}/download/"""
        drawing = self.get_object()
        version = get_object_or_404(DrawingVersion, pk=version_id, drawing=drawing)
        if not version.file:
            return Response({'error': 'Drawing file not found.'}, status=status.HTTP_404_NOT_FOUND)
        response = FileResponse(version.file.open('rb'), content_type='application/octet-stream')
        response['Content-Disposition'] = f'attachment; filename="{version.file_name or "drawing.pdf"}"'
        return response


class ControlPlanViewSet(viewsets.ModelViewSet):
    """
    API for managing Process Control Plans and their Version Histories.
    Accessible to Supervisors, Quality Engineers, and Administrators.
    """
    queryset = ControlPlanDocument.objects.select_related(
        'part', 'created_by', 'assigned_reviewer', 'assigned_approver',
        'reviewed_by', 'approved_by', 'rejected_by'
    ).prefetch_related('versions__uploaded_by').all()
    serializer_class = ControlPlanDocumentSerializer
    permission_classes = [HasAccess]
    access_key = 'development.control_plans.manage'
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def get_permissions(self):
        if self.action in ('list', 'retrieve', 'history', 'download_file'):
            return [HasAccess('development.control_plans.view')]
        return super().get_permissions()

    @transaction.atomic
    def perform_create(self, serializer):
        control_plan = serializer.save(
            created_by=self.request.user,
            status=ControlPlanDocument.Status.DRAFT
        )
        file_obj = self.request.FILES.get('file')
        revision_code = self.request.data.get('revision_code', control_plan.current_revision or 'v1.0')
        change_notes = self.request.data.get('change_notes', 'Initial control plan upload')
        change_type = self.request.data.get('change_type', 'initial')
        if file_obj:
            ControlPlanVersion.objects.create(
                control_plan=control_plan,
                revision_code=revision_code,
                file=file_obj,
                file_name=file_obj.name,
                file_size=file_obj.size,
                change_type=change_type,
                change_notes=change_notes,
                uploaded_by=self.request.user,
            )
            if control_plan.current_revision != revision_code:
                control_plan.current_revision = revision_code
                control_plan.save(update_fields=['current_revision'])

    @action(detail=True, methods=['post'], url_path='submit-review')
    def submit_review(self, request, pk=None):
        """POST /api/parts/control-plans/{id}/submit-review/"""
        control_plan = self.get_object()
        assigned_reviewer_id = request.data.get('assigned_reviewer')
        assigned_approver_id = request.data.get('assigned_approver')
        notes = (request.data.get('notes') or request.data.get('remarks') or '').strip()

        if assigned_reviewer_id:
            control_plan.assigned_reviewer_id = assigned_reviewer_id
        if assigned_approver_id:
            control_plan.assigned_approver_id = assigned_approver_id

        control_plan.status = ControlPlanDocument.Status.UNDER_REVIEW
        control_plan.save()

        try:
            notify_control_plan_submitted(control_plan, submitter_notes=notes)
        except Exception as e:
            logger.error("Error triggering control plan submission notification: %s", str(e))

        serializer = ControlPlanDocumentSerializer(control_plan, context={'request': request})
        return Response({
            'success': True,
            'message': f"Control Plan '{control_plan.control_plan_number}' submitted for review successfully.",
            'control_plan': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], url_path='review')
    def review(self, request, pk=None):
        """POST /api/parts/control-plans/{id}/review/"""
        control_plan = self.get_object()
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'recommend':
            control_plan.status = ControlPlanDocument.Status.REVIEWED
            control_plan.reviewed_by = request.user
            control_plan.reviewed_at = timezone.now()
            control_plan.review_comments = comments
            message = f"Control Plan '{control_plan.control_plan_number}' reviewed and recommended for final approval."
        elif action == 'reject':
            control_plan.status = ControlPlanDocument.Status.REJECTED
            control_plan.rejected_by = request.user
            control_plan.rejection_reason = comments or 'Rejected during review.'
            message = f"Control Plan '{control_plan.control_plan_number}' returned for revision."
        else:
            return Response({'error': "Invalid action. Must be 'recommend' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        control_plan.save()

        try:
            notify_control_plan_reviewed(control_plan, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering control plan review notification: %s", str(e))

        serializer = ControlPlanDocumentSerializer(control_plan, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'control_plan': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], url_path='approve')
    def approve(self, request, pk=None):
        """POST /api/parts/control-plans/{id}/approve/"""
        control_plan = self.get_object()
        action = request.data.get('action')
        comments = (request.data.get('comments') or request.data.get('remarks') or '').strip()

        if action == 'approve':
            control_plan.status = ControlPlanDocument.Status.APPROVED
            control_plan.approved_by = request.user
            control_plan.approved_at = timezone.now()
            control_plan.approval_comments = comments
            message = f"Control Plan '{control_plan.control_plan_number}' approved and released successfully."
        elif action == 'reject':
            control_plan.status = ControlPlanDocument.Status.REJECTED
            control_plan.rejected_by = request.user
            control_plan.rejection_reason = comments or 'Rejected during final approval.'
            message = f"Control Plan '{control_plan.control_plan_number}' rejected."
        else:
            return Response({'error': "Invalid action. Must be 'approve' or 'reject'."}, status=status.HTTP_400_BAD_REQUEST)

        control_plan.save()

        try:
            notify_control_plan_approved(control_plan, request.user, action, comments)
        except Exception as e:
            logger.error("Error triggering control plan approval notification: %s", str(e))

        serializer = ControlPlanDocumentSerializer(control_plan, context={'request': request})
        return Response({
            'success': True,
            'message': message,
            'control_plan': serializer.data,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=['post'], parser_classes=[MultiPartParser, FormParser])
    def upload_version(self, request, pk=None):
        """POST /api/parts/control-plans/{id}/upload_version/"""
        control_plan = self.get_object()
        file_obj = request.FILES.get('file')
        revision_code = request.data.get('revision_code')
        change_notes = request.data.get('change_notes', '')
        change_type = request.data.get('change_type', 'process_improvement')
        assigned_reviewer_id = request.data.get('assigned_reviewer')
        assigned_approver_id = request.data.get('assigned_approver')

        if not file_obj:
            return Response({'error': 'A control plan file is required.'}, status=status.HTTP_400_BAD_REQUEST)
        if not revision_code:
            return Response({'error': 'A version/revision code is required (e.g. v1.1).'}, status=status.HTTP_400_BAD_REQUEST)

        with transaction.atomic():
            ControlPlanVersion.objects.create(
                control_plan=control_plan,
                revision_code=revision_code,
                file=file_obj,
                file_name=file_obj.name,
                file_size=file_obj.size,
                change_type=change_type,
                change_notes=change_notes,
                uploaded_by=request.user,
            )
            control_plan.current_revision = revision_code

            # In manufacturing change control, new revisions on approved control plans require review sign-off
            if control_plan.status == ControlPlanDocument.Status.APPROVED:
                control_plan.status = ControlPlanDocument.Status.UNDER_REVIEW
                if assigned_reviewer_id:
                    control_plan.assigned_reviewer_id = assigned_reviewer_id
                if assigned_approver_id:
                    control_plan.assigned_approver_id = assigned_approver_id
                control_plan.reviewed_by = None
                control_plan.reviewed_at = None
                control_plan.approved_by = None
                control_plan.approved_at = None
                control_plan.save()
                try:
                    notify_control_plan_submitted(control_plan, submitter_notes=f"New Version {revision_code} uploaded: {change_notes}")
                except Exception as e:
                    logger.error("Error triggering control plan revision notification: %s", str(e))
            else:
                control_plan.save(update_fields=['current_revision'])

        return Response(ControlPlanDocumentSerializer(control_plan, context={'request': request}).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=['get'])
    def history(self, request, pk=None):
        """GET /api/parts/control-plans/{id}/history/"""
        control_plan = self.get_object()
        versions = control_plan.versions.select_related('uploaded_by').all()
        serializer = ControlPlanVersionSerializer(versions, many=True, context={'request': request})
        return Response(serializer.data)

    @action(detail=True, methods=['get'], url_path=r'versions/(?P<version_id>\d+)/download')
    def download_file(self, request, pk=None, version_id=None):
        """GET /api/parts/control-plans/{id}/versions/{version_id}/download/"""
        control_plan = self.get_object()
        version = get_object_or_404(ControlPlanVersion, pk=version_id, control_plan=control_plan)
        if not version.file:
            return Response({'error': 'Control plan file not found.'}, status=status.HTTP_404_NOT_FOUND)
        response = FileResponse(version.file.open('rb'), content_type='application/octet-stream')
        response['Content-Disposition'] = f'attachment; filename="{version.file_name or "control_plan.pdf"}"'
        return response

