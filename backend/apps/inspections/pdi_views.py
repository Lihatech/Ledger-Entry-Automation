from datetime import datetime
from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.machines.models import Machine
from apps.parts.models import InspectionParameter, InspectionTemplate, Part
from apps.users.permissions import HasAccess

from .models import PDIReading, PDIReport


def _user_name(user):
    return (
        getattr(user, 'display_name', '')
        or user.get_full_name()
        or user.username
    )


def _parameter_snapshot(parameter):
    return {
        'id': parameter.id,
        'parameter_code': parameter.parameter_code,
        'parameter_name': parameter.parameter_name,
        'unit': parameter.unit,
        'specification': f'{parameter.lower_limit} to {parameter.upper_limit} {parameter.unit}'.strip(),
        'inspection_method': parameter.measurement_technique,
        'lower_limit': str(parameter.lower_limit) if parameter.lower_limit is not None else None,
        'upper_limit': str(parameter.upper_limit) if parameter.upper_limit is not None else None,
        'measurement_type': parameter.measurement_type,
        'sequence_order': parameter.sequence_order,
    }


def _report_data(report, include_readings=True):
    snapshot = report.parameter_snapshot or []
    readings = []
    if include_readings:
        readings = [
            {
                'reading_id': str(reading.reading_id),
                'parameter_id': reading.parameter_id,
                'parameter_code': reading.parameter_code,
                'sample_number': reading.sample_number,
                'value_text': reading.value_text,
                'numeric_value': str(reading.numeric_value) if reading.numeric_value is not None else None,
                'judgement': reading.judgement,
                'remarks': reading.remarks,
                'entered_by': _user_name(reading.entered_by),
                'entered_at': reading.entered_at.isoformat(),
            }
            for reading in report.readings.select_related('entered_by').order_by('parameter__sequence_order', 'sample_number')
        ]
    return {
        'report_id': str(report.report_id),
        'report_number': report.report_number,
        'report_date': report.report_date.isoformat(),
        'shift': report.shift,
        'machine_id': report.machine_id,
        'machine_code': report.machine.machine_code,
        'machine_name': report.machine.name,
        'part_id': report.part_id,
        'part_number': report.part.part_number,
        'part_name': report.part.part_name,
        'template_id': report.template_id,
        'operation_name': report.template.name or 'Operation',
        'customer_name': report.customer_name,
        'invoice_number': report.invoice_number,
        'supplied_quantity': report.supplied_quantity,
        'remarks': report.remarks,
        'status': report.status,
        'overall_judgement': report.overall_judgement,
        'created_by': _user_name(report.created_by),
        'submitted_by': _user_name(report.submitted_by) if report.submitted_by else None,
        'reviewed_by': _user_name(report.reviewed_by) if report.reviewed_by else None,
        'approved_by': _user_name(report.approved_by) if report.approved_by else None,
        'parameter_snapshot': snapshot,
        'readings': readings,
    }


def _parse_date(value):
    if not value:
        return timezone.localdate()
    try:
        return datetime.strptime(str(value), '%Y-%m-%d').date()
    except ValueError:
        return None


def _pdi_templates(machine_id):
    return (
        InspectionTemplate.objects.filter(
            part__machine_id=machine_id,
            part__is_active=True,
            is_active=True,
            is_published=True,
            status=InspectionTemplate.Status.APPROVED,
        )
        .select_related('part')
        .prefetch_related('parameters')
        .order_by('part__part_number', 'operation_key', '-version')
    )


class PDIReportOperationsView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.inspections.record'

    def get(self, request, machine_id):
        if not Machine.objects.filter(pk=machine_id, is_active=True).exists():
            return Response({'error': 'Machine not found.'}, status=status.HTTP_404_NOT_FOUND)
        seen = set()
        operations = []
        for template in _pdi_templates(machine_id):
            key = (template.part_id, str(template.operation_key))
            if key in seen:
                continue
            seen.add(key)
            operations.append({
                'id': template.id,
                'operation_key': str(template.operation_key),
                'name': template.name or 'Operation',
                'part_id': template.part_id,
                'part_number': template.part.part_number,
                'part_name': template.part.part_name,
                'parameter_count': template.parameters.count(),
            })
        return Response(operations)


