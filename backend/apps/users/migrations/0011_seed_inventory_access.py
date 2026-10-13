from django.db import migrations


def seed_inventory_access(apps, schema_editor):
    AccessRole = apps.get_model('users', 'AccessRole')
    for role in AccessRole.objects.filter(slug__in=('admin', 'supervisor')):
        permissions = set(role.permissions or ())
        permissions.update({'inventory.view', 'inventory.manage'})
        role.permissions = sorted(permissions)
        role.save(update_fields=['permissions'])


class Migration(migrations.Migration):
    dependencies = [('users', '0010_seed_editable_common_access')]
    operations = [migrations.RunPython(seed_inventory_access, migrations.RunPython.noop)]
