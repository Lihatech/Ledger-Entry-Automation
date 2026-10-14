from rest_framework import serializers
from .models import (
    InspectionSession,
    DailyProductionReport,
    DowntimeReport,
    JHChecklistItem,
    JHInspectionRecord,
    JHInspectionItemResult,
)


class StartInspectionSerializer(serializers.Serializer):
    part_number       = serializers.CharField()
    machine_id        = serializers.IntegerField()
    template_id       = serializers.IntegerField(required=False)
    inspection_type   = serializers.CharField(required=False, default='first_piece')
    shift             = serializers.ChoiceField(choices=['A', 'B', 'C', 'I', 'II', 'III'], default='A')
    trial_number      = serializers.IntegerField(required=False, default=1)
    hourly_slot       = serializers.IntegerField(required=False, default=1)
    parent_session_id = serializers.CharField(required=False, allow_null=True, allow_blank=True)


class RecordMeasurementSerializer(serializers.Serializer):
    parameter_code  = serializers.CharField()
    measured_value  = serializers.FloatField(required=False, allow_null=True)
    voice_raw_text  = serializers.CharField(required=False, allow_blank=True, default='')
    method          = serializers.CharField(required=False, default='voice')
    hourly_slot     = serializers.IntegerField(required=False, allow_null=True, default=None)
    inspection_type = serializers.CharField(required=False, allow_null=True, allow_blank=True, default=None)
    idempotency_key = serializers.CharField(required=False, allow_null=True, allow_blank=True, default=None)

    def validate(self, attrs):
        raw_text = attrs.get('voice_raw_text', '')
        meas_val = attrs.get('measured_value')
        if raw_text and meas_val is not None:
            from .services import parse_visual_text
            text_ans = parse_visual_text(raw_text)
            if text_ans is False and float(meas_val) >= 0.5:
                raise serializers.ValidationError(
                    {"measured_value": "Contradictory measurement: text indicates negative (NO/FAIL) but numeric value is >= 0.5."}
                )
            if text_ans is True and float(meas_val) == 0.0:
                raise serializers.ValidationError(
                    {"measured_value": "Contradictory measurement: text indicates affirmative (YES/PASS) but numeric value is 0.0."}
                )
        return attrs


class SingleMeasurementSerializer(serializers.Serializer):
    """One field entry within a batch-measure submission."""
    parameter_code  = serializers.CharField()
    measured_value  = serializers.FloatField(required=False, allow_null=True)
    voice_raw_text  = serializers.CharField(required=False, allow_blank=True, default='')
    method          = serializers.CharField(required=False, default='form')
    hourly_slot     = serializers.IntegerField(required=False, allow_null=True, default=None)
    inspection_type = serializers.CharField(required=False, allow_null=True, allow_blank=True, default=None)
    trial_number    = serializers.IntegerField(required=False, allow_null=True, default=None)

    def validate(self, attrs):
        raw_text = attrs.get('voice_raw_text', '')
        meas_val = attrs.get('measured_value')
        if raw_text and meas_val is not None:
            from .services import parse_visual_text
            text_ans = parse_visual_text(raw_text)
            if text_ans is False and float(meas_val) >= 0.5:
                raise serializers.ValidationError(
                    {"measured_value": "Contradictory measurement: text indicates negative (NO/FAIL) but numeric value is >= 0.5."}
                )
            if text_ans is True and float(meas_val) == 0.0:
                raise serializers.ValidationError(
                    {"measured_value": "Contradictory measurement: text indicates affirmative (YES/PASS) but numeric value is 0.0."}
                )
        return attrs


class BatchMeasureSerializer(serializers.Serializer):
    """
    Accepts all measurements for one physical piece in a single POST.

    The inspector fills every parameter on the form screen and taps
    'Submit Piece' : this serializer validates the entire payload before
    the view hands it off to InspectionService for field-level validation.
    """
    measurements = SingleMeasurementSerializer(many=True)


class ReviewSerializer(serializers.Serializer):
    action              = serializers.ChoiceField(choices=['approve', 'reject'])
    remark              = serializers.CharField(required=False, allow_blank=True, default='')
    rejected_parameters = serializers.ListField(
        child=serializers.CharField(),
        required=False,
        default=list,
    )


