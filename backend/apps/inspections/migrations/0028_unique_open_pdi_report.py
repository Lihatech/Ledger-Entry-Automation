from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0027_pdireport_pdireading'),
    ]

    operations = [
        migrations.AddConstraint(
            model_name='pdireport',
            constraint=models.UniqueConstraint(
                condition=models.Q(('status__in', ['draft', 'in_progress'])),
                fields=('machine', 'template', 'report_date', 'shift', 'created_by'),
                name='unique_open_pdi_report_per_creator',
            ),
        ),
    ]
