import uuid

from django.db import migrations, models


def share_operation_keys_for_named_templates(apps, schema_editor):
    InspectionTemplate = apps.get_model('parts', 'InspectionTemplate')

    named_templates = InspectionTemplate.objects.exclude(name='').order_by('part_id', 'id')
    keys_by_operation = {}
    for template in named_templates:
        operation_name = (template.name or '').strip().casefold()
        key = (template.part_id, operation_name)
        if key not in keys_by_operation:
            keys_by_operation[key] = template.operation_key
        if template.operation_key != keys_by_operation[key]:
            InspectionTemplate.objects.filter(pk=template.pk).update(
                operation_key=keys_by_operation[key]
            )


class Migration(migrations.Migration):

    dependencies = [
        ('parts', '0014_controlplandocument_approval_comments_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='inspectiontemplate',
            name='operation_key',
            field=models.UUIDField(db_index=True, default=uuid.uuid4, editable=False),
        ),
        migrations.RunPython(share_operation_keys_for_named_templates, migrations.RunPython.noop),
    ]
