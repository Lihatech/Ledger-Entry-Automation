"""
InspectionSession : PostgreSQL model that stores both the relational index
fields AND the full inspection document payload (measurements, parameter
summaries, etc.) in a JSONB column.  MongoDB is no longer required.
"""

import uuid
from django.conf import settings
from django.db import models


class InspectionSession(models.Model):
    """
    PostgreSQL record: primary source of truth for all inspection data.
    The `document_payload` JSONB column holds the full measurements array,
    parameter summaries, and process parameter entries that formerly lived
    in the MongoDB inspection_records collection.
    """

    class Status(models.TextChoices):
        IN_PROGRESS      = 'in_progress',      'In Progress'
        PENDING_REVIEW   = 'pending_review',   'Pending Review'
        APPROVED         = 'approved',         'Approved'
        REJECTED         = 'rejected',         'Rejected'
        FINALIZED_PASSED = 'finalized_passed', 'Finalized (Passed)'
        FINALIZED_FAILED = 'finalized_failed', 'Finalized (Failed)'
        COMPLETED        = 'completed',        'Completed'

    class Shift(models.TextChoices):
        I   = 'I',   'Shift I'
        II  = 'II',  'Shift II'
        III = 'III', 'Shift III'
        A   = 'A',   'Shift A'
        B   = 'B',   'Shift B'
        C   = 'C',   'Shift C'

    # Unique identifier : same ID used as MongoDB document _id reference (unique implies db_index)
    session_id = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)

    # Relations
    part    = models.ForeignKey('parts.Part',    on_delete=models.PROTECT, related_name='sessions')
    machine = models.ForeignKey('machines.Machine', on_delete=models.PROTECT, related_name='sessions')
    operator   = models.ForeignKey(
        'users.User', on_delete=models.PROTECT, related_name='operated_sessions'
    )
    supervisor = models.ForeignKey(
        'users.User', on_delete=models.SET_NULL, null=True, blank=True,
        related_name='supervised_sessions',
    )
    finalized_by = models.ForeignKey(
        'users.User', on_delete=models.SET_NULL, null=True, blank=True,
        related_name='finalized_sessions',
    )
    template = models.ForeignKey(
        'parts.InspectionTemplate', on_delete=models.SET_NULL,
        null=True, blank=True, related_name='sessions',
    )

    # Session metadata
    inspection_type            = models.CharField(max_length=20, db_index=True)  # first_piece / hourly / final
    shift                      = models.CharField(max_length=5, choices=Shift.choices, default=Shift.I, db_index=True)
    status                     = models.CharField(max_length=25, choices=Status.choices, default=Status.IN_PROGRESS, db_index=True)
    trial_number               = models.IntegerField(default=1)   # 1 for 1st PC #1, 2 for 1st PC #2, 3 for 1st PC #3
    parent_session             = models.ForeignKey('self', on_delete=models.SET_NULL, null=True, blank=True, related_name='child_trials')
    rejection_reason           = models.TextField(blank=True)
    hourly_unlocked_slot       = models.IntegerField(default=0)   # 0 = setup, 1..8 for 1/HR..8/HR
    shift_start_time           = models.DateTimeField(null=True, blank=True)
    supervisor_override_active = models.BooleanField(default=False)
    is_setup_approved          = models.BooleanField(default=False)
    is_first_piece_finalized   = models.BooleanField(default=False)
    finalized_at               = models.DateTimeField(null=True, blank=True)
    pdf_report_path            = models.CharField(max_length=500, blank=True, null=True)

    # Quick flags (avoid expensive MongoDB lookups for dashboards)
    total_parameters  = models.PositiveIntegerField(default=0)
    recorded_count    = models.PositiveIntegerField(default=0)
    has_ooc           = models.BooleanField(default=False)  # out-of-spec flag
    has_critical_fail = models.BooleanField(default=False)

    # Timestamps & Reminder tracking
    started_at          = models.DateTimeField(auto_now_add=True, db_index=True)
    last_measurement_at = models.DateTimeField(null=True, blank=True)
    completed_at        = models.DateTimeField(null=True, blank=True)
    reviewed_at         = models.DateTimeField(null=True, blank=True)
    supervisor_remark   = models.TextField(blank=True)

    # Reminder & Escalation flags
    operator_reminded       = models.BooleanField(default=False)
    operator_reminded_at    = models.DateTimeField(null=True, blank=True)
    supervisor_escalated    = models.BooleanField(default=False)
    supervisor_escalated_at = models.DateTimeField(null=True, blank=True)

    # Full inspection document (replaces MongoDB inspection_records document).
    # Stores: measurements[], parameter_summary[], process_parameter_summary[],
    # process_param_entries[], and any other semi-structured per-session data.
    # PostgreSQL persists this as JSONB : indexed, queryable, no external DB needed.
    document_payload = models.JSONField(
        default=dict,
        help_text=(
            "Full inspection document: measurements[], parameter_summary[], "
            "process_parameter_summary[], process_param_entries[], etc. "
            "Replaces the MongoDB inspection_records document."
        ),
    )

    def clean(self):
        from django.core.exceptions import ValidationError
        super().clean()
        if self.inspection_type == 'first_piece' and self.trial_number > 3:
            raise ValidationError("First Piece Inspection is limited to a maximum of 3 attempts (1st PC #1, #2, #3).")

    class Meta:
        db_table = 'inspection_sessions'
        ordering = ['-started_at']

    def __str__(self):
        return f"Session {self.session_id} | {self.part.part_number} | {self.status}"

    @property
    def is_complete(self):
        return self.recorded_count >= self.total_parameters

    @property
    def progress_percent(self):
        if self.total_parameters == 0:
            return 0
        return round((self.recorded_count / self.total_parameters) * 100)


