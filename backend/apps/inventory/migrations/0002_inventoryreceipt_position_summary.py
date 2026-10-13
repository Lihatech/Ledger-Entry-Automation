from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('inventory', '0001_initial')]
    operations = [
        migrations.AddField(
            model_name='inventoryreceipt',
            name='position_summary',
            field=models.JSONField(blank=True, default=dict),
        ),
    ]
