from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('inventory', '0009_inventoryreceiptintake_idempotency_key')]

    operations = [
        migrations.RemoveConstraint(model_name='inventoryreceipt', name='inventory_company_challan_unique'),
        migrations.AddConstraint(
            model_name='inventoryreceipt',
            constraint=models.UniqueConstraint(
                fields=('plant', 'company_name', 'challan_number'),
                name='inventory_plant_company_challan_unique',
            ),
        ),
    ]
