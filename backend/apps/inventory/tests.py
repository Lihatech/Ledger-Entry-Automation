from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from datetime import date
from django.test import TestCase
from rest_framework.test import APITestCase

from apps.inspections.models import DailyProductionReport
from apps.machines.models import Factory, Machine, Plant
from apps.parts.models import Part
from .models import InventoryReceipt


class InventoryReceiptTests(TestCase):
    def test_new_receipt_starts_with_all_quantity_not_started(self):
        user = get_user_model().objects.create_user(username='inventory-test', password='test-pass')
        receipt = InventoryReceipt.objects.create(
            company_name='Acme Engineering',
            challan_number='CH-001',
            part_name='Shaft 25 mm',
            received_quantity=120,
            created_by=user,
        )
        self.assertEqual(receipt.not_started_quantity, 120)
        self.assertEqual(receipt.current_quantity, 120)
        self.assertFalse(receipt.reconciled)


class InventoryReceiptPlantScopeTests(APITestCase):
    def setUp(self):
        factory = Factory.objects.create(name='Test Factory', code='FAC-INV-01')
        self.plant_a = Plant.objects.create(factory=factory, name='Plant A', code='PLT-INV-A')
        self.plant_b = Plant.objects.create(factory=factory, name='Plant B', code='PLT-INV-B')
        self.user_a = get_user_model().objects.create_user(
            username='plant-a-user', password='test-pass', plant=self.plant_a,
            access_grants=['inventory.view', 'inventory.manage'],
        )
        self.machine_a = Machine.objects.create(
            plant=self.plant_a, name='CNC A', machine_code='CNC-INV-A', status='active',
        )
        self.part_a = Part.objects.create(
            machine=self.machine_a, part_number='PART-INV-A', part_name='Part A', created_by=self.user_a,
        )
        self.receipt_a = InventoryReceipt.objects.create(
            plant=self.plant_a, company_name='Customer A', challan_number='A-001',
            part_name='Part A', received_quantity=10, completed_quantity=10,
        )
        self.receipt_b = InventoryReceipt.objects.create(
            plant=self.plant_b, company_name='Customer B', challan_number='B-001',
            part_name='Part B', received_quantity=10, completed_quantity=10,
        )
        self.client.force_authenticate(self.user_a)

    def test_list_and_detail_are_limited_to_users_plant(self):
        response = self.client.get('/api/inventory/receipts/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row['id'] for row in response.data['results']], [self.receipt_a.id])

        response = self.client.get(f'/api/inventory/receipts/{self.receipt_b.id}/')
        self.assertEqual(response.status_code, 404)

    def test_dispatch_cannot_target_another_plants_receipt(self):
        response = self.client.post(f'/api/inventory/receipts/{self.receipt_b.id}/dispatch/', {'quantity': 1}, format='json')
        self.assertEqual(response.status_code, 404)
        self.receipt_b.refresh_from_db()
        self.assertEqual(self.receipt_b.dispatched_quantity, 0)

    def test_dispatch_unknown_receipt_returns_not_found(self):
        response = self.client.post(
            '/api/inventory/receipts/999999/dispatch/',
            {'quantity': 1}, format='json',
        )
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.data['detail'], 'Receipt not found.')

    def test_fractional_dispatch_is_rejected(self):
        response = self.client.post(
            f'/api/inventory/receipts/{self.receipt_a.id}/dispatch/',
            {'quantity': 1.9}, format='json',
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn('whole number', response.data['quantity'][0])
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.dispatched_quantity, 0)

    def test_retried_dispatch_is_idempotent(self):
        payload = {'quantity': 2, 'idempotency_key': 'dispatch-retry-001'}
        first = self.client.post(
            f'/api/inventory/receipts/{self.receipt_a.id}/dispatch/', payload, format='json',
        )
        retry = self.client.post(
            f'/api/inventory/receipts/{self.receipt_a.id}/dispatch/', payload, format='json',
        )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(retry.status_code, 200)
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.dispatched_quantity, 2)
        self.assertEqual(self.receipt_a.dispatch_events.count(), 1)

    def test_report_correction_cannot_reduce_below_dispatched(self):
        report = DailyProductionReport.objects.create(
            date=date.today(), machine=self.machine_a, part=self.part_a,
            inventory_receipt=self.receipt_a, operator=self.user_a,
            jobs_completed=10, correct_jobs=10, incorrect_jobs=0,
            status=DailyProductionReport.Status.SUBMITTED,
        )
        dispatch = self.client.post(
            f'/api/inventory/receipts/{self.receipt_a.id}/dispatch/',
            {'quantity': 6}, format='json',
        )
        self.assertEqual(dispatch.status_code, 200)

        report.jobs_completed = 2
        report.correct_jobs = 2
        with self.assertRaises(ValidationError) as raised:
            report.save()
        self.assertIn('below parts already dispatched', str(raised.exception))
        report.refresh_from_db()
        self.receipt_a.refresh_from_db()
        self.assertEqual(report.correct_jobs, 10)
        self.assertEqual(self.receipt_a.completed_quantity, 10)

    def test_report_cannot_link_unrelated_receipt_part(self):
        self.user_a.access_grants = ['inventory.view', 'inventory.manage', 'production.daily.manage']
        self.user_a.save(update_fields=['access_grants'])
        response = self.client.post('/api/inspections/daily-production-reports/', {
            'date': date.today().isoformat(), 'machine': self.machine_a.id,
            'part': self.part_a.id, 'operation': 'Facing', 'shift': 'I',
            'inventory_receipt': self.receipt_b.id,
            'jobs_completed': 1, 'correct_jobs': 1, 'incorrect_jobs': 0,
            'cr_count': 0, 'mr_count': 0, 'rw_count': 0,
        }, format='json')
        self.assertEqual(response.status_code, 400)
        self.assertIn('inventory_receipt', response.data)

    def test_report_automatically_links_the_selected_company_inventory(self):
        self.user_a.access_grants = ['inventory.view', 'inventory.manage', 'production.daily.manage']
        self.user_a.save(update_fields=['access_grants'])

        response = self.client.post('/api/inspections/daily-production-reports/', {
            'date': date.today().isoformat(), 'machine': self.machine_a.id,
            'part': self.part_a.id, 'operation': 'Facing', 'shift': 'I',
            'inventory_company_name': 'Customer A',
            'jobs_completed': 2, 'correct_jobs': 2, 'incorrect_jobs': 0,
            'cr_count': 0, 'mr_count': 0, 'rw_count': 0,
        }, format='json')

        self.assertEqual(response.status_code, 201, response.data)
        report = DailyProductionReport.objects.get(pk=response.data['id'])
        self.assertEqual(report.inventory_receipt_id, self.receipt_a.id)
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.completed_quantity, 2)

    def test_new_receipt_uses_request_users_plant(self):
        response = self.client.post('/api/inventory/receipts/', {
            'company_name': 'Customer C',
            'challan_number': 'C-001',
            'part_name': 'Part C',
            'received_quantity': 5,
        }, format='json')
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data['plant'], self.plant_a.id)

    def test_unassigned_user_uses_the_only_active_plant(self):
        self.plant_b.is_active = False
        self.plant_b.save(update_fields=['is_active'])
        user = get_user_model().objects.create_user(
            username='unassigned-inventory-user', password='test-pass',
            access_grants=['inventory.view', 'inventory.manage'],
        )
        self.client.force_authenticate(user)
        response = self.client.post('/api/inventory/receipts/', {
            'company_name': 'Customer E', 'challan_number': 'E-001',
            'part_name': 'Part E', 'received_quantity': 5,
            'machine_sequence_steps': [
                {'machine_id': self.machine_a.id, 'operation': 'Facing'},
            ],
        }, format='json')
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data['plant'], self.plant_a.id)

    def test_inventory_manager_can_read_receipt_setup_data(self):
        machines = self.client.get('/api/machines/', {'plant': self.plant_a.id, 'status': 'active'})
        parts = self.client.get('/api/parts/', {'machine': self.machine_a.id})
        self.assertEqual(machines.status_code, 200)
        self.assertEqual(parts.status_code, 200)

    def test_receipt_list_prefetches_dispatch_history(self):
        response = self.client.get('/api/inventory/receipts/')
        self.assertEqual(response.status_code, 200)
        self.assertIn('dispatch_history', response.data['results'][0])

    def test_user_cannot_create_receipt_for_another_plant(self):
        response = self.client.post('/api/inventory/receipts/', {
            'plant': self.plant_b.id,
            'company_name': 'Customer D',
            'challan_number': 'D-001',
            'part_name': 'Part D',
            'received_quantity': 5,
        }, format='json')
        self.assertEqual(response.status_code, 400)
        self.assertIn('plant', response.data)

    def test_partial_incoming_updates_quantity_and_audit(self):
        response = self.client.post(
            f'/api/inventory/receipts/{self.receipt_a.id}/intake/',
            {'quantity': 5, 'vehicle_number': 'MH-12-AA-1234', 'notes': 'Evening arrival'},
            format='json',
        )
        self.assertEqual(response.status_code, 200)
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.received_quantity, 15)
        self.assertEqual(self.receipt_a.not_started_quantity, 5)
        self.assertEqual(response.data['incoming_history'][0]['quantity'], 5)
        self.assertEqual(response.data['incoming_history'][0]['vehicle_number'], 'MH-12-AA-1234')

    def test_received_quantity_cannot_be_manually_changed(self):
        response = self.client.patch(
            f'/api/inventory/receipts/{self.receipt_a.id}/',
            {'received_quantity': 25},
            format='json',
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn('received_quantity', response.data)

    def test_unused_receipt_can_be_deleted(self):
        response = self.client.delete(f'/api/inventory/receipts/{self.receipt_a.id}/')
        self.assertEqual(response.status_code, 204)
        self.assertFalse(InventoryReceipt.objects.filter(pk=self.receipt_a.id).exists())

    def test_receipt_with_production_history_cannot_be_deleted(self):
        DailyProductionReport.objects.create(
            date=date.today(), machine=self.machine_a, part=self.part_a,
            inventory_receipt=self.receipt_a, operator=self.user_a,
            jobs_completed=1, correct_jobs=1, incorrect_jobs=0,
            status=DailyProductionReport.Status.SUBMITTED,
        )
        response = self.client.delete(f'/api/inventory/receipts/{self.receipt_a.id}/')
        self.assertEqual(response.status_code, 400)
        self.assertIn('cannot be deleted', response.data['detail'])
        self.assertTrue(InventoryReceipt.objects.filter(pk=self.receipt_a.id).exists())

    def test_deleting_submitted_report_reconciles_former_receipt(self):
        report = DailyProductionReport.objects.create(
            date=date.today(), machine=self.machine_a, part=self.part_a,
            inventory_receipt=self.receipt_a, operator=self.user_a,
            jobs_completed=4, correct_jobs=4, incorrect_jobs=0,
            status=DailyProductionReport.Status.SUBMITTED,
        )
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.completed_quantity, 4)

        report.delete()
        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.completed_quantity, 0)

    def test_repeated_route_stages_keep_separate_positions(self):
        machine_b = Machine.objects.create(
            plant=self.plant_a, name='CNC B', machine_code='CNC-INV-B', status='active',
        )
        self.receipt_a.machine_sequence_steps = [
            {'machine_id': self.machine_a.id, 'machine_code': 'CNC-INV-A', 'operation': 'Facing'},
            {'machine_id': machine_b.id, 'machine_code': 'CNC-INV-B', 'operation': 'Drilling'},
            {'machine_id': self.machine_a.id, 'machine_code': 'CNC-INV-A', 'operation': 'Facing'},
        ]
        self.receipt_a.save()

        for machine, correct in ((self.machine_a, 4), (machine_b, 3), (self.machine_a, 2)):
            DailyProductionReport.objects.create(
                date=date.today(), machine=machine, part=self.part_a,
                inventory_receipt=self.receipt_a, operator=self.user_a,
                operation='Facing' if machine is self.machine_a else 'Drilling',
                jobs_completed=correct, correct_jobs=correct, incorrect_jobs=0,
                status=DailyProductionReport.Status.SUBMITTED,
            )

        self.receipt_a.refresh_from_db()
        self.assertEqual(len(self.receipt_a.position_summary), 3)
        self.assertIn('Step 1: CNC-INV-A / Facing', self.receipt_a.position_summary)
        self.assertIn('Step 3: CNC-INV-A / Facing', self.receipt_a.position_summary)

    def test_unsequenced_reports_are_capped_at_received_quantity(self):
        for correct in (7, 8):
            DailyProductionReport.objects.create(
                date=date.today(), machine=self.machine_a, part=self.part_a,
                inventory_receipt=self.receipt_a, operator=self.user_a,
                jobs_completed=correct, correct_jobs=correct, incorrect_jobs=0,
                status=DailyProductionReport.Status.SUBMITTED,
            )

        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.received_quantity, 10)
        self.assertEqual(self.receipt_a.completed_quantity, 10)

    def test_summary_uses_jobs_completed_not_sum_of_route_positions(self):
        receipt = InventoryReceipt.objects.create(
            plant=self.plant_a, company_name='Customer Flow', challan_number='FLOW-001',
            part_name='Part A', received_quantity=200,
            machine_sequence_steps=[
                {'machine_id': self.machine_a.id, 'machine_code': 'CNC-INV-A', 'operation': 'Facing'},
                {'machine_id': self.machine_a.id, 'machine_code': 'CNC-INV-A', 'operation': 'Finishing'},
            ],
        )
        DailyProductionReport.objects.create(
            date=date.today(), machine=self.machine_a, part=self.part_a,
            inventory_receipt=receipt, operator=self.user_a, operation='Facing',
            jobs_completed=100, correct_jobs=90, incorrect_jobs=10,
            cr_count=4, rw_count=6, status=DailyProductionReport.Status.SUBMITTED,
        )

        receipt.refresh_from_db()
        self.assertEqual(receipt.not_started_quantity, 100)
        self.assertEqual(receipt.in_process_quantity, 100)
        self.assertEqual(receipt.completed_quantity, 0)
        self.assertEqual(receipt.position_summary['CNC-INV-A / Facing'], 110)
        self.assertEqual(receipt.position_summary['CNC-INV-A / Finishing'], 90)

    def test_malformed_machine_sequence_is_rejected(self):
        response = self.client.post('/api/inventory/receipts/', {
            'company_name': 'Customer Invalid',
            'challan_number': 'INVALID-001',
            'part_name': 'Part Invalid',
            'received_quantity': 5,
            'machine_sequence_steps': ['not-a-step'],
        }, format='json')
        self.assertEqual(response.status_code, 400)
        self.assertIn('machine_sequence_steps', response.data)

    def test_machine_sequence_requires_operation_name(self):
        response = self.client.post('/api/inventory/receipts/', {
            'company_name': 'Customer Missing Operation',
            'challan_number': 'MISSING-OP-001',
            'part_name': 'Part Missing Operation',
            'received_quantity': 5,
            'machine_sequence_steps': [{'machine_id': self.machine_a.id, 'operation': ' '}],
        }, format='json')
        self.assertEqual(response.status_code, 400)
        self.assertIn('machine_sequence_steps', response.data)

    def test_unicode_machine_sequence_is_reconciled(self):
        machine_b = Machine.objects.create(
            plant=self.plant_a, name='CNC B', machine_code='CNC-INV-B', status='active',
        )
        self.receipt_a.machine_sequence = 'CNC-INV-A / Facing → CNC-INV-B / Drilling'
        self.receipt_a.save()
        for machine, operation, correct in (
            (self.machine_a, 'Facing', 4),
            (machine_b, 'Drilling', 3),
        ):
            DailyProductionReport.objects.create(
                date=date.today(), machine=machine, part=self.part_a,
                inventory_receipt=self.receipt_a, operator=self.user_a,
                operation=operation, jobs_completed=correct, correct_jobs=correct,
                incorrect_jobs=0, status=DailyProductionReport.Status.SUBMITTED,
            )

        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.completed_quantity, 3)
        self.assertEqual(len(self.receipt_a.position_summary), 2)

    def test_machine_code_change_does_not_erase_tracking(self):
        self.receipt_a.machine_sequence_steps = [{
            'machine_id': self.machine_a.id,
            'machine_code': 'CNC-INV-A',
            'operation': 'Facing',
        }]
        self.receipt_a.save()
        self.machine_a.machine_code = 'CNC-INV-A-RENAMED'
        self.machine_a.save()

        DailyProductionReport.objects.create(
            date=date.today(), machine=self.machine_a, part=self.part_a,
            inventory_receipt=self.receipt_a, operator=self.user_a,
            operation='Facing', jobs_completed=4, correct_jobs=4,
            incorrect_jobs=0, status=DailyProductionReport.Status.SUBMITTED,
        )

        self.receipt_a.refresh_from_db()
        self.assertEqual(self.receipt_a.completed_quantity, 4)
