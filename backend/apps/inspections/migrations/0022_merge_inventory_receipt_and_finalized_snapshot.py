from django.db import migrations


class Migration(migrations.Migration):
    """Join the two migration branches introduced on the release branch.

    The finalized-report snapshot and inventory-receipt changes are independent
    schema changes.  This no-op migration gives Django one leaf so deployments
    can run migrations normally.
    """

    dependencies = [
        ('inspections', '0020_inspectionsession_finalized_report_snapshot'),
        ('inspections', '0021_dailyproductionreport_idempotency_key'),
    ]

    operations = []
