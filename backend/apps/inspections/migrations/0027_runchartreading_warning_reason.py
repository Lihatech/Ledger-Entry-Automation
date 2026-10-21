from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0026_run_chart_reading_idempotency'),
    ]

    operations = [
        migrations.AddField(
            model_name='runchartreading',
            name='warning_reason',
            field=models.TextField(blank=True, default=''),
        ),
    ]