class InspectionSessionSerializer(serializers.ModelSerializer):
    part_number  = serializers.CharField(source='part.part_number', read_only=True)
    part_name    = serializers.CharField(source='part.part_name', read_only=True)
    machine_code = serializers.CharField(source='machine.machine_code', read_only=True)
    operator_name   = serializers.SerializerMethodField()
    supervisor_name = serializers.SerializerMethodField()
    inspector_name  = serializers.SerializerMethodField()
    template_id     = serializers.SerializerMethodField()
    template_name   = serializers.SerializerMethodField()
    template_version = serializers.SerializerMethodField()
    progress_percent = serializers.IntegerField(read_only=True)
    hourly_slot     = serializers.IntegerField(source='hourly_unlocked_slot', read_only=True)
    shift_duration_hours = serializers.IntegerField(source='machine.plant.shift_duration_hours', read_only=True)
    total_break_mins = serializers.IntegerField(source='machine.plant.total_break_mins', read_only=True)
    shift_hours = serializers.SerializerMethodField()
    total_hourly_slots = serializers.SerializerMethodField()
    rejected_parameters = serializers.SerializerMethodField()

    class Meta:
        model  = InspectionSession
        fields = [
            'session_id', 'part_number', 'part_name', 'machine_code',
            'operator_name', 'supervisor_name', 'inspector_name',
            'template_id', 'template_name', 'template_version',
            'inspection_type', 'shift', 'status', 'shift_hours', 'total_hourly_slots', 'shift_duration_hours', 'total_break_mins',
            'trial_number', 'hourly_unlocked_slot', 'hourly_slot', 'parent_session', 'rejection_reason',
            'total_parameters', 'recorded_count', 'progress_percent',
            'has_ooc', 'has_critical_fail', 'is_setup_approved', 'is_first_piece_finalized',
            'started_at', 'completed_at', 'reviewed_at', 'finalized_at',
            'supervisor_remark', 'rejected_parameters',
        ]

    def get_shift_hours(self, obj):
        if obj.machine and obj.machine.plant and obj.machine.plant.factory:
            return obj.machine.plant.factory.shift_hours or 8
        return 8

    def get_total_hourly_slots(self, obj):
        return self.get_shift_hours(obj)

    def get_operator_name(self, obj):
        if obj.operator:
            name = obj.operator.get_full_name().strip()
            return name if name else obj.operator.username
        return '-'

    def get_supervisor_name(self, obj):
        if obj.supervisor:
            name = obj.supervisor.get_full_name().strip()
            return name if name else obj.supervisor.username
        return '-'

    def get_template_id(self, obj):
        if obj.template_id:
            return obj.template_id
        return getattr(obj, 'template_id', None)

    def get_template_name(self, obj):
        # Use prefetched template
        if obj.template and obj.template.name and obj.template.name.strip():
            return obj.template.name.strip()
        return None

    def get_template_version(self, obj):
        if obj.template:
            return obj.template.version
        return getattr(obj, 'template_version', None)

    def get_inspector_name(self, obj):
        if obj.finalized_by:
            name = obj.finalized_by.get_full_name().strip()
            return name if name else obj.finalized_by.username
        elif obj.supervisor:
            name = obj.supervisor.get_full_name().strip()
            return name if name else obj.supervisor.username
        return 'Inspector'

    def get_rejected_parameters(self, obj):
        # Read directly from document_payload JSONB : no extra DB query
        try:
            doc = obj.document_payload or {}
            rej = doc.get('rejected_parameters', [])
            if rej:
                return rej
            measurements = doc.get('measurements', [])
            if measurements:
                latest_trial = max(m.get('trial_number', 1) for m in measurements)
                return list(set([
                    m['parameter_code'] for m in measurements
                    if m.get('trial_number', 1) == latest_trial and m.get('status') == 'out_of_spec'
                ]))
        except Exception:
            pass
        return []


