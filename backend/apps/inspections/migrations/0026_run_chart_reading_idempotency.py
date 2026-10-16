from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0025_backfill_finalized_report_snapshots'),
        ('inspections', '0025_runchartreport_runchartreading'),
    ]

    operations = [
        migrations.AddField(
            model_name='runchartreading',
            name='idempotency_key',
            field=models.CharField(blank=True, max_length=64, null=True),
        ),
        migrations.AddConstraint(
            model_name='runchartreading',
            constraint=models.UniqueConstraint(
                condition=models.Q(idempotency_key__isnull=False),
                fields=('report', 'idempotency_key'),
                name='unique_run_chart_idempotency_key',
            ),
        ),
    ]
