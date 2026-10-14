from django.contrib import admin
from .models import InventoryReceipt, InventoryReceiptIntake


@admin.register(InventoryReceipt)
class InventoryReceiptAdmin(admin.ModelAdmin):
    list_display = ('company_name', 'challan_number', 'part_name', 'received_quantity', 'created_at')
    search_fields = ('company_name', 'challan_number', 'part_name', 'vehicle_number')


@admin.register(InventoryReceiptIntake)
class InventoryReceiptIntakeAdmin(admin.ModelAdmin):
    list_display = ('receipt', 'quantity', 'received_by', 'vehicle_number', 'created_at')
    search_fields = ('receipt__company_name', 'receipt__challan_number', 'vehicle_number', 'notes')
