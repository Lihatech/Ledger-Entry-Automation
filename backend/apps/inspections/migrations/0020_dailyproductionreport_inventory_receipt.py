from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0019_setupapproval_shift'),
        ('inventory', '0002_inventoryreceipt_position_summary'),
    ]

    operations = [
        migrations.AddField(
            model_name='dailyproductionreport',
            name='inventory_receipt',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='production_reports', to='inventory.inventoryreceipt'),
        ),
    ]
