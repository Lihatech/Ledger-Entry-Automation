from django.db import migrations


def link_unambiguous_reports(apps, schema_editor):
    """Backfill submitted reports only where one inventory row is unambiguous."""
    DailyProductionReport = apps.get_model('inspections', 'DailyProductionReport')
    InventoryReceipt = apps.get_model('inventory', 'InventoryReceipt')

    linked_receipt_ids = set()
    skipped_reports = 0
    reports = DailyProductionReport.objects.filter(
        status='SUBMITTED', inventory_receipt__isnull=True
    ).select_related('machine', 'part')

    for report in reports:
        if not report.machine_id or not report.part_id or not report.machine.plant_id:
            skipped_reports += 1
            continue

        candidates = []
        for receipt in InventoryReceipt.objects.filter(
            plant_id=report.machine.plant_id,
            part_name__iexact=report.part.part_name.strip(),
            received_quantity__gt=0,
        ).exclude(received_quantity__lte=0).order_by('created_at', 'id'):
            if receipt.dispatched_quantity >= receipt.received_quantity:
                continue
            steps = receipt.machine_sequence_steps or []
            matches_route = not steps or any(
                isinstance(step, dict)
                and str(step.get('machine_id')) == str(report.machine_id)
                and (step.get('operation') or '').strip().casefold()
                == (report.operation or '').strip().casefold()
                for step in steps
            )
            if matches_route:
                candidates.append(receipt)

        if len(candidates) != 1:
            skipped_reports += 1
            continue

        report.inventory_receipt_id = candidates[0].pk
        report.save(update_fields=['inventory_receipt'])
        linked_receipt_ids.add(candidates[0].pk)

    # Use the current reconciliation service after the historical links have
    # been saved, so the inventory cards reflect the backfilled reports.
    from apps.inventory.models import InventoryReceipt as CurrentInventoryReceipt
    from apps.inventory.services import reconcile_receipt_from_reports

    for receipt in CurrentInventoryReceipt.objects.filter(pk__in=linked_receipt_ids):
        reconcile_receipt_from_reports(receipt)

    print(
        'Daily report inventory backfill completed: '
        f'{len(linked_receipt_ids)} receipt(s) reconciled; '
        f'{skipped_reports} ambiguous or incomplete report(s) left unchanged.'
    )


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0023_merge_20261014_1432'),
        ('inventory', '0011_consolidate_existing_records_to_kandalgaon'),
    ]

    operations = [
        migrations.RunPython(link_unambiguous_reports, migrations.RunPython.noop),
    ]
