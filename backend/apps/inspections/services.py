"""
Validation Engine + Inspection Service.

ToleranceValidator  : checks if a measured value is within tolerance.
InspectionService   : orchestrates session creation, measurement recording,
                      MongoDB document management, and WebSocket notifications.
"""

import logging
import re
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

from django.core.cache import cache
from django.db import transaction
from django.db.models import F, Q
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

from apps.parts.models import InspectionParameter, InspectionTemplate, ProcessParameter
from .models import InspectionSession
from . import document_utils as doc_utils

logger = logging.getLogger(__name__)


# M1 FIX: Single shared thread pool for all WebSocket broadcast events.
# Old code created a brand-new thread per event (thread churn).
# Each measurement recorded = 1 new thread created + destroyed = unnecessary CPU
# + memory overhead under load. A fixed pool of 2 workers handles all broadcasts
# with zero thread creation cost after startup.
_broadcast_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='ws_broadcast')


def _dispatch_async_websocket(group_name: str, payload: dict):
    """Sends WebSocket group message via shared thread pool to prevent blocking HTTP response."""
    def _send():
        try:
            channel_layer = get_channel_layer()
            if channel_layer:
                async_to_sync(channel_layer.group_send)(group_name, payload)
        except Exception as exc:
            logger.warning("Failed to dispatch WebSocket event: %s", exc)

    _broadcast_pool.submit(_send)


class CachedParamWrapper:
    """Safely wraps cached parameter dictionary with attribute access and fallback."""
    def __init__(self, data: dict):
        self.__dict__.update(data)

    def __getattr__(self, name):
        return None


def _get_cached_parameter(part_id: int, parameter_code: str):
    """Retrieves InspectionParameter from Redis cache (1 hour timeout) or DB."""
    cache_key = f"param_spec_{part_id}_{parameter_code}"
    cached_param = cache.get(cache_key)
    if cached_param is not None:
        if isinstance(cached_param, dict):
            return CachedParamWrapper(cached_param)
        return cached_param

    from django.db.models import Q
    param = InspectionParameter.objects.filter(template__part_id=part_id).filter(
        Q(parameter_code__iexact=parameter_code) | Q(parameter_name__iexact=parameter_code)
    ).first()

    if not param:
        param = InspectionParameter.objects.filter(
            Q(parameter_code__iexact=parameter_code) | Q(parameter_name__iexact=parameter_code)
        ).first()

    if param:
        cache_data = {
            'id': param.id,
            'parameter_code': param.parameter_code,
            'parameter_name': param.parameter_name,
            'measurement_type': param.measurement_type or 'dimensional',
            'measurement_technique': getattr(param, 'measurement_technique', '') or '',
            'unit': param.unit or 'mm',
            'nominal_value': float(param.nominal_value) if param.nominal_value is not None else 0.0,
            'upper_tolerance': float(param.upper_tolerance) if param.upper_tolerance is not None else 0.0,
            'lower_tolerance': float(param.lower_tolerance) if param.lower_tolerance is not None else 0.0,
            'upper_limit': float(param.upper_limit) if param.upper_limit is not None else 0.0,
            'lower_limit': float(param.lower_limit) if param.lower_limit is not None else 0.0,
            'is_critical': bool(param.is_critical),
            'is_process_parameter': False,
        }
        cache.set(cache_key, cache_data, timeout=3600)
    return param


def _get_cached_process_parameter(part_id: int, parameter_code: str):
    """Retrieves ProcessParameter from Redis cache (1 hour timeout) or DB."""
    cache_key = f"proc_param_spec_{part_id}_{parameter_code}"
    cached_proc_param = cache.get(cache_key)
    if cached_proc_param is not None:
        if isinstance(cached_proc_param, dict):
            return CachedParamWrapper(cached_proc_param)
        return cached_proc_param

    from django.db.models import Q
    proc_param = ProcessParameter.objects.filter(template__part_id=part_id).filter(
        Q(parameter_code__iexact=parameter_code) | Q(parameter_name__iexact=parameter_code)
    ).first()

    if not proc_param:
        proc_param = ProcessParameter.objects.filter(
            Q(parameter_code__iexact=parameter_code) | Q(parameter_name__iexact=parameter_code)
        ).first()

    if proc_param:
        cache_data = {
            'id': proc_param.id,
            'parameter_code': proc_param.parameter_code,
            'parameter_name': proc_param.parameter_name,
            'data_type': proc_param.data_type or 'numeric',
            'measurement_type': proc_param.measurement_type or 'dimensional',
            'measurement_technique': getattr(proc_param, 'measurement_technique', '') or '',
            'unit': proc_param.unit or '',
            'specification': proc_param.specification or '',
            'nominal_value': float(proc_param.nominal_value) if proc_param.nominal_value is not None else None,
            'upper_tolerance': float(proc_param.upper_tolerance) if proc_param.upper_tolerance is not None else None,
            'lower_tolerance': float(proc_param.lower_tolerance) if proc_param.lower_tolerance is not None else None,
            'upper_limit': float(proc_param.upper_limit) if proc_param.upper_limit is not None else None,
            'lower_limit': float(proc_param.lower_limit) if proc_param.lower_limit is not None else None,
            'is_required': bool(proc_param.is_required),
            'is_process_parameter': True,
        }
        cache.set(cache_key, cache_data, timeout=3600)
    return proc_param


# ─── Validation Result ────────────────────────────────────────────────────
@dataclass
class ValidationResult:
    measured_value: float
    nominal:        float
    upper_limit:    float
    lower_limit:    float
    status:         str           # 'ok' | 'out_of_spec'
    deviation:      float         # measured - nominal
    is_critical:    bool
    message:        str



def parse_visual_text(text: str) -> Optional[bool]:
    """
    Parses visual/voice confirmation text into boolean (True=Pass/Yes, False=Fail/No).
    Explicit negative tokens ('NO', 'FAIL', 'REJECT', 'FALSE', 'NOT OK', 'NOT GOOD', etc.)
    take strict precedence over affirmative tokens.
    Matches normalized tokens using word boundaries, avoiding substring misclassification (e.g. 'OK' in 'NOT OK').
    """
    if not text:
        return None
    raw = str(text).strip().upper()
    if raw in ('0', '0.0'):
        return False
    if raw in ('1', '1.0'):
        return True

    neg_pattern = r'\b(NO|FAIL|REJECT|FALSE|NOT\s+OK|NOT\s+GOOD|OUT\s+OF\s+SPEC|DEFECTIVE)\b'
    aff_pattern = r'\b(YES|PASS|OK|TRUE|GOOD|ACCEPTED)\b'

    has_neg = bool(re.search(neg_pattern, raw))
    has_aff = bool(re.search(aff_pattern, raw))

    if has_neg:
        return False
    if has_aff:
        return True
    return None


