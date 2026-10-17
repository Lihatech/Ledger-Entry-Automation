from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.inventory.models import InventoryReceipt
from apps.machines.models import Machine, Plant
from apps.messaging.models import Conversation
from apps.users.models import User


class Command(BaseCommand):
    help = (
        'Assign legacy records with no plant to one existing plant. '
        'Dry-runs unless --apply is supplied.'
    )

    def add_arguments(self, parser):
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument('--plant-id', type=int)
        group.add_argument('--plant-code')
        group.add_argument('--plant-name')
        parser.add_argument(
            '--apply',
            action='store_true',
            help='Persist the backfill. Without this flag, only a report is produced.',
        )

    def _get_target(self, options):
        if options.get('plant_id') is not None:
            target = Plant.objects.filter(pk=options['plant_id']).first()
        elif options.get('plant_code'):
            target = Plant.objects.filter(code__iexact=options['plant_code']).first()
        else:
            matches = Plant.objects.filter(name__iexact=options['plant_name'])
            if matches.count() > 1:
                raise CommandError(
                    'More than one plant has that name; use --plant-id or --plant-code.'
                )
            target = matches.first()
        if target is None:
            raise CommandError('Target plant was not found.')
        return target

    def handle(self, *args, **options):
        target = self._get_target(options)

        machines = Machine.objects.filter(plant__isnull=True)
        users = User.objects.filter(plant__isnull=True)
        conversations = Conversation.objects.filter(plant__isnull=True)
        receipts = InventoryReceipt.objects.filter(plant__isnull=True)

        existing_receipt_keys = set(
            InventoryReceipt.objects.filter(plant=target).values_list(
                'company_name', 'challan_number'
            )
        )
        legacy_receipt_keys = {}
        collisions = []
        for receipt in receipts.order_by('pk'):
            key = (receipt.company_name, receipt.challan_number)
            if key in existing_receipt_keys or key in legacy_receipt_keys:
                collisions.append(f'{receipt.pk}:{receipt.company_name}/{receipt.challan_number}')
            else:
                legacy_receipt_keys[key] = receipt.pk

        self.stdout.write(f'Target plant: {target.name} ({target.code}, id={target.pk})')
        self.stdout.write(f'Machines without plant: {machines.count()}')
        self.stdout.write(f'Users without plant: {users.count()}')
        self.stdout.write(f'Conversations without plant: {conversations.count()}')
        self.stdout.write(f'Inventory receipts without plant: {receipts.count()}')

        if collisions:
            raise CommandError(
                'Migration stopped: inventory uniqueness collisions detected: '
                + ', '.join(collisions)
            )

        if not options['apply']:
            self.stdout.write(self.style.WARNING('Dry run only; no records were changed.'))
            return

        with transaction.atomic():
            machines.update(plant=target)
            users.update(plant=target)
            conversations.update(plant=target)
            receipts.update(plant=target)

        self.stdout.write(self.style.SUCCESS('Legacy plant backfill completed successfully.'))
