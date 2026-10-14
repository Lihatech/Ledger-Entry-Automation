from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APITestCase

from apps.machines.models import Factory, Plant
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

    def test_new_receipt_uses_request_users_plant(self):
        response = self.client.post('/api/inventory/receipts/', {
            'company_name': 'Customer C',
            'challan_number': 'C-001',
            'part_name': 'Part C',
            'received_quantity': 5,
        }, format='json')
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data['plant'], self.plant_a.id)

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
