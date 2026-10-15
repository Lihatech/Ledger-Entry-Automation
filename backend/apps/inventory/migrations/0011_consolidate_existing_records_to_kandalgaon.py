from django.db import migrations


TARGET_PLANT_CODE = 'KANDALGAON-1'
TARGET_PLANT_NAME = 'kandalgaon'


def consolidate_to_kandalgaon(apps, schema_editor):
    """Move legacy plant-scoped records into the plant selected by the admin."""
    Plant = apps.get_model('machines', 'Plant')
    Machine = apps.get_model('machines', 'Machine')
    User = apps.get_model('users', 'User')
    InventoryReceipt = apps.get_model('inventory', 'InventoryReceipt')
    Conversation = apps.get_model('messaging', 'Conversation')

    target = (
        Plant.objects.filter(code__iexact=TARGET_PLANT_CODE).first()
        or Plant.objects.filter(name__iexact=TARGET_PLANT_NAME).first()
    )
    if target is None:
        print('Plant consolidation skipped: kandalgaon was not found.')
        return

    target_id = target.pk
    machines_moved = Machine.objects.exclude(plant_id=target_id).update(plant_id=target_id)
    users_moved = User.objects.exclude(plant_id=target_id).update(plant_id=target_id)
    conversations_moved = Conversation.objects.exclude(plant_id=target_id).update(plant_id=target_id)

    # A receipt is unique within a plant by company and challan. Do not merge
    # records with the same key: leave any collision in its source plant so no
    # stock quantity or audit trail is lost.
    occupied_receipt_keys = set(
        InventoryReceipt.objects.filter(plant_id=target_id).values_list(
            'company_name', 'challan_number'
        )
    )
    receipt_ids = []
    skipped_receipts = 0
    for receipt in InventoryReceipt.objects.exclude(plant_id=target_id).order_by('id'):
        key = (receipt.company_name, receipt.challan_number)
        if key in occupied_receipt_keys:
            skipped_receipts += 1
            continue
        receipt_ids.append(receipt.pk)
        occupied_receipt_keys.add(key)

    receipts_moved = InventoryReceipt.objects.filter(pk__in=receipt_ids).update(plant_id=target_id)
    print(
        'Plant consolidation to kandalgaon completed: '
        f'{machines_moved} machines, {users_moved} users, '
        f'{receipts_moved} inventory receipts, and {conversations_moved} conversations moved; '
        f'{skipped_receipts} receipt collisions left unchanged.'
    )


class Migration(migrations.Migration):
    dependencies = [
        ('inventory', '0010_inventoryreceipt_plant_company_challan_unique'),
        ('machines', '0010_factory_shift_1_start_factory_shift_2_start_and_more'),
        ('messaging', '0006_conversation_past_participants'),
        ('users', '0011_seed_inventory_access'),
    ]

    operations = [
        migrations.RunPython(consolidate_to_kandalgaon, migrations.RunPython.noop),
    ]