# ─── Tolerance Validator ──────────────────────────────────────────────────
class ToleranceValidator:
    """
    Validates a measured numeric value against an InspectionParameter's tolerance.
    Applies the 3 Mechanical Rules while preserving original DB spec values.
    """

    def validate(self, measured_value: float, parameter: InspectionParameter, voice_raw_text: str = '') -> ValidationResult:
        nominal      = float(parameter.nominal_value)
        upper_limit  = float(parameter.upper_limit)
        lower_limit  = float(parameter.lower_limit)
        deviation    = round(measured_value - nominal, 6)

        m_type = (parameter.measurement_type or '').lower()
        p_code = (parameter.parameter_code or '').upper()
        p_name = (parameter.parameter_name or '').upper()
        p_unit = (parameter.unit or '').lower()
        p_tech = (getattr(parameter, 'measurement_technique', '') or '').upper()

        # Visual check is strictly determined by configured type, unit, or technique
        is_visual = (
            m_type == 'visual'
            or p_unit in ['pass', 'yes/no', 'yes / no', 'visual', 'pass/fail', 'pass / fail']
            or 'PLUG GAUGE' in p_name
            or 'PLUGE GAUGE' in p_tech
            or 'PLUG GAUGE' in p_tech
            or 'VISUALLY' in p_tech
            or 'COMPARE WITH MASTER' in p_tech
        )

        if is_visual:
            # Rule 2: Visual Pass/Fail Check (1.0 = PASS / YES, 0.0 = REJECT / NO)
            text_ans = parse_visual_text(voice_raw_text)
            num_ans = None
            if measured_value is not None:
                try:
                    num_ans = float(measured_value) >= 0.5
                except (ValueError, TypeError):
                    pass

            if text_ans is False:
                # Explicit negative ALWAYS fails, even if numeric was >= 0.5
                is_within = False
                message = 'Visual Inspection REJECTED (NO).'
            elif text_ans is True:
                if num_ans is False:
                    # Contradictory: voice YES but numeric < 0.5
                    is_within = False
                    message = 'Contradictory visual reading (Voice: YES, Numeric: NO).'
                else:
                    is_within = True
                    message = 'Visual Inspection PASSED (YES).'
            elif num_ans is not None:
                is_within = num_ans
                message = 'Visual Inspection PASSED (YES).' if is_within else 'Visual Inspection REJECTED (NO).'
            else:
                is_within = False
                message = 'Visual Inspection REJECTED (No valid input).'
        elif m_type == 'min_limit' or 'MIN' in p_name:
            # Rule 3A: Minimum Threshold (Any value >= nominal or lower_limit is OK)
            min_bound = nominal if nominal > 0 else lower_limit
            is_within = measured_value >= min_bound
            message = (
                f'Value {measured_value} {parameter.unit} meets minimum limit of {min_bound} {parameter.unit}.'
                if is_within
                else f'Value {measured_value} {parameter.unit} is below minimum limit of {min_bound} {parameter.unit}.'
            )
        elif m_type in ['max_limit', 'surface'] or 'MAX' in p_name:
            # Rule 3B: Maximum Threshold (Any roughness <= nominal is OK)
            max_bound = nominal if nominal > 0 else upper_limit
            is_within = measured_value <= max_bound
            message = (
                f'Measurement {measured_value} {parameter.unit} is within maximum allowed {max_bound} {parameter.unit}.'
                if is_within
                else f'Measurement {measured_value} {parameter.unit} exceeds maximum allowed {max_bound} {parameter.unit}.'
            )
        else:
            # Rule 1: Specific Limits Range
            is_within = lower_limit <= measured_value <= upper_limit
            if is_within:
                message = f'Value {measured_value} {parameter.unit} is within specification.'
            else:
                direction = 'above' if measured_value > upper_limit else 'below'
                message   = (
                    f'Value {measured_value} {parameter.unit} is {direction} specification. '
                    f'Allowed: [{lower_limit}, {upper_limit}] {parameter.unit}'
                )

        status = 'ok' if is_within else 'out_of_spec'

        return ValidationResult(
            measured_value = measured_value,
            nominal        = nominal,
            upper_limit    = upper_limit,
            lower_limit    = lower_limit,
            status         = status,
            deviation      = deviation,
            is_critical    = parameter.is_critical and not is_within,
            message        = message,
        )