class DailyProductionReportSerializer(serializers.ModelSerializer):
    machine_code = serializers.CharField(source='machine.machine_code', read_only=True)
    machine_name = serializers.CharField(source='machine.name', read_only=True)
    part_number  = serializers.CharField(source='part.part_number', read_only=True)
    part_name    = serializers.CharField(source='part.part_name', read_only=True)
    operator_name = serializers.SerializerMethodField()

    class Meta:
        model = DailyProductionReport
        fields = [
            'id', 'report_id', 'idempotency_key', 'date', 'machine', 'machine_code', 'machine_name',
            'part', 'part_number', 'part_name', 'operation', 'shift',
            'inventory_receipt',
            'operator', 'operator_name',
            'production_target', 'jobs_completed', 'correct_jobs', 'incorrect_jobs',
            'cr_count', 'mr_count', 'rw_count', 'remarks',
            'achievement_percentage', 'created_at', 'updated_at'
        ]
        read_only_fields = ['id', 'report_id', 'achievement_percentage', 'created_at', 'updated_at']
        extra_kwargs = {'operator': {'required': False, 'allow_null': True}}

    def get_operator_name(self, obj):
        if obj.operator:
            name = obj.operator.get_full_name().strip()
            return name if name else obj.operator.username
        return '-'

    def validate(self, attrs):
        if 'idempotency_key' in attrs and not attrs.get('idempotency_key'):
            attrs['idempotency_key'] = None
        receipt = attrs.get('inventory_receipt') or getattr(self.instance, 'inventory_receipt', None)
        machine = attrs.get('machine') or getattr(self.instance, 'machine', None)
        part = attrs.get('part') or getattr(self.instance, 'part', None)
        operation = (attrs.get('operation', getattr(self.instance, 'operation', '')) or '').strip()
        request_user = getattr(self.context.get('request'), 'user', None)
        if receipt and machine and part:
            if receipt.plant_id and machine.plant_id != receipt.plant_id:
                raise serializers.ValidationError({'inventory_receipt': 'The receipt belongs to a different plant.'})
            if getattr(request_user, 'plant_id', None) and receipt.plant_id != request_user.plant_id:
                raise serializers.ValidationError({'inventory_receipt': 'The receipt is outside your assigned plant.'})
            receipt_part = (receipt.part_name or '').strip().casefold()
            if receipt_part not in {part.part_name.strip().casefold(), part.part_number.strip().casefold()}:
                raise serializers.ValidationError({'inventory_receipt': 'The receipt part does not match this production report.'})
            steps = receipt.machine_sequence_steps or []
            if steps:
                matches_route = any(
                    str(step.get('machine_id')) == str(machine.id)
                    and (step.get('operation') or '').strip().casefold() == operation.casefold()
                    for step in steps if isinstance(step, dict)
                )
                if not matches_route:
                    raise serializers.ValidationError({'inventory_receipt': 'The report machine and operation are not in the receipt route.'})
        jobs_completed = attrs.get('jobs_completed', 0)
        correct_jobs = attrs.get('correct_jobs', 0)
        incorrect_jobs = attrs.get('incorrect_jobs', 0)
        cr_count = attrs.get('cr_count', 0)
        mr_count = attrs.get('mr_count', 0)
        rw_count = attrs.get('rw_count', 0)

        # Validation Rule 1: Jobs Completed = Correct Jobs + Incorrect Jobs
        if jobs_completed != (correct_jobs + incorrect_jobs):
            raise serializers.ValidationError({
                "jobs_completed": f"Jobs Completed ({jobs_completed}) must equal Correct Jobs ({correct_jobs}) + Incorrect Jobs ({incorrect_jobs})."
            })

        # Validation Rule 2: Incorrect Jobs = CR + MR + RW
        if incorrect_jobs != (cr_count + mr_count + rw_count):
            raise serializers.ValidationError({
                "incorrect_jobs": f"Incorrect Jobs ({incorrect_jobs}) must equal CR ({cr_count}) + MR ({mr_count}) + RW ({rw_count})."
            })

        return attrs


