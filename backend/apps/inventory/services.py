from collections import defaultdict
import re

from django.db import transaction
from django.db.models import Sum


def reconcile_receipt_from_reports(receipt):
    """Rebuild receipt quantities from submitted end-of-shift reports."""
    from .models import InventoryReceipt

    # Always reload the receipt while holding a row lock. A second report
    # submission waits here, then reads the newest committed report set rather
    # than overwriting it with an older calculation.
    with transaction.atomic():
        locked_receipt = InventoryReceipt.objects.select_for_update().get(pk=receipt.pk)
        reports = locked_receipt.production_reports.filter(status='SUBMITTED').select_related('machine')
        good_by_machine = defaultdict(int)
        good_by_step_id = defaultdict(int)
        good_by_step_code = defaultdict(int)
        steps = locked_receipt.machine_sequence_steps or []
        for report in reports:
            code = report.machine.machine_code
            good_by_machine[code] += report.correct_jobs or 0
            operation = (report.operation or '').strip()
            good_by_step_id[(report.machine_id, operation)] += report.correct_jobs or 0
            good_by_step_code[(code, operation)] += report.correct_jobs or 0

        stages = [
            item.strip()
            for item in re.split(r'\s*(?:->|→)\s*', locked_receipt.machine_sequence or '')
            if item.strip()
        ]
        if steps:
            stages = [f"{step.get('machine_code') or step.get('machine_name') or 'Machine'} / {step.get('operation') or 'Operation'}" for step in steps]
        # Keep duplicate labels separate. A route may intentionally visit the
        # same machine/operation more than once, and a JSON object cannot hold
        # two values under the same label.
        label_counts = defaultdict(int)
        for stage in stages:
            label_counts[stage] += 1
        positions = {}
        previous_good = locked_receipt.received_quantity
        for index, stage in enumerate(stages):
            if steps:
                step = steps[index]
                machine_code = step.get('machine_code') or step.get('machine_name') or ''
                operation = (step.get('operation') or '').strip()
                machine_id = step.get('machine_id')
                if machine_id:
                    matched_good = good_by_step_id.get((machine_id, operation), 0)
                else:
                    matched_good = good_by_step_code.get((machine_code, operation), 0)
                good = min(matched_good, previous_good)
            else:
                machine_code = stage.split(' ', 1)[0]
                good = min(good_by_machine.get(machine_code, 0), previous_good)
            position_key = stage
            if label_counts[stage] > 1:
                position_key = f"Step {index + 1}: {stage}"
            positions[position_key] = max(previous_good - good, 0)
            previous_good = good

        totals = reports.aggregate(
            rework=Sum('rw_count'),
            customer_reject=Sum('cr_count'),
            machine_reject=Sum('mr_count'),
        )
        rework = totals['rework'] or 0
        rejected = (totals['customer_reject'] or 0) + (totals['machine_reject'] or 0)
        # Legacy receipts may not have a route. Even then, report totals must
        # never manufacture more completed parts than physically received.
        completed = previous_good if stages else min(
            sum(good_by_machine.values()), locked_receipt.received_quantity,
        )
        locked_receipt.reconcile(
            completed=completed,
            rework=rework,
            rejected=rejected,
            dispatched=locked_receipt.dispatched_quantity,
            positions=positions,
        )
        locked_receipt.save(update_fields=[
            'not_started_quantity', 'in_process_quantity', 'completed_quantity',
            'rework_quantity', 'rejected_quantity', 'position_summary',
            'last_reconciled_at', 'updated_at',
        ])
        return locked_receipt
