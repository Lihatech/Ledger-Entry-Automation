from django.contrib import admin
from .models import InventoryReceipt


@admin.register(InventoryReceipt)
class InventoryReceiptAdmin(admin.ModelAdmin):
    list_display = ('company_name', 'challan_number', 'part_name', 'received_quantity', 'created_at')
    search_fields = ('company_name', 'challan_number', 'part_name', 'vehicle_number')