class DowntimeReportSerializer(serializers.ModelSerializer):
    production_report_id = serializers.IntegerField(source='production_report.id', read_only=True)
    date = serializers.DateField(source='production_report.date', read_only=True)
    shift = serializers.CharField(source='production_report.shift', read_only=True)
    machine = serializers.CharField(source='production_report.machine.machine_code', read_only=True)
    machine_code = serializers.CharField(source='production_report.machine.machine_code', read_only=True)
    machine_name = serializers.CharField(source='production_report.machine.name', read_only=True)
    operator = serializers.SerializerMethodField()
    operator_name = serializers.SerializerMethodField()
    target = serializers.IntegerField(source='production_report.production_target', read_only=True)
    produced = serializers.IntegerField(source='production_report.jobs_completed', read_only=True)
    accepted_actual = serializers.IntegerField(source='production_report.correct_jobs', read_only=True)
    cr = serializers.IntegerField(source='production_report.cr_count', read_only=True)
    mr = serializers.IntegerField(source='production_report.mr_count', read_only=True)
    rw = serializers.IntegerField(source='production_report.rw_count', read_only=True)
    cycle_time_mins = serializers.SerializerMethodField()

    class Meta:
        model = DowntimeReport
        fields = [
            'id', 'report_id', 'production_report', 'production_report_id',
            'date', 'shift', 'machine', 'machine_code', 'machine_name',
            'operator', 'operator_name',
            'target', 'produced', 'accepted_actual', 'cr', 'mr', 'rw',
            'no_load', 'no_operator', 'um', 'setting', 'inspection_wait',
            'tool_change', 'power_off', 'rework', 'tool_problem',
            'total_downtime', 'expected_downtime', 'remarks', 'status', 'cycle_time_mins',
            'created_by', 'created_at', 'updated_at', 'completed_at'
        ]
        read_only_fields = [
            'id', 'report_id', 'total_downtime', 'created_at', 'updated_at', 'completed_at'
        ]

    def get_operator(self, obj):
        if obj.production_report and obj.production_report.operator:
            name = obj.production_report.operator.get_full_name().strip()
            return name if name else obj.production_report.operator.username
        return '-'

    def get_operator_name(self, obj):
        return self.get_operator(obj)

    def get_cycle_time_mins(self, obj):
        from apps.parts.models import InspectionTemplate
        prod = obj.production_report
        if not prod or not prod.part:
            return 0.0
        template = InspectionTemplate.objects.filter(
            part=prod.part,
            name=prod.operation
        ).first()
        if not template:
            template = InspectionTemplate.objects.filter(
                part=prod.part
            ).first()
        if template and template.cycle_time_mins and float(template.cycle_time_mins) > 0:
            return float(template.cycle_time_mins)
        return 10.0

    def validate(self, attrs):
        fields = [
            'no_load', 'no_operator', 'um', 'setting',
            'inspection_wait', 'tool_change', 'power_off',
            'rework', 'tool_problem'
        ]
        for field in fields:
            val = attrs.get(field)
            if val is not None:
                if not isinstance(val, int) or val < 0:
                    raise serializers.ValidationError({
                        field: f"{field} must be a non-negative integer."
                    })
        return attrs
 
 
class JHChecklistItemSerializer(serializers.ModelSerializer):
    tool_type_display = serializers.CharField(source='get_tool_type_display', read_only=True)

    class Meta:
        model = JHChecklistItem
        fields = [
            'id', 'sub_no', 'assembly', 'sub_assembly', 'check_point',
            'standard', 'tool_type', 'tool_type_display', 'rank', 'frequency',
            'action_clean', 'action_lubricate', 'action_inspect', 'action_retighten',
            'timing_sec', 'sort_order', 'is_active',
        ]


class JHInspectionItemResultSerializer(serializers.ModelSerializer):
    item_details = JHChecklistItemSerializer(source='item', read_only=True)
    sub_no = serializers.CharField(source='item.sub_no', read_only=True)
    check_point = serializers.CharField(source='item.check_point', read_only=True)
    standard = serializers.CharField(source='item.standard', read_only=True)
    tool_type = serializers.CharField(source='item.tool_type', read_only=True)

    class Meta:
        model = JHInspectionItemResult
        fields = [
            'id', 'item', 'item_details', 'sub_no', 'check_point', 'standard',
            'tool_type', 'status', 'remark', 'action_taken'
        ]


class JHInspectionRecordSerializer(serializers.ModelSerializer):
    item_results = JHInspectionItemResultSerializer(many=True, read_only=True)
    machine_code = serializers.CharField(source='machine.machine_code', read_only=True)
    machine_name = serializers.CharField(source='machine.name', read_only=True)
    operator_name = serializers.SerializerMethodField()

    class Meta:
        model = JHInspectionRecord
        fields = [
            'id', 'record_id', 'machine', 'machine_code', 'machine_name',
            'operator', 'operator_name', 'date', 'shift', 'status',
            'total_items', 'ok_items', 'not_ok_items', 'corrected_items',
            'overall_remarks', 'created_at', 'updated_at', 'item_results'
        ]

    def get_operator_name(self, obj):
        if obj.operator:
            name = obj.operator.get_full_name().strip()
            return name if name else obj.operator.username
        return '-'


class JHSubmitItemResultInputSerializer(serializers.Serializer):
    item_id = serializers.IntegerField()
    status = serializers.ChoiceField(choices=['OK', 'NOT_OK', 'CORRECTED'])
    remark = serializers.CharField(required=False, allow_blank=True, default='')
    action_taken = serializers.CharField(required=False, allow_blank=True, default='')


class JHInspectionSubmitSerializer(serializers.Serializer):
    machine_id = serializers.IntegerField()
    date = serializers.DateField()
    shift = serializers.ChoiceField(choices=['I', 'II', 'III'])
    overall_remarks = serializers.CharField(required=False, allow_blank=True, default='')
    results = JHSubmitItemResultInputSerializer(many=True)



