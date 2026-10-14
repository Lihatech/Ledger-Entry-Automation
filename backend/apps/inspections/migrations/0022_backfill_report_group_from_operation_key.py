from django.db import migrations


def backfill_report_groups(apps, schema_editor):
    InspectionSession = apps.get_model('inspections', 'InspectionSession')

    for session in InspectionSession.objects.filter(
        report_group_id__isnull=True,
        inspection_type__in=['first_piece', 'hourly'],
    ).select_related('template'):
        operation_key = getattr(session.template, 'operation_key', None)
        if operation_key:
            InspectionSession.objects.filter(pk=session.pk).update(
                report_group_id=operation_key,
            )


class Migration(migrations.Migration):

    dependencies = [
        ('parts', '0015_inspectiontemplate_operation_key'),
        ('inspections', '0021_inspectionsession_report_group_id'),
    ]

    operations = [
        migrations.RunPython(backfill_report_groups, migrations.RunPython.noop),
    ]