class PDIReportParametersView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.inspections.record'

    def get(self, request, template_id):
        template = InspectionTemplate.objects.filter(
            pk=template_id,
            is_active=True,
            is_published=True,
            status=InspectionTemplate.Status.APPROVED,
        ).select_related('part').first()
        if not template:
            return Response({'error': 'Approved operation not found.'}, status=status.HTTP_404_NOT_FOUND)
        parameters = template.parameters.order_by('sequence_order', 'id')
        return Response([_parameter_snapshot(parameter) for parameter in parameters])


class PDIReportCreateView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.inspections.record'

    def post(self, request):
        try:
            machine_id = int(request.data.get('machine_id'))
            template_id = int(request.data.get('template_id'))
        except (TypeError, ValueError):
            return Response({'error': 'machine_id and template_id are required.'}, status=status.HTTP_400_BAD_REQUEST)
        report_date = _parse_date(request.data.get('report_date'))
        if report_date is None:
            return Response({'error': 'report_date must use YYYY-MM-DD format.'}, status=status.HTTP_400_BAD_REQUEST)
        template = _pdi_templates(machine_id).filter(pk=template_id).first()
        if not template:
            return Response({'error': 'Approved operation is not available for this machine.'}, status=status.HTTP_400_BAD_REQUEST)
        snapshot = [_parameter_snapshot(p) for p in template.parameters.order_by('sequence_order', 'id')]
        if not snapshot:
            return Response({'error': 'This operation has no active inspection parameters.'}, status=status.HTTP_400_BAD_REQUEST)
        shift = str(request.data.get('shift') or getattr(request.user, 'assigned_shift', '') or 'I')
        report = PDIReport.objects.filter(
            machine_id=machine_id, template=template, report_date=report_date,
            shift=shift, created_by=request.user,
            status__in=[PDIReport.Status.DRAFT, PDIReport.Status.IN_PROGRESS],
        ).first()
        if not report:
            prefix = f'PDI-{report_date:%Y%m%d}'
            count = PDIReport.objects.filter(report_number__startswith=prefix).count() + 1
            report = PDIReport.objects.create(
                report_number=f'{prefix}-{count:03d}', report_date=report_date,
                shift=shift, machine=template.part.machine, part=template.part,
                template=template, created_by=request.user, parameter_snapshot=snapshot,
                customer_name=str(request.data.get('customer_name') or ''),
                invoice_number=str(request.data.get('invoice_number') or ''),
                supplied_quantity=int(request.data.get('supplied_quantity') or 0),
            )
        return Response(_report_data(report, include_readings=False), status=status.HTTP_201_CREATED)


