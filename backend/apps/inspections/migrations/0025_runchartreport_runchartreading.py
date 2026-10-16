import uuid

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('inspections', '0024_link_unambiguous_reports_to_inventory'),
        ('machines', '0001_initial'),
        ('parts', '0015_inspectiontemplate_operation_key'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='RunChartReport',
            fields=[
                ('report_id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('report_date', models.DateField(db_index=True)),
                ('shift', models.CharField(db_index=True, default='I', max_length=10)),
                ('status', models.CharField(choices=[('active', 'Active'), ('closed', 'Closed')], db_index=True, default='active', max_length=10)),
                ('parameter_code', models.CharField(max_length=30)),
                ('parameter_name', models.CharField(max_length=150)),
                ('unit', models.CharField(max_length=20)),
                ('nominal_value', models.DecimalField(decimal_places=4, max_digits=12)),
                ('lower_limit', models.DecimalField(decimal_places=4, max_digits=12)),
                ('upper_limit', models.DecimalField(decimal_places=4, max_digits=12)),
                ('started_at', models.DateTimeField(auto_now_add=True)),
                ('closed_at', models.DateTimeField(blank=True, null=True)),
                ('machine', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_reports', to='machines.machine')),
                ('operator', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_reports', to=settings.AUTH_USER_MODEL)),
                ('parameter', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_reports', to='parts.inspectionparameter')),
                ('part', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_reports', to='parts.part')),
                ('template', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_reports', to='parts.inspectiontemplate')),
            ],
            options={
                'db_table': 'run_chart_reports',
                'ordering': ['-started_at'],
            },
        ),
        migrations.CreateModel(
            name='RunChartReading',
            fields=[
                ('reading_id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('piece_number', models.PositiveIntegerField()),
                ('measured_value', models.DecimalField(decimal_places=6, max_digits=14)),
                ('deviation', models.DecimalField(decimal_places=6, max_digits=14)),
                ('zone', models.CharField(choices=[('green', 'Green'), ('yellow', 'Yellow'), ('red', 'Red')], db_index=True, max_length=10)),
                ('recorded_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('recorded_by', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='run_chart_readings', to=settings.AUTH_USER_MODEL)),
                ('report', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='readings', to='inspections.runchartreport')),
            ],
            options={
                'db_table': 'run_chart_readings',
                'ordering': ['piece_number'],
            },
        ),
        migrations.AddConstraint(
            model_name='runchartreport',
            constraint=models.UniqueConstraint(fields=('machine', 'template', 'parameter', 'report_date', 'shift'), name='unique_run_chart_per_shift'),
        ),
        migrations.AddConstraint(
            model_name='runchartreading',
            constraint=models.UniqueConstraint(fields=('report', 'piece_number'), name='unique_piece_per_run_chart'),
        ),
    ]
