from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('inspections', '0020_inspectionsession_finalized_report_snapshot'),
    ]

    operations = [
        migrations.AddField(
            model_name='inspectionsession',
            name='report_group_id',
            field=models.UUIDField(blank=True, db_index=True, null=True),
        ),
    ]