class PDIReportReadingView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.inspections.record'

    def post(self, request, report_id):
        try:
            sample_number = int(request.data.get('sample_number'))
            parameter_id = int(request.data.get('parameter_id'))
        except (TypeError, ValueError):
            return Response({'error': 'parameter_id and sample_number are required.'}, status=status.HTTP_400_BAD_REQUEST)
        if not 1 <= sample_number <= 5:
            return Response({'error': 'sample_number must be between 1 and 5.'}, status=status.HTTP_400_BAD_REQUEST)
        report = PDIReport.objects.select_related('machine', 'part', 'template').filter(pk=report_id).first()
        if not report:
            return Response({'error': 'PDI report not found.'}, status=status.HTTP_404_NOT_FOUND)
        if report.status in [PDIReport.Status.SUBMITTED, PDIReport.Status.APPROVED]:
            return Response({'error': 'Submitted reports cannot be edited.'}, status=status.HTTP_409_CONFLICT)
        parameter = InspectionParameter.objects.filter(pk=parameter_id, template_id=report.template_id).first()
        if not parameter:
            return Response({'error': 'Parameter is not part of this operation.'}, status=status.HTTP_400_BAD_REQUEST)
        value_text = str(request.data.get('value_text') or '').strip()
        measurement_type = parameter.measurement_type
        numeric_value = None
        judgement = str(request.data.get('judgement') or '').lower().strip()
        if measurement_type == InspectionParameter.MeasurementType.VISUAL:
            if judgement not in {PDIReading.Judgement.PASS, PDIReading.Judgement.FAIL, PDIReading.Judgement.NA}:
                return Response({'error': 'Visual parameters require Pass, Fail, or Not Applicable.'}, status=status.HTTP_400_BAD_REQUEST)
        else:
            try:
                numeric_value = Decimal(str(request.data.get('numeric_value', value_text)))
            except (InvalidOperation, TypeError, ValueError):
                return Response({'error': 'A numeric value is required for this parameter.'}, status=status.HTTP_400_BAD_REQUEST)
            judgement = PDIReading.Judgement.PASS if parameter.lower_limit <= numeric_value <= parameter.upper_limit else PDIReading.Judgement.FAIL
            value_text = str(numeric_value)
        with transaction.atomic():
            reading, _ = PDIReading.objects.update_or_create(
                report=report, parameter=parameter, sample_number=sample_number,
                defaults={
                    'parameter_code': parameter.parameter_code,
                    'parameter_name': parameter.parameter_name,
                    'unit': parameter.unit,
                    'specification': f'{parameter.lower_limit} to {parameter.upper_limit} {parameter.unit}'.strip(),
                    'inspection_method': parameter.measurement_technique,
                    'lower_limit': parameter.lower_limit,
                    'upper_limit': parameter.upper_limit,
                    'value_text': value_text,
                    'numeric_value': numeric_value,
                    'judgement': judgement,
                    'remarks': str(request.data.get('remarks') or ''),
                    'entered_by': request.user,
                },
            )
            if report.status == PDIReport.Status.DRAFT:
                report.status = PDIReport.Status.IN_PROGRESS
                report.save(update_fields=['status', 'updated_at'])
        return Response({'reading_id': str(reading.reading_id), 'judgement': reading.judgement, 'status': report.status})


class PDIReportDetailView(APIView):
    permission_classes = [HasAccess]
    access_key = {'GET': 'quality.reports.view', 'PATCH': 'quality.inspections.record'}

    def get(self, request, report_id):
        report = PDIReport.objects.select_related('machine', 'part', 'template', 'created_by', 'submitted_by', 'reviewed_by', 'approved_by').filter(pk=report_id).first()
        if not report:
            return Response({'error': 'PDI report not found.'}, status=status.HTTP_404_NOT_FOUND)
        return Response(_report_data(report))


class PDIReportSubmitView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.inspections.record'

    def post(self, request, report_id):
        with transaction.atomic():
            report = PDIReport.objects.select_for_update().filter(pk=report_id).first()
            if not report:
                return Response({'error': 'PDI report not found.'}, status=status.HTTP_404_NOT_FOUND)
            expected = len(report.parameter_snapshot or []) * 5
            readings = list(report.readings.all())
            if len(readings) < expected:
                return Response({'error': f'Complete all five samples for every parameter before submitting. {len(readings)}/{expected} entered.'}, status=status.HTTP_400_BAD_REQUEST)
            report.overall_judgement = PDIReport.Judgement.FAIL if any(r.judgement == PDIReading.Judgement.FAIL for r in readings) else PDIReport.Judgement.PASS
            report.status = PDIReport.Status.SUBMITTED
            report.submitted_by = request.user
            report.submitted_at = timezone.now()
            report.save(update_fields=['overall_judgement', 'status', 'submitted_by', 'submitted_at', 'updated_at'])
        return Response(_report_data(report))


class PDIReportListView(APIView):
    permission_classes = [HasAccess]
    access_key = 'quality.reports.view'

    def get(self, request):
        reports = PDIReport.objects.select_related('machine', 'part', 'template', 'created_by', 'submitted_by').all()
        if request.query_params.get('date'):
            report_date = _parse_date(request.query_params.get('date'))
            if report_date:
                reports = reports.filter(report_date=report_date)
        if request.query_params.get('machine_id'):
            reports = reports.filter(machine_id=request.query_params['machine_id'])
        if request.query_params.get('status'):
            reports = reports.filter(status=request.query_params['status'])
        return Response([_report_data(report, include_readings=False) for report in reports[:200]])
