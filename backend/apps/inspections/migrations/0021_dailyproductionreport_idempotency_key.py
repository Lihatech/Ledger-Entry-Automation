from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inspections', '0020_dailyproductionreport_inventory_receipt'),
    ]

    operations = [
        migrations.AddField(
            model_name='dailyproductionreport',
            name='idempotency_key',
            field=models.CharField(blank=True, max_length=64, null=True, unique=True),
        ),
    ]