class DailyProductionReport(models.Model):
    """
    Dedicated model for End-of-Day Daily Production Reports.
    Completely separate from inspection session records.
    """
    report_id = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    date = models.DateField(db_index=True)
    machine = models.ForeignKey('machines.Machine', on_delete=models.PROTECT, related_name='production_reports')
    part = models.ForeignKey('parts.Part', on_delete=models.PROTECT, related_name='production_reports')
    operation = models.CharField(max_length=100, blank=True, default='')
    shift = models.CharField(max_length=20, default='I', db_index=True)
    operator = models.ForeignKey('users.User', on_delete=models.PROTECT, related_name='production_reports')

    production_target = models.PositiveIntegerField(default=0)
    jobs_completed = models.PositiveIntegerField(default=0)
    correct_jobs = models.PositiveIntegerField(default=0)
    incorrect_jobs = models.PositiveIntegerField(default=0)

    cr_count = models.PositiveIntegerField(default=0)  # Customer Rejection / CR Quantity
    mr_count = models.PositiveIntegerField(default=0)  # Machine Rejection / MR Quantity
    rw_count = models.PositiveIntegerField(default=0)  # Rework / RW Quantity

    remarks = models.TextField(blank=True, default='')
    achievement_percentage = models.FloatField(default=0.0)

    class Status(models.TextChoices):
        DRAFT = 'DRAFT', 'Draft'
        SUBMITTED = 'SUBMITTED', 'Submitted'

    status = models.CharField(max_length=20, choices=Status.choices, default=Status.SUBMITTED, db_index=True)

    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'daily_production_reports'
        ordering = ['-date', '-created_at']

    def save(self, *args, **kwargs):
        # Auto-calculate target from available time and cycle time
        available_time = 420
        if self.machine and self.machine.plant:
            plant = self.machine.plant
            if getattr(plant, 'factory', None) and plant.factory.shift_hours:
                fac = plant.factory
                available_time = (fac.shift_hours * 60) - (fac.lunch_break_minutes + fac.tea_break_minutes)
            elif plant.shift_duration_hours:
                available_time = (plant.shift_duration_hours * 60) - (plant.total_break_mins or 0)
        
        if available_time <= 0:
            available_time = 420
        
        from apps.parts.models import InspectionTemplate
        template = InspectionTemplate.objects.filter(
            part=self.part, name=self.operation
        ).first()
        if not template:
            template = InspectionTemplate.objects.filter(part=self.part).first()
        
        if template and getattr(template, 'cycle_time_mins', 0) > 0:
            self.production_target = int(available_time / template.cycle_time_mins)
        else:
            self.production_target = int(available_time / 10.0)

        if self.production_target > 0:
            self.achievement_percentage = round((self.jobs_completed / self.production_target) * 100, 2)
        else:
            self.achievement_percentage = 0.0
        super().save(*args, **kwargs)

        # Immediately ensure linked DowntimeReport is created and updated
        if self.status == self.Status.SUBMITTED:
            downtime_report, _ = DowntimeReport.objects.get_or_create(production_report=self)
            downtime_report.save()

    def __str__(self):
        return f"Daily Production Report {self.date} | {self.machine.machine_code} | {self.operator.username}"


