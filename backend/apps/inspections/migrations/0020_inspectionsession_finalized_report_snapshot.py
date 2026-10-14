from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('inspections', '0019_setupapproval_shift'),
    ]

    operations = [
        migrations.AddField(
            model_name='inspectionsession',
            name='finalized_report_snapshot',
            field=models.JSONField(
                blank=True,
                default=dict,
                help_text='Immutable combined First Piece + hourly report snapshot captured for finalized reports so live-session cleanup cannot remove history.',
            ),
        ),
    ]
