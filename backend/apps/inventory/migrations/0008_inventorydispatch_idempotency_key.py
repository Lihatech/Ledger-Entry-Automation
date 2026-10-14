from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inventory', '0007_inventoryreceiptintake'),
    ]

    operations = [
        migrations.AddField(
            model_name='inventorydispatch',
            name='idempotency_key',
            field=models.CharField(blank=True, max_length=64, null=True, unique=True),
        ),
    ]