class DowntimeReport(models.Model):
    """
    Downtime Report attached strictly 1-to-1 to a DailyProductionReport.
    Stores supervisor downtime entries (in minutes).
    """
    class Status(models.TextChoices):
        PENDING = 'PENDING', 'Pending'
        COMPLETED = 'COMPLETED', 'Completed'

    report_id = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    production_report = models.OneToOneField(
        DailyProductionReport,
        on_delete=models.CASCADE,
        related_name='downtime_report'
    )

    # Downtime fields in MINUTES
    no_load = models.PositiveIntegerField(default=0)
    no_operator = models.PositiveIntegerField(default=0)
    um = models.PositiveIntegerField(default=0)
    setting = models.PositiveIntegerField(default=0)
    inspection_wait = models.PositiveIntegerField(default=0)
    tool_change = models.PositiveIntegerField(default=0)
    power_off = models.PositiveIntegerField(default=0)
    rework = models.PositiveIntegerField(default=0)
    tool_problem = models.PositiveIntegerField(default=0)

    total_downtime = models.PositiveIntegerField(default=0)
    expected_downtime = models.PositiveIntegerField(default=0, help_text="Mathematically expected downtime")
    remarks = models.TextField(blank=True, default='')
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PENDING, db_index=True)

    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_downtime_reports'
    )

    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = 'downtime_reports'
        ordering = ['-created_at']

    def clean(self):
        from django.core.exceptions import ValidationError
        downtime_fields = [
            self.no_load, self.no_operator, self.um, self.setting,
            self.inspection_wait, self.tool_change, self.power_off,
            self.rework, self.tool_problem
        ]
        for val in downtime_fields:
            if val is not None and val < 0:
                raise ValidationError("Downtime values must be non-negative integers.")

    def save(self, *args, **kwargs):
        # L5 FIX: Removed self.full_clean() here. Validation should be handled by 
        # the serializer or forms before save() is called.
        
        # Calculate expected downtime (Total Down Time)
        prod = self.production_report
        target = prod.production_target
        produced = prod.jobs_completed
        cycle_time = 0.0
        
        from apps.parts.models import InspectionTemplate
        template = InspectionTemplate.objects.filter(
            part=prod.part, name=prod.operation
        ).first()
        if not template:
            template = InspectionTemplate.objects.filter(part=prod.part).first()
        if template and getattr(template, 'cycle_time_mins', 0) > 0:
            cycle_time = template.cycle_time_mins
        else:
            cycle_time = 10.0
        
        self.expected_downtime = max(0, int((target - produced) * cycle_time))

        self.total_downtime = (
            (self.no_load or 0) +
            (self.no_operator or 0) +
            (self.um or 0) +
            (self.setting or 0) +
            (self.inspection_wait or 0) +
            (self.tool_change or 0) +
            (self.power_off or 0) +
            (self.rework or 0) +
            (self.tool_problem or 0)
        )
        if self.status == self.Status.COMPLETED and not self.completed_at:
            from django.utils import timezone
            self.completed_at = timezone.now()
        super().save(*args, **kwargs)

    def __str__(self):
        return f"Downtime Report | ProdRef: {self.production_report_id} | Total: {self.total_downtime} min"


