from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone

from apps.machines.models import Plant


class InventoryReceipt(models.Model):
    """A client job-work receipt and its shift-reconciled quantity snapshot."""

    company_name = models.CharField(max_length=150)
    # Internal production location. Nullable only for legacy receipts created
    # before plant ownership was introduced; new API receipts must set it.
    plant = models.ForeignKey(
        Plant,
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name='inventory_receipts',
    )
    challan_number = models.CharField(max_length=80)
    part_name = models.CharField(max_length=150)
    received_quantity = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    vehicle_number = models.CharField(max_length=40, blank=True, default='')
    machine_sequence = models.CharField(max_length=500, blank=True, default='')
    machine_sequence_steps = models.JSONField(default=list, blank=True)

    # These are updated from submitted Daily Production Reports.
    not_started_quantity = models.PositiveIntegerField(default=0)
    in_process_quantity = models.PositiveIntegerField(default=0)
    completed_quantity = models.PositiveIntegerField(default=0)
    rework_quantity = models.PositiveIntegerField(default=0)
    rejected_quantity = models.PositiveIntegerField(default=0)
    dispatched_quantity = models.PositiveIntegerField(default=0)
    last_dispatched_at = models.DateTimeField(null=True, blank=True)
    last_dispatched_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='inventory_dispatches',
    )
    position_summary = models.JSONField(default=dict, blank=True)
    last_reconciled_at = models.DateTimeField(null=True, blank=True)

    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='inventory_receipts',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'inventory_receipts'
        ordering = ['-created_at']
        constraints = [
            models.UniqueConstraint(
                fields=['plant', 'company_name', 'challan_number'],
                name='inventory_plant_company_challan_unique',
            ),
        ]

    def save(self, *args, **kwargs):
        if self.machine_sequence_steps:
            if (
                not isinstance(self.machine_sequence_steps, list)
                or any(not isinstance(step, dict) for step in self.machine_sequence_steps)
            ):
                raise ValidationError({
                    'machine_sequence_steps': 'Each machine sequence step must be an object.'
                })
            if any(not str(step.get('operation') or '').strip() for step in self.machine_sequence_steps):
                raise ValidationError({
                    'machine_sequence_steps': 'Each machine sequence step must include an operation.'
                })
            self.machine_sequence = ' → '.join(
                f"{step.get('machine_code') or step.get('machine_name') or 'Machine'} / {step.get('operation') or 'Operation'}"
                for step in self.machine_sequence_steps
            )
        elif self.machine_sequence_steps == []:
            self.machine_sequence = ''
        if self._state.adding and not self.not_started_quantity:
            self.not_started_quantity = self.received_quantity
        super().save(*args, **kwargs)

    @property
    def current_quantity(self):
        return max(
            self.received_quantity - self.dispatched_quantity,
            0,
        )

    @property
    def reconciled(self):
        return bool(self.last_reconciled_at)

    def reconcile(self, *, completed=0, started=None, rework=0, rejected=0, dispatched=0, positions=None):
        self.completed_quantity = max(0, int(completed))
        self.rework_quantity = max(0, int(rework))
        self.rejected_quantity = max(0, int(rejected))
        self.dispatched_quantity = max(0, int(dispatched))
        # ``started`` is the number of physical units touched by production.
        # Route positions are a diagnostic breakdown and must not be summed
        # into the summary card: the same units can appear at different route
        # stages as they move through the process.
        if started is None:
            started = self.received_quantity
        started = min(max(int(started), 0), self.received_quantity)
        self.in_process_quantity = max(started - self.completed_quantity, 0)
        self.not_started_quantity = max(
            self.received_quantity - started,
            0,
        )
        if positions is not None:
            self.position_summary = positions
        self.last_reconciled_at = timezone.now()


class InventoryDispatch(models.Model):
    receipt = models.ForeignKey(InventoryReceipt, on_delete=models.CASCADE, related_name='dispatch_events')
    quantity = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    idempotency_key = models.CharField(max_length=64, unique=True, null=True, blank=True)
    dispatched_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, related_name='inventory_dispatch_events')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'inventory_dispatch_events'
        ordering = ['-created_at']


class InventoryReceiptIntake(models.Model):
    """An additional physical arrival recorded against an existing receipt."""

    receipt = models.ForeignKey(
        InventoryReceipt,
        on_delete=models.CASCADE,
        related_name='intake_events',
    )
    quantity = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    idempotency_key = models.CharField(max_length=64, unique=True, null=True, blank=True)
    received_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        related_name='inventory_intake_events',
    )
    vehicle_number = models.CharField(max_length=40, blank=True, default='')
    notes = models.TextField(blank=True, default='')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'inventory_receipt_intake_events'
        ordering = ['-created_at']
