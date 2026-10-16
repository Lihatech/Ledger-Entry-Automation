from copy import deepcopy

from django.db import migrations
from django.db.models import Q


PROTECTED_STATUSES = {
    'approved',
    'finalized_passed',
    'finalized_failed',
    'completed',
}


def _payload(session):
    value = session.document_payload
    return deepcopy(value) if isinstance(value, dict) else {}


def _scope_sessions(InspectionSession, session):
    """Return the historical sessions belonging to one combined report."""
    base = InspectionSession.objects.filter(
        machine_id=session.machine_id,
        part_id=session.part_id,
        inspection_type__in=('first_piece', 'hourly'),
    )

    if session.report_group_id:
        return base.filter(report_group_id=session.report_group_id).order_by(
            'inspection_type', 'trial_number', 'hourly_unlocked_slot', 'started_at', 'pk'
        )

    # Older records may not have report_group_id. Keep the fallback narrow so
    # unrelated reports from another shift/date are not merged together.
    fallback = base.filter(shift=session.shift)
    if session.started_at:
        fallback = fallback.filter(started_at__date=session.started_at.date())
    if session.template_id:
        fallback = fallback.filter(template_id=session.template_id)
    else:
        operation_name = (_payload(session).get('operation_name') or '').strip()
        if operation_name:
            fallback = fallback.filter(
                document_payload__operation_name__iexact=operation_name,
            )
    return fallback.order_by(
        'inspection_type', 'trial_number', 'hourly_unlocked_slot', 'started_at', 'pk'
    )


def _measurement_key(measurement, inspection_type, trial_number, hourly_slot):
    code = measurement.get('parameter_code')
    if not code:
        return None
    column = trial_number if inspection_type == 'first_piece' else hourly_slot
    return code, inspection_type, column


def backfill_finalized_report_snapshots(apps, schema_editor):
    InspectionSession = apps.get_model('inspections', 'InspectionSession')

    candidates = InspectionSession.objects.filter(
        inspection_type='first_piece',
    ).filter(
        Q(is_first_piece_finalized=True) | Q(status__in=PROTECTED_STATUSES)
    ).order_by('pk')
    created = 0
    skipped = 0

    for finalized_session in candidates:
        # Idempotent: never alter a snapshot that was already captured.
        if finalized_session.finalized_report_snapshot:
            skipped += 1
            continue

        sessions = list(_scope_sessions(InspectionSession, finalized_session))
        measurements = {}
        snapshot = _payload(finalized_session)

        for source in sessions:
            source_payload = _payload(source)
            source_type = source.inspection_type
            trial_number = source.trial_number or source_payload.get('trial_number') or 1
            hourly_slot = source.hourly_unlocked_slot or source_payload.get('hourly_slot') or 1

            for raw_measurement in source_payload.get('measurements', []):
                if not isinstance(raw_measurement, dict):
                    continue
                measurement = deepcopy(raw_measurement)
                key = _measurement_key(
                    measurement,
                    source_type,
                    trial_number,
                    hourly_slot,
                )
                if key is None:
                    continue

                measurement['inspection_type'] = source_type
                measurement['trial_number'] = trial_number if source_type == 'first_piece' else 0
                measurement['hourly_slot'] = hourly_slot if source_type == 'hourly' else 0
                measurements[key] = measurement

        # A snapshot without measurements would make a legacy report appear
        # finalized while still being empty, so leave it for manual review.
        if not measurements:
            skipped += 1
            continue

        snapshot['measurements'] = list(measurements.values())
        snapshot['session_id'] = str(finalized_session.session_id)
        snapshot['inspection_type'] = 'first_piece'
        snapshot['trial_number'] = finalized_session.trial_number or 1
        snapshot['report_group_id'] = (
            str(finalized_session.report_group_id)
            if finalized_session.report_group_id else None
        )
        snapshot['finalized_report_snapshot_version'] = 1

        InspectionSession.objects.filter(pk=finalized_session.pk).update(
            finalized_report_snapshot=snapshot,
        )
        created += 1

    print(
        'Finalized report snapshot backfill completed: '
        f'{created} snapshot(s) created; {skipped} record(s) skipped.'
    )


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0024_link_unambiguous_reports_to_inventory'),
    ]

    operations = [
        migrations.RunPython(backfill_finalized_report_snapshots, migrations.RunPython.noop),
    ]