class JHChecklistVersion(models.Model):
    """
    Audit log and version snapshot of every checklist upload/change.
    Can be scoped per machine or null for the factory default template.
    """
    machine = models.ForeignKey(
        'machines.Machine',
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name='jh_checklist_versions',
        db_index=True,
        help_text='Machine this checklist version belongs to. Null = factory default template.'
    )
    version_number = models.IntegerField(db_index=True)
    filename = models.CharField(max_length=255, blank=True, default='')
    uploaded_by = models.ForeignKey('users.User', on_delete=models.SET_NULL, null=True, blank=True, related_name='checklist_uploads')
    uploaded_at = models.DateTimeField(auto_now_add=True)
    total_items = models.IntegerField(default=0)
    notes = models.TextField(blank=True, default='')
    is_active = models.BooleanField(default=True)

    class Meta:
        db_table = 'jh_checklist_versions'
        ordering = ['-version_number']
        constraints = [
            models.UniqueConstraint(
                fields=['machine', 'version_number'],
                name='unique_machine_version'
            ),
            models.UniqueConstraint(
                fields=['version_number'],
                condition=models.Q(machine__isnull=True),
                name='unique_default_version'
            )
        ]

    def __str__(self):
        m_str = self.machine.machine_code if self.machine else 'Default'
        return f"Checklist Version v{self.version_number} [{m_str}] ({self.total_items} items) - {self.filename}"



class JHChecklistItem(models.Model):
    """
    Master Autonomous Maintenance (Jishu Hozen) checklist items.
    Can be bound to a specific machine or null for factory default template.
    Pre-seeded with standardized assembly checkpoints.
    """
    class ToolType(models.TextChoices):
        VISUAL = 'VISUAL', 'Visual (Eye)'
        TOUCH = 'TOUCH', 'Touch (Hand)'
        TOOL = 'TOOL', 'Tool / Wrench (Spanner)'

    machine = models.ForeignKey(
        'machines.Machine',
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name='jh_checklist_items',
        db_index=True,
        help_text='Machine this checkpoint belongs to. Null = factory default template.'
    )
    version = models.ForeignKey(JHChecklistVersion, on_delete=models.CASCADE, related_name='items', null=True, blank=True)
    sub_no = models.CharField(max_length=20, db_index=True)  # e.g. "1.1", "2.1"
    assembly = models.CharField(max_length=100, db_index=True)  # e.g. "1. Machine Front Side", "2. FIXTURE"
    sub_assembly = models.CharField(max_length=100, blank=True, default='')  # e.g. "एफ एम एफ बोर्ड", "फिक्सचर"
    check_point = models.TextField()  # e.g. "एफ एम एफ बोर्ड साफ करो"
    standard = models.TextField()  # e.g. "धुल और तेल से मुक्त"
    tool_type = models.CharField(max_length=20, choices=ToolType.choices, default=ToolType.VISUAL)
    rank = models.CharField(max_length=10, blank=True, default='D')  # e.g. 'A', 'B', 'D'
    frequency = models.CharField(max_length=10, default='D')  # Daily
    action_clean = models.BooleanField(default=False)
    action_lubricate = models.BooleanField(default=False)
    action_inspect = models.BooleanField(default=True)
    action_retighten = models.BooleanField(default=False)
    timing_sec = models.CharField(max_length=50, default='5 DPT')  # e.g. "5 DPT", "60 DPT"
    sort_order = models.IntegerField(default=0)
    is_active = models.BooleanField(default=True)

    class Meta:
        db_table = 'jh_checklist_items'
        ordering = ['sort_order', 'sub_no']

    def __str__(self):
        m_str = f"[{self.machine.machine_code}] " if self.machine else "[Default] "
        return f"{m_str}{self.sub_no} - {self.assembly} - {self.check_point[:30]}"


