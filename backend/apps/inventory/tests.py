from django.contrib.auth import get_user_model
from django.test import TestCase

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
