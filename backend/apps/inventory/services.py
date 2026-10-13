from collections import defaultdict

from django.db.models import Sum


def reconcile_receipt_from_reports(receipt):
    """Rebuild receipt quantities from submitted end-of-shift reports."""
    reports = receipt.production_reports.filter(status='SUBMITTED').select_related('machine')
    good_by_machine = defaultdict(int)
    good_by_step = defaultdict(int)
    steps = receipt.machine_sequence_steps or []
    for report in reports:
        code = report.machine.machine_code
        good_by_machine[code] += report.correct_jobs or 0
        good_by_step[(code, (report.operation or '').strip())] += report.correct_jobs or 0

    stages = [item.strip() for item in receipt.machine_sequence.split('->') if item.strip()]
    if steps:
        stages = [f"{step.get('machine_code') or step.get('machine_name') or 'Machine'} / {step.get('operation') or 'Operation'}" for step in steps]
    positions = {}
    previous_good = receipt.received_quantity
    for index, stage in enumerate(stages):
        if steps:
            step = steps[index]
            machine_code = step.get('machine_code') or step.get('machine_name') or ''
            operation = (step.get('operation') or '').strip()
            good = min(good_by_step.get((machine_code, operation), 0), previous_good)
        else:
            machine_code = stage.split(' ', 1)[0]
            good = min(good_by_machine.get(machine_code, 0), previous_good)
        positions[stage] = max(previous_good - good, 0)
        previous_good = good

    totals = reports.aggregate(
        rework=Sum('rw_count'),
        customer_reject=Sum('cr_count'),
        machine_reject=Sum('mr_count'),
    )
    rework = totals['rework'] or 0
    rejected = (totals['customer_reject'] or 0) + (totals['machine_reject'] or 0)
    completed = previous_good if stages else sum(good_by_machine.values())
    receipt.reconcile(
        completed=completed,
        rework=rework,
        rejected=rejected,
        dispatched=receipt.dispatched_quantity,
        positions=positions,
    )
    receipt.save(update_fields=[
        'not_started_quantity', 'in_process_quantity', 'completed_quantity',
        'rework_quantity', 'rejected_quantity', 'position_summary',
        'last_reconciled_at', 'updated_at',
    ])
