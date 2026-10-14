from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('inventory', '0008_inventorydispatch_idempotency_key'),
    ]

    operations = [
        migrations.AddField(
            model_name='inventoryreceiptintake',
            name='idempotency_key',
            field=models.CharField(blank=True, max_length=64, null=True, unique=True),
        ),
    ]