# ─── Inspection Service ───────────────────────────────────────────────────
class InspectionService:
    """
    Orchestrates the full inspection workflow:
    1. Create session (PostgreSQL with JSONB document_payload)
    2. Record measurements (JSONB document + PostgreSQL counters)
    3. Validate against tolerances
    4. Push WebSocket events
    5. Complete / review session
    """

    def __init__(self):
        self.validator  = ToleranceValidator()

    # ── Create Session ────────────────────────────────────────────────────
    def create_session(
        self,
        part,
        machine,
        operator,
        inspection_type: str = 'first_piece',
        shift: str = 'A',
        supervisor=None,
        template_id=None,
        trial_number: int = 1,
        parent_session_id: str = None,
        hourly_slot: int = 1,
    ) -> InspectionSession:
        """
        Creates a PostgreSQL InspectionSession + initialises MongoDB document.
        """
        actual_inspection_type = inspection_type or 'first_piece'

        # Validate trial number max 3 for first_piece
        if actual_inspection_type == 'first_piece' and trial_number > 3:
            raise ValueError("First Piece Inspection is limited to a maximum of 3 attempts (1st PC #1, #2, #3).")

        # Get the specific template by template_id, or fall back to first active match
        if template_id:
            template = InspectionTemplate.objects.prefetch_related('parameters', 'process_parameters').get(
                pk=template_id,
                is_active=True,
            )
        else:
            template = InspectionTemplate.objects.prefetch_related('parameters', 'process_parameters').filter(
                part=part,
                inspection_type=actual_inspection_type,
                is_active=True,
            ).first()

            if not template:
                template = InspectionTemplate.objects.prefetch_related('parameters', 'process_parameters').filter(
                    part=part,
                    is_active=True,
                ).first()

        if not template:
            raise ValueError("No active inspection template found.")

        parameters         = list(template.parameters.order_by('sequence_order'))
        process_parameters = list(template.process_parameters.filter(is_active=True).order_by('sequence_order')) if actual_inspection_type == 'first_piece' else []
        total_params       = len(parameters)

        # H4 FIX: Wrap existence check + create in an atomic transaction with a
        # row-level lock. Without this, two simultaneous POST /start/ requests for
        # the same machine+part+shift both read "no session exists" and both create
        # one : resulting in duplicate sessions and split/corrupt measurement data.
        #
        # select_for_update() holds a DB lock on matching rows for the duration of
        # the transaction. The second request blocks until the first commits, then
        # finds the newly-created session and returns it instead of creating again.
        from django.utils import timezone as django_tz
        from django.db import transaction
        today = django_tz.localdate()
        filter_kwargs = {
            'machine': machine,
            'part': part,
            'shift': shift,
            'started_at__date': today,
            'inspection_type': actual_inspection_type,
            'template': template,
        }
        if actual_inspection_type == 'first_piece':
            filter_kwargs['trial_number'] = trial_number
        elif actual_inspection_type == 'hourly':
            filter_kwargs['hourly_unlocked_slot'] = hourly_slot

        with transaction.atomic():
            # Lock any matching rows so concurrent requests queue up here
            existing_session = (
                InspectionSession.objects
                .select_for_update()
                .filter(**filter_kwargs)
                .exclude(
                    status__in=[
                        InspectionSession.Status.COMPLETED,
                        InspectionSession.Status.APPROVED,
                    ]
                )
                .order_by('-started_at')
                .first()
            )

            if existing_session and not (actual_inspection_type == 'first_piece' and trial_number > 1 and not parent_session_id):
                return existing_session

            # No existing session : safe to create now (lock still held)
            session_id     = uuid.uuid4()

            parent_session = None
            initial_measurements = []
            rejected_codes = set()

            if parent_session_id and str(parent_session_id).strip():
                clean_parent_id = str(parent_session_id).strip()
                try:
                    parent_uuid = uuid.UUID(clean_parent_id)
                    parent_session = InspectionSession.objects.filter(session_id=parent_uuid).first()
                except (ValueError, TypeError, AttributeError):
                    parent_session = None

            if parent_session:
                parent_doc = doc_utils.get_document(parent_session)
                if parent_doc:
                    rejected_list = parent_doc.get('rejected_parameters') or []
                    if rejected_list:
                        rejected_codes = set(rejected_list)
                    else:
                        for p_sum in parent_doc.get('parameter_summary', []):
                            if p_sum.get('status') == 'out_of_spec':
                                rejected_codes.add(p_sum.get('parameter_code'))

                    parent_measurements = parent_doc.get('measurements', [])
                    for m in parent_measurements:
                        code = m.get('parameter_code')
                        if code and code not in rejected_codes and m.get('status') == 'ok':
                            m_copy = dict(m)
                            m_copy['carried_forward'] = True
                            initial_measurements.append(m_copy)

            # Persist one identity for every session that belongs to the same
            # combined report. Retrials inherit their parent's identity. For
            # hourly sessions created without a parent, reuse the latest
            # matching First Piece identity when it is unambiguous.
            report_group_id = None
            if actual_inspection_type in ('first_piece', 'hourly'):
                report_group_id = parent_session.report_group_id if parent_session else None
                if not report_group_id:
                    report_group_id = getattr(template, 'operation_key', None)

            if actual_inspection_type in ('first_piece', 'hourly') and not report_group_id:
                operation_name = (template.name or '').strip()
                matching_first_piece = InspectionSession.objects.filter(
                    machine=machine,
                    part=part,
                    shift=shift,
                    started_at__date=today,
                    inspection_type='first_piece',
                ).order_by('-trial_number', '-started_at')
                if operation_name:
                    matching_first_piece = matching_first_piece.filter(
                        Q(template__name__iexact=operation_name) |
                        Q(document_payload__operation_name__iexact=operation_name)
                    )
                    first_piece = matching_first_piece.first()
                else:
                    # With unnamed templates there is no safe name-based
                    # identity. Reuse a group only when exactly one distinct
                    # First Piece group exists for this machine/part/shift.
                    # Multiple unnamed operations remain isolated.
                    candidates = list(matching_first_piece.only('pk', 'report_group_id'))
                    group_ids = {item.report_group_id or item.session_id for item in candidates}
                    if len(group_ids) == 1:
                        first_piece = candidates[0]
                    else:
                        first_piece = None
                if first_piece:
                    report_group_id = first_piece.report_group_id or first_piece.session_id
                    if not first_piece.report_group_id:
                        first_piece.report_group_id = report_group_id
                        first_piece.save(update_fields=['report_group_id'])
                    # Backfill the same legacy report scope when a new
                    # session reconnects to an older report created before
                    # report_group_id existed.
                    matching_first_piece.filter(
                        report_group_id__isnull=True,
                    ).update(report_group_id=report_group_id)

            # Final/approval sessions are not part of the combined live
            # First Piece + hourly report. Keep them ungrouped so their
            # measurements cannot be classified into either column family.

            initial_recorded_count = len(initial_measurements)

            # 1. Create PostgreSQL session (inside atomic block : lock held until commit)
            session = InspectionSession.objects.create(
                session_id           = session_id,
                part                 = part,
                machine              = machine,
                operator             = operator,
                supervisor           = supervisor,
                template             = template,
                inspection_type      = actual_inspection_type,
                shift                = shift,
                trial_number         = trial_number,
                hourly_unlocked_slot = hourly_slot if actual_inspection_type == 'hourly' else 0,
                parent_session       = parent_session,
                report_group_id      = report_group_id,
                total_parameters     = total_params,
                recorded_count       = initial_recorded_count,
            )

        carried_map = {m['parameter_code']: m for m in initial_measurements}
        param_summary_list = []

        for p in parameters:
            code = p.parameter_code
            tech = p.measurement_technique or 'VERNIER CALIPER'
            samp = p.sample_size or '5NOS/SHIFT'

            if code in carried_map:
                param_summary_list.append({
                    'parameter_code':        code,
                    'parameter_name':        p.parameter_name,
                    'unit':                  p.unit,
                    'nominal':               float(p.nominal_value),
                    'upper_limit':           float(p.upper_limit),
                    'lower_limit':           float(p.lower_limit),
                    'is_critical':           p.is_critical,
                    'measurement_technique': tech,
                    'evaluation_technique':  tech,
                    'sample_size':           samp,
                    'sample_frequency':      samp,
                    'status':                'ok',
                    'measured_value':        carried_map[code].get('measured_value'),
                    'carried_forward':       True,
                })
            else:
                param_summary_list.append({
                    'parameter_code':        code,
                    'parameter_name':        p.parameter_name,
                    'unit':                  p.unit,
                    'nominal':               float(p.nominal_value),
                    'upper_limit':           float(p.upper_limit),
                    'lower_limit':           float(p.lower_limit),
                    'is_critical':           p.is_critical,
                    'measurement_technique': tech,
                    'evaluation_technique':  tech,
                    'sample_size':           samp,
                    'sample_frequency':      samp,
                    'status':                'pending',
                })

        proc_param_summary_list = []
        if actual_inspection_type == 'first_piece':
            for pp in process_parameters:
                proc_param_summary_list.append({
                    'parameter_code':        pp.parameter_code,
                    'parameter_name':        pp.parameter_name,
                    'data_type':             pp.data_type,
                    'unit':                  pp.unit or '',
                    'specification':         pp.specification or '',
                    'nominal':               float(pp.nominal_value) if pp.nominal_value is not None else None,
                    'upper_limit':           float(pp.upper_limit) if pp.upper_limit is not None else None,
                    'lower_limit':           float(pp.lower_limit) if pp.lower_limit is not None else None,
                    'is_required':           pp.is_required,
                    'status':                'pending',
                    'is_process_parameter':  True,
                })

        # Resolve operation name: use template.name if set, else fall back to
        # inspection_type display label so the dashboard always shows a meaningful name.
        insp_type_labels = {
            'first_piece': '1st Piece Cum In-Process Inspection',
            'hourly':      'Hourly In-Process Inspection',
            'final':       'Final Inspection',
            'setup_approval': 'Setup Approval',
        }
        operation_name = (
            template.name.strip()
            if template and template.name and template.name.strip()
            else insp_type_labels.get(actual_inspection_type, actual_inspection_type.replace('_', ' ').title())
        )

        # 2. Initialize document_payload JSONB field
        doc_utils.initialize_document(
            session=session,
            part_number=part.part_number,
            part_name=part.part_name,
            machine_code=machine.machine_code,
            plant_id=machine.plant_id,
            operator_id=operator.id,
            operator_name=operator.get_full_name(),
            supervisor_id=supervisor.id if supervisor else None,
            inspection_type=actual_inspection_type,
            template_id=template.pk if template else None,
            operation_name=operation_name,
            hourly_slot=hourly_slot if actual_inspection_type == 'hourly' else 0,
            shift=shift,
            trial_number=trial_number,
            parent_session_id=parent_session_id,
            started_at=datetime.now(timezone.utc),
            parameter_summary=param_summary_list,
            process_parameter_summary=proc_param_summary_list,
            initial_measurements=initial_measurements,
            save=True
        )
        if rejected_codes:
            doc_utils.update_document(session, {'rejected_parameters': list(rejected_codes)}, save=True)


        self._push_session_event(session, 'session_started')
        return session

    # ── Record Measurement ────────────────────────────────────────────────
    @transaction.atomic
    def record_measurement(
        self,
        session_id: str,
        parameter_code: str,
        measured_value: float,
        voice_raw_text: str = '',
        audio_file_path: str = '',
        method: str = 'voice',       # 'voice' | 'manual'
        hourly_slot: int = None,
        inspection_type: str = None,
    ) -> dict:
        """
        Records a single measurement for a parameter.
        - Validates against tolerance
        - Saves to MongoDB
        - Updates PostgreSQL counters
        - Pushes WebSocket event to dashboard
        """
        # Fetch session
        session = InspectionSession.objects.select_related(
            'part', 'machine', 'template'
        ).get(session_id=session_id)

        # Lock every session in this report scope in a stable order. This
        # serializes measurement writes, snapshot refreshes, and cleanup while
        # avoiding lock-order races between different companion sessions.
        list(
            self._report_scope_queryset(session)
            .select_for_update(of=('self',))
            .order_by('pk')
        )
        session = InspectionSession.objects.select_related(
            'part', 'machine', 'template'
        ).get(pk=session.pk)

        # Whole operation completion lock
        op_name = session.template.name if session.template and session.template.name else (session.inspection_type or 'Inspection')
        if (session.status or '').lower() in ['completed', 'approved']:
            raise PermissionError(f"Operation '{op_name}' has been fully completed and locked against edits.")

        # First piece finalize lock (protects 1st PC #1..#3 from post-finalization edits)
        if (inspection_type == 'first_piece' or session.inspection_type == 'first_piece') and (
            session.is_first_piece_finalized or session.status in [InspectionSession.Status.FINALIZED_PASSED, InspectionSession.Status.FINALIZED_FAILED]
        ):
            raise PermissionError(f"1st Piece Inspection for Operation '{op_name}' is finalized and locked.")

        # Fetch parameter safely from Redis cache or DB by part_id and parameter_code
        parameter = _get_cached_parameter(session.part_id, parameter_code)

        process_parameter = None
        if not parameter:
            process_parameter = _get_cached_process_parameter(session.part_id, parameter_code)

        if not parameter and not process_parameter:
            # Removed dangerous fallback that substituted wrong tolerances (C2)
            raise ValueError(f"Parameter '{parameter_code}' not found for part {session.part.part_number}.")

        current_slot = hourly_slot if (hourly_slot is not None and hourly_slot > 0) else (session.hourly_unlocked_slot or 1)

        # Determine measurement classification:
        # Operator entries -> hourly (1/HR through 8/HR)
        # Inspector entries -> first_piece (1ST PC #1, 1ST PC #2, 1ST PC #3)
        if inspection_type == 'first_piece' or (not inspection_type and session.inspection_type == 'first_piece' and (hourly_slot is None or hourly_slot == 0)):
            meas_type = 'first_piece'
            meas_trial = session.trial_number or 1
            meas_slot = 0
        else:
            meas_type = 'hourly'
            meas_slot = current_slot if current_slot > 0 else 1
            meas_trial = 0

        # Check if measurement already exists in document_payload
        measurement_exists = doc_utils.measurement_exists(
            session=session,
            parameter_code=parameter_code,
            inspection_type=meas_type,
            trial_number=meas_trial,
            hourly_slot=meas_slot
        )

        # Handle Process Parameter measurement recording & validation
        if process_parameter:
            dt = process_parameter.data_type
            mtype = (process_parameter.measurement_type or '').lower()
            status_val = 'ok'
            dev = 0.0
            msg = f"Process parameter '{process_parameter.parameter_name}' recorded."
            is_crit = False

            if dt == 'numeric':
                num_val = float(measured_value) if measured_value is not None else 0.0
                nom = float(process_parameter.nominal_value) if process_parameter.nominal_value is not None else 0.0
                dev = round(num_val - nom, 6)
                ll = float(process_parameter.lower_limit) if process_parameter.lower_limit is not None else None
                ul = float(process_parameter.upper_limit) if process_parameter.upper_limit is not None else None

                p_tech = (getattr(process_parameter, 'measurement_technique', '') or '').upper()
                p_name = (process_parameter.parameter_name or '').upper()

                is_visual_proc = (
                    mtype == 'visual'
                    or (process_parameter.unit or '').lower() in ['pass', 'yes/no', 'yes / no', 'visual', 'pass/fail', 'pass / fail']
                    or 'PLUG GAUGE' in p_name
                    or 'PLUGE GAUGE' in p_tech
                    or 'PLUG GAUGE' in p_tech
                    or 'VISUALLY' in p_tech
                    or 'COMPARE WITH MASTER' in p_tech
                )

                if is_visual_proc:
                    text_ans = parse_visual_text(voice_raw_text)
                    num_ans = num_val >= 0.5 if measured_value is not None else None

                    if text_ans is False:
                        is_within = False
                        msg = 'Visual Inspection REJECTED (NO).'
                    elif text_ans is True:
                        if num_ans is False:
                            is_within = False
                            msg = 'Contradictory visual reading (Voice: YES, Numeric: NO).'
                        else:
                            is_within = True
                            msg = 'Visual Inspection PASSED (YES).'
                    elif num_ans is not None:
                        is_within = num_ans
                        msg = 'Visual Inspection PASSED (YES).' if is_within else 'Visual Inspection REJECTED (NO).'
                    else:
                        is_within = False
                        msg = 'Visual Inspection REJECTED (No valid input).'
                elif mtype == 'min_limit' or 'MIN' in (process_parameter.parameter_name or '').upper():
                    min_bound = nom if nom > 0 else (ll if ll is not None else 0.0)
                    is_within = num_val >= min_bound
                    msg = f"Value {num_val} {process_parameter.unit} meets minimum limit of {min_bound}." if is_within else f"Value {num_val} {process_parameter.unit} is below minimum limit of {min_bound}."
                elif mtype in ['max_limit', 'surface'] or 'MAX' in (process_parameter.parameter_name or '').upper():
                    max_bound = nom if nom > 0 else (ul if ul is not None else 99999.0)
                    is_within = num_val <= max_bound
                    msg = f"Measurement {num_val} {process_parameter.unit} is within maximum allowed {max_bound}." if is_within else f"Measurement {num_val} {process_parameter.unit} exceeds maximum allowed {max_bound}."
                else:
                    # Dimensional / Weight / Range
                    if ll is not None and ul is not None:
                        is_within = ll <= num_val <= ul
                    else:
                        is_within = True
                    msg = f"Value {num_val} {process_parameter.unit} is within specification." if is_within else f"Value {num_val} {process_parameter.unit} is outside specification."

                status_val = 'ok' if is_within else 'out_of_spec'
            elif dt == 'yes_no':
                text_ans = parse_visual_text(voice_raw_text)
                num_ans = None
                if measured_value is not None:
                    try:
                        num_ans = float(measured_value) >= 0.5
                    except (ValueError, TypeError):
                        pass

                if text_ans is False:
                    # Explicit negative response strictly takes precedence
                    status_val = 'out_of_spec'
                    msg = "Visual Inspection REJECTED (NO)."
                elif text_ans is True:
                    if num_ans is False:
                        status_val = 'out_of_spec'
                        msg = "Contradictory visual reading (Voice: YES, Numeric: NO)."
                    else:
                        status_val = 'ok'
                        msg = "Visual Inspection PASSED (YES)."
                elif num_ans is not None:
                    status_val = 'ok' if num_ans else 'out_of_spec'
                    msg = "Visual Inspection PASSED (YES)." if num_ans else "Visual Inspection REJECTED (NO)."
                else:
                    status_val = 'out_of_spec'
                    msg = "Visual Inspection REJECTED (No valid input)."
            elif dt in ['text', 'selection']:
                str_val = str(voice_raw_text or measured_value or '').strip()
                if process_parameter.specification:
                    exp_val = process_parameter.specification.strip()
                    if str_val.lower() != exp_val.lower():
                        status_val = 'out_of_spec'
                        msg = f"Value '{str_val}' does not match expected '{exp_val}'."

            measurement = {
                'parameter_code':        parameter_code,
                'parameter_name':        process_parameter.parameter_name,
                'unit':                  process_parameter.unit,
                'nominal':               float(process_parameter.nominal_value) if process_parameter.nominal_value is not None else None,
                'upper_limit':           float(process_parameter.upper_limit) if process_parameter.upper_limit is not None else None,
                'lower_limit':           float(process_parameter.lower_limit) if process_parameter.lower_limit is not None else None,
                'measured_value':        measured_value,
                'deviation':             dev,
                'status':                status_val,
                'is_critical_fail':      is_crit,
                'is_process_parameter':  True,
                'voice_raw_text':        voice_raw_text,
                'audio_file_path':       audio_file_path,
                'method':                method,
                'inspection_type':       meas_type,
                'trial_number':          meas_trial,
                'hourly_slot':           meas_slot,
                'recorded_at':           datetime.now(timezone.utc).isoformat(),
            }

            if measurement_exists:
                # Update existing measurement in JSONB
                doc_utils.update_measurement(
                    session=session,
                    parameter_code=parameter_code,
                    inspection_type=meas_type,
                    trial_number=meas_trial,
                    hourly_slot=meas_slot,
                    updates={
                        'measured_value': measured_value,
                        'status': status_val,
                        'deviation': dev,
                        'voice_raw_text': voice_raw_text,
                        'recorded_at': datetime.now(timezone.utc).isoformat(),
                    },
                    save=False
                )

                # Update parameter summary
                doc_utils.update_process_parameter_summary(
                    session=session,
                    parameter_code=parameter_code,
                    updates={
                        'status': status_val,
                        'measured_value': measured_value,
                    },
                    save=True
                )
            else:
                # Add new measurement to JSONB
                doc_utils.add_measurement(session=session, measurement=measurement, save=False)

                # Update parameter summary
                doc_utils.update_process_parameter_summary(
                    session=session,
                    parameter_code=parameter_code,
                    updates={
                        'status': status_val,
                        'measured_value': measured_value,
                    },
                    save=True
                )

            # Auto-sync reading into process_param_entries for Setup Approval Report
            t_num = meas_trial if (meas_trial >= 1 and meas_trial <= 3) else 1
            t_key = f"trial_{t_num}"
            entry_val = str(voice_raw_text or measured_value or '').strip()

            doc_utils.add_or_update_process_param_entry(
                session=session,
                parameter_code=parameter_code,
                parameter_name=process_parameter.parameter_name,
                specification=process_parameter.specification or '',
                trial_key=t_key,
                value=entry_val,
                save=True
            )

            # Push WebSocket event for Process Parameter
            self._push_process_param_event(
                session, process_parameter, status_val, measured_value,
                voice_raw_text=voice_raw_text, method=method,
                meas_type=meas_type, meas_trial=meas_trial, meas_slot=meas_slot,
            )

            self._safe_refresh_finalized_report_snapshots(session)

            return {
                'parameter_code': parameter_code,
                'measured_value': measured_value,
                'status':         status_val,
                'deviation':      dev,
                'message':        msg,
                'is_critical':    is_crit,
                'progress':       session.progress_percent,
            }

        # Check hourly authorization
        if session.inspection_type == 'hourly' or current_slot > 0:
            first_piece_active = InspectionSession.objects.filter(
                machine=session.machine,
                part=session.part,
                inspection_type='first_piece',
                status__in=[InspectionSession.Status.FINALIZED_PASSED, InspectionSession.Status.APPROVED],
            ).exists()
            if not first_piece_active and not session.is_setup_approved and session.hourly_unlocked_slot == 0:
                session.is_setup_approved = True
                session.save(update_fields=['is_setup_approved'])

        # Validate
        result = self.validator.validate(measured_value, parameter, voice_raw_text=voice_raw_text)

        # Build measurement document
        measurement = {
            'parameter_code':   parameter_code,
            'parameter_name':   parameter.parameter_name,
            'unit':             parameter.unit,
            'nominal':          float(parameter.nominal_value),
            'upper_limit':      float(parameter.upper_limit),
            'lower_limit':      float(parameter.lower_limit),
            'measured_value':   measured_value,
            'deviation':        result.deviation,
            'status':           result.status,
            'is_critical_fail': result.is_critical,
            'voice_raw_text':   voice_raw_text,
            'audio_file_path':  audio_file_path,
            'method':           method,
            'inspection_type':  meas_type,
            'trial_number':     meas_trial,
            'hourly_slot':      meas_slot,
            'recorded_at':      datetime.now(timezone.utc).isoformat(),
        }

        # Update document_payload in PostgreSQL
        if measurement_exists:
            # Update existing measurement
            doc_utils.update_measurement(
                session=session,
                parameter_code=parameter_code,
                inspection_type=meas_type,
                trial_number=meas_trial,
                hourly_slot=meas_slot,
                updates={
                    'measured_value': measured_value,
                    'status': result.status,
                    'deviation': result.deviation,
                    'voice_raw_text': voice_raw_text,
                    'recorded_at': datetime.now(timezone.utc).isoformat(),
                },
                save=False
            )

            # Update parameter summary
            doc_utils.update_parameter_summary(
                session=session,
                parameter_code=parameter_code,
                updates={
                    'status': result.status,
                    'measured_value': measured_value,
                },
                save=True
            )
        else:
            # Add new measurement
            doc_utils.add_measurement(session=session, measurement=measurement, save=False)

            # Update parameter summary
            doc_utils.update_parameter_summary(
                session=session,
                parameter_code=parameter_code,
                updates={
                    'status': result.status,
                    'measured_value': measured_value,
                },
                save=True
            )

        # Update PostgreSQL counters and reminder timestamps atomically
        from django.utils import timezone as django_timezone
        now_dt = django_timezone.now()

        update_dict = {
            'last_measurement_at': now_dt,
            'operator_reminded': False,
            'supervisor_escalated': False,
        }
        
        if not measurement_exists:
            update_dict['recorded_count'] = F('recorded_count') + 1
            session.recorded_count += 1

        if result.status == 'out_of_spec':
            update_dict['has_ooc'] = True
            session.has_ooc = True
        if result.is_critical:
            update_dict['has_critical_fail'] = True
            session.has_critical_fail = True

        session.last_measurement_at = now_dt
        InspectionSession.objects.filter(pk=session.pk).update(**update_dict)

        # Push WebSocket event
        self._push_measurement_event(
            session, parameter, result, measured_value,
            voice_raw_text=voice_raw_text, method=method,
            meas_type=meas_type, meas_trial=meas_trial, meas_slot=meas_slot
        )

        self._safe_refresh_finalized_report_snapshots(session)

        return {
            'parameter_code': parameter_code,
            'measured_value': measured_value,
            'status':         result.status,
            'deviation':      result.deviation,
            'message':        result.message,
            'is_critical':    result.is_critical,
            'progress':       session.progress_percent,
        }

    # ── Complete Session ──────────────────────────────────────────────────
    def complete_session(self, session_id: str) -> InspectionSession:
        """Marks session as pending supervisor review."""
        session = InspectionSession.objects.get(session_id=session_id)
        now = datetime.now(timezone.utc)

        session.status       = InspectionSession.Status.PENDING_REVIEW
        session.completed_at = now
        session.save(update_fields=['status', 'completed_at'])

        # Update document_payload status
        doc_utils.update_document(
            session=session,
            updates={
                'status': 'pending_review',
                'completed_at': now.isoformat(),
            },
            save=True
        )

        # H5 FIX: Per-operation slot unlock.
        # When an hourly session is completed, check if ALL operations
        # (templates) for this machine+part+shift+slot are also done.
        # Only then unlock the next slot on the parent first_piece session.
        if session.inspection_type == 'hourly':
            current_slot = session.hourly_unlocked_slot
            from django.utils import timezone as django_tz
            today = django_tz.localdate()

            # H5 FIX (Sourcery review): derive total_ops from CONFIGURED templates,
            # not from sessions that already exist for this slot.
            #
            # Bug in original logic: if only OP-10 started Slot 2, total_ops = 1
            # and completed_ops = 1 immediately after OP-10 finishes, so the next
            # slot unlocks even though OP-02 hasn't started yet.
            #
            # Correct approach: count how many hourly InspectionTemplates are
            # configured for this part. That is the expected number of operations
            # that must all complete before the slot advances.
            from apps.parts.models import InspectionTemplate as _IT
            expected_op_ids = set(
                _IT.objects
                .filter(part=session.part, inspection_type='hourly')
                .values_list('id', flat=True)
            )
            total_ops = len(expected_op_ids)

            if total_ops == 0:
                # No hourly templates configured — nothing to gate on; skip unlock
                all_ops_done = False
            else:
                # Count how many of those configured templates have a completed
                # session for this exact slot today
                completed_op_ids = set(
                    InspectionSession.objects.filter(
                        machine=session.machine,
                        part=session.part,
                        shift=session.shift,
                        inspection_type='hourly',
                        hourly_unlocked_slot=current_slot,
                        started_at__date=today,
                        status__in=['completed', 'pending_review', 'approved', 'finalized_passed'],
                        template_id__in=expected_op_ids,
                    ).values_list('template_id', flat=True).distinct()
                )
                all_ops_done = (completed_op_ids >= expected_op_ids)

            if all_ops_done:
                # Advance the next slot on the first_piece (setup) session
                fp_session = InspectionSession.objects.filter(
                    machine=session.machine,
                    part=session.part,
                    shift=session.shift,
                    inspection_type='first_piece',
                    started_at__date=today,
                    is_setup_approved=True,
                ).order_by('-started_at').first()

                if fp_session and fp_session.hourly_unlocked_slot == current_slot:
                    fp_session.hourly_unlocked_slot = current_slot + 1
                    fp_session.save(update_fields=['hourly_unlocked_slot'])
                    logger.info(
                        '[SLOT UNLOCK] All %d ops done for slot %d. Unlocked slot %d on FP session %s.',
                        total_ops, current_slot, current_slot + 1, fp_session.session_id,
                    )

        self._push_session_event(session, 'session_completed')
        return session

    # ── Finalize First Piece Session (Inspector Workflow) ─────────────────
    def finalize_first_piece_session(self, session_id: str, inspector) -> InspectionSession:
        """
        Inspector finalizes the First Piece Inspection independently.
        Generates First Piece PDF report and enables machine for production if PASSED.
        """
        session = InspectionSession.objects.get(session_id=session_id)
        if session.inspection_type != 'first_piece':
            raise ValueError("Only First Piece Inspections can be finalized via this workflow.")

        now = datetime.now(timezone.utc)
        doc = self.get_session_document(str(session_id)) or {}
        summary_list = doc.get('parameter_summary', [])

        # │► Belt-and-suspenders guard: never finalize an empty session.
        # If the MongoDB document has no measurements AND parameter_summary is empty,
        # that means 0 parameters were recorded. This must NEVER produce 'finalized_passed'.
        # The Flutter frontend also guards this, but we enforce it on the backend too.
        measurements = doc.get('measurements', [])
        if not measurements and not summary_list:
            raise ValueError(
                "Cannot finalize: No measurements have been recorded for this First Piece Inspection session. "
                "Record at least one parameter measurement before finalizing."
            )

        has_out_of_spec = any(p.get('status') == 'out_of_spec' for p in summary_list)

        if has_out_of_spec:
            session.status = InspectionSession.Status.FINALIZED_FAILED
            session.is_setup_approved = False
        else:
            session.status = InspectionSession.Status.FINALIZED_PASSED
            session.is_setup_approved = True
            session.hourly_unlocked_slot = 1

        session.is_first_piece_finalized = True
        session.finalized_at = now
        session.finalized_by = inspector
        session.completed_at = now

        # Generate official First Piece Inspection PDF report
        try:
            from .pdf_generator import generate_first_piece_pdf
            pdf_path = generate_first_piece_pdf(session, doc)
            session.pdf_report_path = pdf_path
        except Exception as e:
            logger.error(f"Error generating first piece PDF: {e}")

        session.save(update_fields=['status', 'is_first_piece_finalized', 'finalized_at', 'finalized_by', 'completed_at', 'is_setup_approved', 'hourly_unlocked_slot', 'pdf_report_path'])

        # Update document_payload
        doc_utils.update_document(
            session=session,
            updates={
                'status': session.status,
                'is_first_piece_finalized': True,
                'is_setup_approved': session.is_setup_approved,
                'finalized_at': now.isoformat(),
                'finalized_by_id': inspector.id,
                'finalized_by_name': inspector.get_full_name(),
                'completed_at': now.isoformat(),
                'hourly_unlocked_slot': session.hourly_unlocked_slot,
                'pdf_report_path': session.pdf_report_path,
            },
            save=True
        )

        # Persist the complete First Piece + hourly report before any live
        # sessions are eligible for cleanup.
        snapshot = self.get_session_document(
            str(session.session_id),
            use_finalized_snapshot=False,
        )
        if snapshot:
            InspectionSession.objects.filter(pk=session.pk).update(
                finalized_report_snapshot=snapshot,
            )
            session.finalized_report_snapshot = snapshot

        self._push_session_event(session, 'first_piece_finalized')
        return session


    # ── Supervisor Review ─────────────────────────────────────────────────
    def review_session(
        self,
        session_id: str,
        action: str,          # 'approve' | 'reject'
        supervisor,
        remark: str = '',
        rejected_parameters: list = None,
    ) -> InspectionSession:
        """Supervisor approves or rejects an inspection session."""
        session = InspectionSession.objects.get(session_id=session_id)
        now     = datetime.now(timezone.utc)

        new_status = (
            InspectionSession.Status.APPROVED
            if action == 'approve'
            else InspectionSession.Status.REJECTED
        )

        doc = doc_utils.get_document(session)
        if action == 'reject':
            if not rejected_parameters and doc:
                latest_measurements = doc.get('measurements', [])
                if latest_measurements:
                    latest_trial = max(m.get('trial_number', 1) for m in latest_measurements)
                    rejected_parameters = list(set([
                        m['parameter_code'] for m in latest_measurements
                        if m.get('trial_number', 1) == latest_trial and m.get('status') == 'out_of_spec'
                    ]))
                if not rejected_parameters and 'parameter_summary' in doc:
                    rejected_parameters = [
                        p['parameter_code'] for p in doc['parameter_summary']
                        if p.get('status') == 'out_of_spec'
                    ]
        else:
            rejected_parameters = []

        session.status            = new_status
        session.supervisor        = supervisor
        session.supervisor_remark = remark
        if action == 'approve':
            session.is_setup_approved = True
            if session.hourly_unlocked_slot == 0:
                session.hourly_unlocked_slot = 1
        if action == 'reject':
            session.rejection_reason = remark
        session.reviewed_at       = now
        session.save(update_fields=['status', 'supervisor', 'supervisor_remark', 'rejection_reason', 'reviewed_at', 'is_setup_approved', 'hourly_unlocked_slot'])

        # Update document_payload
        doc_utils.update_document(
            session=session,
            updates={
                'status': new_status,
                'supervisor_id': supervisor.id,
                'supervisor_remark': remark,
                'rejection_reason': remark if action == 'reject' else '',
                'rejected_parameters': rejected_parameters,
                'is_setup_approved': session.is_setup_approved,
                'hourly_unlocked_slot': session.hourly_unlocked_slot,
                'approved_at': now.isoformat() if action == 'approve' else None,
            },
            save=True
        )

        self._safe_refresh_finalized_report_snapshots(session)

        if action == 'reject':
            self._push_rejection_alert(session, remark, rejected_parameters)
        else:
            self._push_session_event(session, 'supervisor_action')

        return session

    def _report_scope_queryset(self, session, inspection_type=None):
        """Return sessions belonging to the same combined inspection report.

        First Piece and hourly templates can be different rows because they are
        configured for different inspection types.  The operation name is the
        shared identity between those templates; falling back to template_id
        keeps older unnamed templates isolated instead of mixing operations.
        """
        from django.utils import timezone as django_timezone

        queryset = InspectionSession.objects.filter(
            machine_id=session.machine_id,
            part_id=session.part_id,
            shift=session.shift,
        )
        if session.started_at:
            report_date = django_timezone.localtime(session.started_at).date()
            queryset = queryset.filter(started_at__date=report_date)

        if session.report_group_id:
            queryset = queryset.filter(report_group_id=session.report_group_id)
            if inspection_type:
                queryset = queryset.filter(inspection_type=inspection_type)
            return queryset

        template_name = (getattr(session.template, 'name', '') or '').strip()
        document_operation_name = (
            (doc_utils.get_document(session) or {}).get('operation_name') or ''
        ).strip()
        generic_operation_labels = {
            '1st Piece Cum In-Process Inspection',
            'Hourly In-Process Inspection',
            'Final Inspection',
            'Setup Approval',
        }
        operation_names = {
            name for name in (template_name, document_operation_name)
            if name and name not in generic_operation_labels
        }
        operation_name = template_name or document_operation_name
        if not template_name and document_operation_name in generic_operation_labels:
            operation_name = ''
        if operation_names and session.template_id:
            operation_filter = Q(template_id=session.template_id)
            for name in operation_names:
                operation_filter |= Q(template__name__iexact=name)
                operation_filter |= Q(
                    template_id__isnull=True,
                    document_payload__operation_name__iexact=name,
                )
            queryset = queryset.filter(operation_filter)
        elif operation_names:
            operation_filter = Q()
            for name in operation_names:
                operation_filter |= Q(template__name__iexact=name)
                operation_filter |= Q(document_payload__operation_name__iexact=name)
            queryset = queryset.filter(operation_filter)
        elif session.template_id:
            queryset = queryset.filter(template_id=session.template_id)
        else:
            # There is no safe shared identity. Never merge every unnamed,
            # template-less session into one report.
            queryset = queryset.filter(pk=session.pk)

        if inspection_type:
            queryset = queryset.filter(inspection_type=inspection_type)
        return queryset

    # ── Get Full Document ─────────────────────────────────────────────────
    def get_session_document(self, session_id: str, use_finalized_snapshot: bool = True) -> Optional[dict]:
        """Retrieve full inspection document from document_payload JSONB field."""
        session_obj = InspectionSession.objects.filter(session_id=str(session_id)).select_related(
            'operator', 'supervisor', 'finalized_by', 'machine__plant__factory', 'part'
        ).first()

        if not session_obj:
            return None

        # Once live companion sessions are removed, serve the permanent combined
        # report captured at finalization instead of rebuilding from deleted rows.
        # While companions still exist, rebuild from PostgreSQL instead. This
        # prevents an older snapshot from hiding a newly saved hourly or
        # First Piece measurement when snapshot refresh was unable to complete.
        live_companions_exist = self._report_scope_queryset(session_obj).exclude(
            pk=session_obj.pk,
        ).filter(
            inspection_type__in=('first_piece', 'hourly'),
        ).exists()
        if use_finalized_snapshot and session_obj.finalized_report_snapshot and not live_companions_exist and (
            session_obj.is_first_piece_finalized or
            session_obj.status in [
                InspectionSession.Status.APPROVED,
                InspectionSession.Status.FINALIZED_PASSED,
                InspectionSession.Status.FINALIZED_FAILED,
                InspectionSession.Status.COMPLETED,
            ]
        ):
            snapshot = dict(session_obj.finalized_report_snapshot)
            # Older snapshots were created before report_group_id existed.
            # Add the current relational identity at read time so the
            # frontend can match this finalized report with live companions.
            if session_obj.report_group_id and not snapshot.get('report_group_id'):
                snapshot['report_group_id'] = str(session_obj.report_group_id)
            return snapshot

        # Get document from JSONB field
        doc = doc_utils.get_document(session_obj)
        if not doc:
            doc = {}

        # Add session ID
        doc['_id'] = str(session_obj.session_id)
        doc['session_id'] = str(session_obj.session_id)

        # Add metadata from PostgreSQL fields
        shift_hrs = 8
        if session_obj.machine and session_obj.machine.plant and session_obj.machine.plant.factory:
            shift_hrs = session_obj.machine.plant.factory.shift_hours or 8

        doc['shift_hours'] = shift_hrs
        doc['total_hourly_slots'] = shift_hrs
        doc['inspection_type'] = session_obj.inspection_type
        doc['hourly_slot'] = session_obj.hourly_unlocked_slot or 1
        doc['hourly_unlocked_slot'] = session_obj.hourly_unlocked_slot
        doc['is_setup_approved'] = session_obj.is_setup_approved
        doc['status'] = session_obj.status
        doc['trial_number'] = session_obj.trial_number or 1
        doc['shift'] = session_obj.shift or 'I'

        # Timestamps : essential for report date display
        doc['started_at'] = session_obj.started_at.isoformat() if session_obj.started_at else None
        completed_at = getattr(session_obj, 'completed_at', None)
        doc['completed_at'] = completed_at.isoformat() if completed_at else None
        finalized_at = getattr(session_obj, 'finalized_at', None)
        doc['finalized_at'] = finalized_at.isoformat() if finalized_at else None

        # Part and machine metadata
        doc['part_number'] = session_obj.part.part_number if session_obj.part else None
        doc['part_name'] = session_obj.part.part_name if session_obj.part else None
        doc['machine_code'] = session_obj.machine.machine_code if session_obj.machine else None
        doc['template_name'] = session_obj.template.name if session_obj.template else ''
        doc['template_version'] = session_obj.template.version if session_obj.template else 1
        doc['report_group_id'] = str(session_obj.report_group_id) if session_obj.report_group_id else None

        # Add user names
        if session_obj.finalized_by:
            doc['finalized_by_name'] = session_obj.finalized_by.get_full_name()
            doc['inspector_name'] = session_obj.finalized_by.get_full_name()
        elif session_obj.operator and (session_obj.operator.role == 'inspector' or session_obj.inspection_type == 'first_piece'):
            doc['inspector_name'] = session_obj.operator.get_full_name()

        if session_obj.operator:
            doc['operator_name'] = session_obj.operator.get_full_name()

        if session_obj.supervisor:
            doc['supervisor_name'] = session_obj.supervisor.get_full_name()

        # Get setup approval entries if not present
        if not doc.get('process_param_entries'):
            from .models import SetupApproval
            setup_approval = SetupApproval.objects.filter(
                machine_id=session_obj.machine_id
            ).order_by('-submitted_at').first()

            if setup_approval and setup_approval.process_param_entries:
                doc['process_param_entries'] = setup_approval.process_param_entries

        # Merge measurements from related sessions (parent/child trials and hourly slots)
        root_session = session_obj.parent_session if session_obj.parent_session else session_obj
        root_session_id = str(root_session.session_id)

        # Find all related sessions
        related_sessions = InspectionSession.objects.filter(
            Q(session_id=root_session.session_id) |
            Q(parent_session=root_session) |
            Q(session_id=session_obj.session_id)
        ).select_related('operator', 'finalized_by')

        # Collect and deduplicate measurements
        meas_dict = {}

        def add_meas(m_item, def_type='first_piece', def_trial=1, def_slot=1):
            code = m_item.get('parameter_code')
            if not code:
                return

            # The owning session is authoritative for the report column. Older
            # payloads can contain a stale/misclassified inspection_type or slot
            # (for example a First Piece value labelled as hourly). Trusting the
            # embedded measurement metadata moves that value into the wrong
            # column in the merged Live Report.
            itype = def_type if def_type in ('first_piece', 'hourly') else (
                m_item.get('inspection_type') or def_type
            )

            if itype == 'first_piece':
                if m_item.get('carried_forward'):
                    # Preserving original trial or excluding duplicate copies:
                    # Carried-forward measurements originated in an earlier trial.
                    # Preserve the original trial if present, otherwise exclude the copied
                    # measurement so it does not overwrite or appear in the retry trial's columns.
                    orig_trial = m_item.get('trial_number')
                    if orig_trial and orig_trial != def_trial and orig_trial > 0:
                        trial = orig_trial
                    else:
                        return
                else:
                    trial = def_trial if def_trial is not None and def_trial > 0 else 1
                slot = 0
            else:
                trial = 0
                slot = def_slot if def_slot is not None and def_slot > 0 else 1

            key = (code, itype, slot if itype == 'hourly' else trial)
            m_copy = dict(m_item)
            m_copy['inspection_type'] = itype
            m_copy['trial_number'] = trial if itype == 'first_piece' else 0
            m_copy['hourly_slot'] = slot if itype == 'hourly' else 0
            meas_dict[key] = m_copy

        # Process related sessions
        for rel_sess in sorted(related_sessions, key=lambda x: x.trial_number):
            rel_doc = doc_utils.get_document(rel_sess)
            trial_no = rel_sess.trial_number or rel_doc.get('trial_number') or 1
            d_type = rel_sess.inspection_type
            d_slot = rel_sess.hourly_unlocked_slot or rel_doc.get('hourly_slot') or 1

            for m in rel_doc.get('measurements', []):
                add_meas(m, def_type=d_type, def_trial=trial_no, def_slot=d_slot)

        # Merge measurements from same-day first piece and hourly sessions
        if session_obj:
            # Get all First Piece sessions for this report scope.  The owning
            # session determines the trial column; measurement metadata is only
            # a compatibility fallback for legacy payloads.
            fp_sessions = self._report_scope_queryset(
                session_obj,
                inspection_type='first_piece',
            ).order_by('trial_number', 'started_at')
            for fp_s in fp_sessions:
                fp_doc = doc_utils.get_document(fp_s)
                t_no = fp_s.trial_number or fp_doc.get('trial_number') or 1
                if fp_s.finalized_by and 'inspector_name' not in doc:
                    doc['inspector_name'] = fp_s.finalized_by.get_full_name()
                for m in fp_doc.get('measurements', []):
                    add_meas(m, def_type='first_piece', def_trial=t_no, def_slot=1)

            # ── Authoritative override pass ───────────────────────────────────
            # Each first-piece session's own parameter_summary is the ground-truth
            # for that trial.  Raw measurements inside the (root/final) session doc
            # carry copies for ALL trials - those copies can overwrite earlier
            # trials' correct out_of_spec values.  We fix that by re-applying
            # each trial's own parameter_summary on top of meas_dict.
            for fp_s in fp_sessions:
                fp_doc = doc_utils.get_document(fp_s)
                t_no = fp_s.trial_number or fp_doc.get('trial_number') or 1
                for p in fp_doc.get('parameter_summary', []):
                    if p.get('measured_value') is None:
                        continue
                    if p.get('carried_forward'):
                        continue
                    key = (p['parameter_code'], 'first_piece', t_no)
                    meas_dict[key] = {
                        'parameter_code':   p['parameter_code'],
                        'parameter_name':   p.get('parameter_name'),
                        'unit':             p.get('unit'),
                        'nominal':          p.get('nominal'),
                        'upper_limit':      p.get('upper_limit'),
                        'lower_limit':      p.get('lower_limit'),
                        'measured_value':   p.get('measured_value'),
                        'deviation':        p.get('deviation', 0),
                        'status':           p.get('status', 'ok'),
                        'is_critical_fail': p.get('is_critical_fail', False),
                        'voice_raw_text':   p.get('voice_raw_text', ''),
                        'audio_file_path':  p.get('audio_file_path', ''),
                        'method':           p.get('method', 'voice'),
                        'inspection_type':  'first_piece',
                        'trial_number':     t_no,
                        'hourly_slot':      0,
                    }
                for p in fp_doc.get('process_parameter_summary', []):
                    if p.get('measured_value') is None:
                        continue
                    if p.get('carried_forward'):
                        continue
                    key = (p['parameter_code'], 'first_piece', t_no)
                    meas_dict[key] = {
                        'parameter_code':        p['parameter_code'],
                        'parameter_name':        p.get('parameter_name'),
                        'unit':                  p.get('unit'),
                        'nominal':               p.get('nominal'),
                        'upper_limit':           p.get('upper_limit'),
                        'lower_limit':           p.get('lower_limit'),
                        'measured_value':        p.get('measured_value'),
                        'deviation':             p.get('deviation', 0),
                        'status':                p.get('status', 'ok'),
                        'is_critical_fail':      False,
                        'is_process_parameter':  True,
                        'voice_raw_text':        p.get('voice_raw_text', ''),
                        'audio_file_path':       p.get('audio_file_path', ''),
                        'method':                p.get('method', 'voice'),
                        'inspection_type':       'first_piece',
                        'trial_number':          t_no,
                        'hourly_slot':           0,
                    }

            # Get all hourly sessions for this report scope.  The owning
            # session's hourly_unlocked_slot is authoritative for 1/HR..N/HR.
            hourly_sessions = self._report_scope_queryset(
                session_obj,
                inspection_type='hourly',
            ).order_by('hourly_unlocked_slot', 'started_at')
            for h_sess in hourly_sessions:
                h_doc = doc_utils.get_document(h_sess)
                slot = h_sess.hourly_unlocked_slot or h_doc.get('hourly_slot') or 1
                for m in h_doc.get('measurements', []):
                    add_meas(m, def_type='hourly', def_trial=0, def_slot=slot)

        doc['measurements'] = list(meas_dict.values())
        return doc

    def _refresh_finalized_report_snapshots(self, session) -> None:
        """Refresh finalized combined reports affected by a new measurement."""
        if not session.machine_id or not session.part_id or not session.started_at:
            return

        with transaction.atomic():
            # Lock the whole report scope before reading it. A measurement
            # write and cleanup therefore cannot interleave with snapshot
            # generation and replace a newer snapshot with stale data.
            scope = list(
                self._report_scope_queryset(session)
                .select_for_update(of=('self',))
                .order_by('pk')
            )
            protected_statuses = [
                InspectionSession.Status.APPROVED,
                InspectionSession.Status.FINALIZED_PASSED,
                InspectionSession.Status.FINALIZED_FAILED,
                InspectionSession.Status.COMPLETED,
            ]
            finalized_sessions = [
                scoped for scoped in scope
                if scoped.inspection_type == 'first_piece' and (
                    scoped.is_first_piece_finalized or scoped.status in protected_statuses
                )
            ]
            for finalized_session in finalized_sessions:
                snapshot = self.get_session_document(
                    str(finalized_session.session_id),
                    use_finalized_snapshot=False,
                )
                if snapshot:
                    InspectionSession.objects.filter(pk=finalized_session.pk).update(
                        finalized_report_snapshot=snapshot,
                    )

    def _safe_refresh_finalized_report_snapshots(self, session) -> None:
        """Refresh snapshots without turning a saved measurement into an API error."""
        try:
            self._refresh_finalized_report_snapshots(session)
        except Exception:
            logger.exception(
                "Unable to refresh finalized report snapshots after session %s",
                session.session_id,
            )

    # ── WebSocket Push ────────────────────────────────────────────────────
    def _push_measurement_event(self, session, parameter, result, value, voice_raw_text='', method='voice',
                                meas_type=None, meas_trial=None, meas_slot=None):
        group_name    = f"plant_{session.machine.plant_id}"
        operator_name = session.operator.display_name if session.operator else f"Operator #{session.operator_id}"
        _dispatch_async_websocket(
            group_name,
            {
                'type':              'inspection.event',
                'event':             'measurement_recorded',
                'session_id':        str(session.session_id),
                'parent_session_id': str(session.parent_session.session_id) if session.parent_session else '',
                'report_group_id':   str(session.report_group_id) if session.report_group_id else '',
                'machine_code':      session.machine.machine_code,
                'part_number':       session.part.part_number,
                'part_name':         session.part.part_name,
                'operator_id':       session.operator_id,
                'operator_name':     operator_name,
                'template_name':     session.template.name if session.template else '',
                'template_version':  session.template.version if session.template else 1,
                'parameter_code':    parameter.parameter_code,
                'parameter_name':    parameter.parameter_name,
                'nominal':           float(parameter.nominal_value),
                'lower_limit':       float(parameter.lower_limit),
                'upper_limit':       float(parameter.upper_limit),
                'unit':              parameter.unit,
                'measured_value':    value,
                'status':            result.status,
                'is_critical':       result.is_critical,
                'progress':          session.progress_percent,
                'voice_raw_text':    voice_raw_text,
                'method':             method,
                'shift':              session.shift,
                'trial_number':       meas_trial if meas_trial is not None else (session.trial_number or 1),
                'inspection_type':    meas_type if meas_type is not None else session.inspection_type,
                'hourly_slot':        meas_slot if meas_slot is not None else (session.hourly_unlocked_slot or 1),
            },
        )

    def _push_process_param_event(self, session, process_parameter, status_val, value, voice_raw_text='', method='voice',
                                  meas_type='first_piece', meas_trial=1, meas_slot=0):
        group_name    = f"plant_{session.machine.plant_id}"
        operator_name = session.operator.display_name if session.operator else f"Operator #{session.operator_id}"
        _dispatch_async_websocket(
            group_name,
            {
                'type':              'inspection.event',
                'event':             'measurement_recorded',
                'session_id':        str(session.session_id),
                'parent_session_id': str(session.parent_session.session_id) if session.parent_session else '',
                'report_group_id':   str(session.report_group_id) if session.report_group_id else '',
                'machine_code':      session.machine.machine_code,
                'part_number':       session.part.part_number,
                'part_name':         session.part.part_name,
                'operator_id':       session.operator_id,
                'operator_name':     operator_name,
                'template_name':     session.template.name if session.template else '',
                'template_version':  session.template.version if session.template else 1,
                'parameter_code':    process_parameter.parameter_code,
                'parameter_name':    process_parameter.parameter_name,
                'nominal':           float(process_parameter.nominal_value) if process_parameter.nominal_value is not None else None,
                'lower_limit':       float(process_parameter.lower_limit) if process_parameter.lower_limit is not None else None,
                'upper_limit':       float(process_parameter.upper_limit) if process_parameter.upper_limit is not None else None,
                'unit':              process_parameter.unit or '',
                'measured_value':    value,
                'status':            status_val,
                'is_critical':       False,
                'is_process_parameter': True,
                'progress':          session.progress_percent,
                'voice_raw_text':    voice_raw_text,
                'method':            method,
                'shift':             session.shift,
                'trial_number':      meas_trial,
                'inspection_type':   meas_type,
                'hourly_slot':       meas_slot,
            },
        )

    def _push_session_event(self, session, event_type: str):
        group_name    = f"plant_{session.machine.plant_id}"
        operator_name = session.operator.display_name if session.operator else f"Operator #{session.operator_id}"
        _dispatch_async_websocket(
            group_name,
            {
                'type':          'inspection.event',
                'event':         event_type,
                'session_id':    str(session.session_id),
                'machine_code':  session.machine.machine_code,
                'part_number':   session.part.part_number,
                'part_name':     session.part.part_name,
                'operator_id':   session.operator_id,
                'operator_name': operator_name,
                'status':        session.status,
                'has_ooc':       session.has_ooc,
                'trial_number':  session.trial_number,
                'shift':         session.shift,
                'inspection_type': session.inspection_type,
            },
        )

    def _push_rejection_alert(self, session, remark: str, rejected_parameters: list = None):
        group_name    = f"plant_{session.machine.plant_id}"
        next_trial    = min(session.trial_number + 1, 3)
        _dispatch_async_websocket(
            group_name,
            {
                'type':               'inspection.event',
                'event':              'rejection_alert',
                'session_id':         str(session.session_id),
                'trial_number':       session.trial_number,
                'next_trial_number':  next_trial,
                'machine_code':       session.machine.machine_code,
                'part_number':        session.part.part_number,
                'operator_id':        session.operator_id,
                'supervisor_remark':  remark,
                'rejected_parameters': rejected_parameters or [],
                'status':             session.status,
            },
        )

    # ── Supervisor 3rd Trial Override ─────────────────────────────────────
    def supervisor_override_measurement(
        self,
        session_id: str,
        parameter_code: str,
        override_value: float,
        supervisor,
        remark: str = '',
    ) -> dict:
        """Allows Supervisor direct override/correction for 1ST PC #3 (3rd Trial Chance)."""
        session = InspectionSession.objects.get(session_id=session_id)
        if session.trial_number != 3 and not session.supervisor_override_active:
            raise ValueError("Supervisor direct override is only permitted for 1ST PC #3 (3rd Trial Chance).")

        parameter = InspectionParameter.objects.filter(
            template__part=session.part,
            parameter_code=parameter_code,
            template__is_active=True,
        ).first()
        if not parameter:
            raise ValueError(f"Parameter '{parameter_code}' not found.")

        result = self.validator.validate(override_value, parameter)

        # Update parameter_summary in document_payload
        now = datetime.now(timezone.utc)
        doc_utils.update_parameter_summary(
            session,
            parameter_code=parameter_code,
            updates={
                'measured_value': override_value,
                'status': result.status,
                'override_by_supervisor': True,
                'supervisor_id': supervisor.id,
                'supervisor_remark': remark,
                'updated_at': now.isoformat(),
            },
            save=False
        )

        session.has_ooc = result.status == 'out_of_spec'
        session.supervisor_override_active = True
        session.save(update_fields=['document_payload', 'has_ooc', 'supervisor_override_active'])

        # Keep the permanent report aligned with supervisor corrections.
        self._safe_refresh_finalized_report_snapshots(session)

        self._push_session_event(session, 'supervisor_override')
        return {
            'status': 'success',
            'parameter_code': parameter_code,
            'measured_value': override_value,
            'result_status': result.status,
        }

    # ── Hourly Completion-Based Slot Management ───────────────────────────
    def get_hourly_status(self, session_id: str) -> dict:
        """
        Returns completion-based status for hourly slots.
        Slot 1 is always unlocked.
        Slot N unlocks as soon as Slot N-1 has been completed (has measurements).
        NO time lock — operator can proceed immediately after finishing previous slot.
        """
        session = InspectionSession.objects.select_related('machine__plant__factory').get(session_id=session_id)
        shift_hours = 8
        if session.machine and session.machine.plant and session.machine.plant.factory:
            shift_hours = session.machine.plant.factory.shift_hours or 8

        # Get all completed hourly slots from the session document
        doc = self.get_session_document(str(session_id)) or {}
        measurements = doc.get('measurements', [])
        completed_slots = set()
        for m in measurements:
            if m.get('inspection_type') == 'hourly':
                slot = m.get('hourly_slot')
                if slot:
                    try:
                        completed_slots.add(int(slot))
                    except Exception:
                        pass

        slots = []
        for i in range(1, shift_hours + 1):
            # Slot 1 always unlocked; slot N unlocks when N-1 is completed
            is_unlocked = (i == 1) or ((i - 1) in completed_slots)
            is_completed = i in completed_slots

            slots.append({
                'slot':          f"{i}/HR",
                'slot_number':   i,
                'is_unlocked':   is_unlocked,
                'is_completed':  is_completed,
                'is_overdue':    False,   # time-lock removed
                'unlock_minute': 0,       # kept for API compatibility
            })

        now = datetime.now(timezone.utc)
        start = session.shift_start_time or session.started_at
        elapsed_minutes = (now - start).total_seconds() / 60.0

        return {
            'session_id':      str(session.session_id),
            'shift_hours':     shift_hours,
            'total_slots':     shift_hours,
            'elapsed_minutes': round(elapsed_minutes, 1),
            'completed_slots': sorted(list(completed_slots)),
            'slots':           slots,
        }


# ─── Shared singleton ─────────────────────────────────────────────────────────
# M4 FIX: One InspectionService instance shared across the entire process.
# Previously views.py and tasks.py each created their own instance, resulting
# in duplicate MongoDB connection pools and split in-memory state.
# All modules must import this object instead of calling InspectionService().
inspection_service = InspectionService()