class JHInspectionRecord(models.Model):
    """
    Per-shift Autonomous Maintenance inspection submission by an operator.
    Stored in PostgreSQL.
    """
    class Shift(models.TextChoices):
        I = 'I', 'Shift I'
        II = 'II', 'Shift II'
        III = 'III', 'Shift III'

    class Status(models.TextChoices):
        ALL_OK = 'ALL_OK', 'All OK'
        HAS_ISSUES = 'HAS_ISSUES', 'Has Issues'
        CORRECTED = 'CORRECTED', 'Issues Corrected'

    record_id = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    machine = models.ForeignKey('machines.Machine', on_delete=models.PROTECT, related_name='jh_inspections')
    operator = models.ForeignKey('users.User', on_delete=models.PROTECT, related_name='jh_inspections')
    date = models.DateField(db_index=True)
    shift = models.CharField(max_length=10, choices=Shift.choices, default=Shift.I, db_index=True)
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.ALL_OK, db_index=True)
    total_items = models.IntegerField(default=0)
    ok_items = models.IntegerField(default=0)
    not_ok_items = models.IntegerField(default=0)
    corrected_items = models.IntegerField(default=0)
    overall_remarks = models.TextField(blank=True, default='')
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'jh_inspection_records'
        ordering = ['-date', '-created_at']
        unique_together = ('machine', 'date', 'shift')

    def __str__(self):
        return f"JH Audit {self.date} Shift {self.shift} | {self.machine.machine_code} | {self.status}"


class JHInspectionItemResult(models.Model):
    """
    Individual evaluation result for a checklist item in a shift inspection.
    """
    class ItemStatus(models.TextChoices):
        OK = 'OK', 'OK'
        NOT_OK = 'NOT_OK', 'Not OK'
        CORRECTED = 'CORRECTED', 'Not OK Correction Done'

    inspection = models.ForeignKey(JHInspectionRecord, on_delete=models.CASCADE, related_name='item_results')
    item = models.ForeignKey(JHChecklistItem, on_delete=models.PROTECT, related_name='inspection_results')
    status = models.CharField(max_length=20, choices=ItemStatus.choices, default=ItemStatus.OK)
    remark = models.CharField(max_length=255, blank=True, default='')
    action_taken = models.CharField(max_length=255, blank=True, default='')

    class Meta:
        db_table = 'jh_inspection_item_results'
        unique_together = ('inspection', 'item')

    def __str__(self):
        return f"{self.inspection.date} Shift {self.inspection.shift} - Item {self.item.sub_no}: {self.status}"


class SetupApproval(models.Model):
    """
    Replaces MongoDB documents with inspection_type='setup_approval'.

    Setup approval documents are architecturally separate from InspectionSession
    (normal first-piece / hourly / final inspections).  They record the
    inspector's process-parameter trial readings that must be approved before
    a production run begins.
    """

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    template = models.ForeignKey(
        'parts.InspectionTemplate',
        on_delete=models.CASCADE,
        related_name='setup_approvals',
    )
    machine = models.ForeignKey(
        'machines.Machine',
        on_delete=models.CASCADE,
        related_name='setup_approvals',
    )
    part_number    = models.CharField(max_length=100, blank=True)
    inspector      = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='setup_approvals',
    )
    inspector_name = models.CharField(max_length=255, blank=True)

    # List of {parameter_code, parameter_name, trial_1, trial_2, trial_3, …}
    process_param_entries = models.JSONField(default=list)

    status       = models.CharField(max_length=50, default='submitted')
    submitted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'inspection_setup_approvals'
        ordering = ['-submitted_at']
        indexes = [
            models.Index(fields=['template', 'machine', 'submitted_at']),
        ]

    def __str__(self):
        return (
            f"SetupApproval | template={self.template_id} "
            f"machine={self.machine_id} | {self.submitted_at:%Y-%m-%d}"
        )

