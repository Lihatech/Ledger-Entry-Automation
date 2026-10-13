from django.conf import settings
from django.db import migrations, models
import django.core.validators
import django.db.models.deletion


class Migration(migrations.Migration):
    initial = True
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]
    operations = [
        migrations.CreateModel(
            name='InventoryReceipt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('company_name', models.CharField(max_length=150)),
                ('challan_number', models.CharField(max_length=80)),
                ('part_name', models.CharField(max_length=150)),
                ('received_quantity', models.PositiveIntegerField(validators=[django.core.validators.MinValueValidator(1)])),
                ('vehicle_number', models.CharField(blank=True, default='', max_length=40)),
                ('machine_sequence', models.CharField(blank=True, default='', max_length=500)),
                ('not_started_quantity', models.PositiveIntegerField(default=0)),
                ('in_process_quantity', models.PositiveIntegerField(default=0)),
                ('completed_quantity', models.PositiveIntegerField(default=0)),
                ('rework_quantity', models.PositiveIntegerField(default=0)),
                ('rejected_quantity', models.PositiveIntegerField(default=0)),
                ('dispatched_quantity', models.PositiveIntegerField(default=0)),
                ('last_reconciled_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('created_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='inventory_receipts', to=settings.AUTH_USER_MODEL)),
            ],
            options={'db_table': 'inventory_receipts', 'ordering': ['-created_at']},
        ),
        migrations.AddConstraint(
            model_name='inventoryreceipt',
            constraint=models.UniqueConstraint(fields=('company_name', 'challan_number'), name='inventory_company_challan_unique'),
        ),
    ]
