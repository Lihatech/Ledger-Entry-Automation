import uuid

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('inspections', '0026_run_chart_reading_idempotency'),
        ('machines', '0001_initial'),
        ('parts', '0015_inspectiontemplate_operation_key'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='PDIReport',
            fields=[
                ('report_id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('report_number', models.CharField(db_index=True, max_length=40, unique=True)),
                ('report_date', models.DateField(db_index=True)),
                ('shift', models.CharField(db_index=True, default='I', max_length=10)),
                ('customer_name', models.CharField(blank=True, default='', max_length=200)),
                ('invoice_number', models.CharField(blank=True, default='', max_length=100)),
                ('supplied_quantity', models.PositiveIntegerField(default=0)),
                ('remarks', models.TextField(blank=True, default='')),
                ('status', models.CharField(choices=[('draft', 'Draft'), ('in_progress', 'In Progress'), ('ready_for_review', 'Ready for Review'), ('submitted', 'Submitted'), ('approved', 'Approved'), ('rejected', 'Rejected')], db_index=True, default='draft', max_length=20)),
                ('overall_judgement', models.CharField(choices=[('pass', 'Pass'), ('fail', 'Fail'), ('incomplete', 'Incomplete')], default='incomplete', max_length=20)),
                ('parameter_snapshot', models.JSONField(blank=True, default=list)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('submitted_at', models.DateTimeField(blank=True, null=True)),
                ('reviewed_at', models.DateTimeField(blank=True, null=True)),
                ('approved_at', models.DateTimeField(blank=True, null=True)),
                ('approved_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='approved_pdi_reports', to=settings.AUTH_USER_MODEL)),
                ('created_by', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='created_pdi_reports', to=settings.AUTH_USER_MODEL)),
                ('machine', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='pdi_reports', to='machines.machine')),
                ('part', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='pdi_reports', to='parts.part')),
                ('reviewed_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='reviewed_pdi_reports', to=settings.AUTH_USER_MODEL)),
                ('submitted_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='submitted_pdi_reports', to=settings.AUTH_USER_MODEL)),
                ('template', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='pdi_reports', to='parts.inspectiontemplate')),
            ],
            options={'db_table': 'pdi_reports', 'ordering': ['-report_date', '-created_at']},
        ),
        migrations.CreateModel(
            name='PDIReading',
            fields=[
                ('reading_id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('sample_number', models.PositiveSmallIntegerField()),
                ('parameter_code', models.CharField(max_length=30)),
                ('parameter_name', models.CharField(max_length=150)),
                ('unit', models.CharField(blank=True, default='', max_length=30)),
                ('specification', models.CharField(blank=True, default='', max_length=200)),
                ('inspection_method', models.CharField(blank=True, default='', max_length=200)),
                ('lower_limit', models.DecimalField(blank=True, decimal_places=6, max_digits=14, null=True)),
                ('upper_limit', models.DecimalField(blank=True, decimal_places=6, max_digits=14, null=True)),
                ('value_text', models.CharField(blank=True, default='', max_length=200)),
                ('numeric_value', models.DecimalField(blank=True, decimal_places=6, max_digits=14, null=True)),
                ('judgement', models.CharField(blank=True, choices=[('pass', 'Pass'), ('fail', 'Fail'), ('na', 'Not Applicable')], default='', max_length=10)),
                ('remarks', models.TextField(blank=True, default='')),
                ('entered_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('entered_by', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='pdi_readings_entered', to=settings.AUTH_USER_MODEL)),
                ('parameter', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='pdi_readings', to='parts.inspectionparameter')),
                ('report', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='readings', to='inspections.pdireport')),
            ],
            options={'db_table': 'pdi_readings', 'ordering': ['parameter_code', 'sample_number']},
        ),
        migrations.AddConstraint(
            model_name='pdireading',
            constraint=models.UniqueConstraint(fields=('report', 'parameter', 'sample_number'), name='unique_pdi_parameter_sample'),
        ),
    ]
