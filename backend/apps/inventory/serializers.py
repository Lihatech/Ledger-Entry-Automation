from rest_framework import serializers
from .models import InventoryReceipt


class InventoryReceiptSerializer(serializers.ModelSerializer):
    current_quantity = serializers.IntegerField(read_only=True)
    reconciled = serializers.BooleanField(read_only=True)
    status_label = serializers.SerializerMethodField()
    received_by_name = serializers.SerializerMethodField()
    dispatch_history = serializers.SerializerMethodField()

    class Meta:
        model = InventoryReceipt
        fields = [
            'id', 'company_name', 'challan_number', 'part_name',
            'received_quantity', 'vehicle_number', 'machine_sequence',
            'machine_sequence_steps',
            'current_quantity', 'not_started_quantity', 'in_process_quantity',
            'completed_quantity', 'rework_quantity', 'rejected_quantity',
            'dispatched_quantity', 'last_reconciled_at', 'reconciled',
            'last_dispatched_at', 'last_dispatched_by',
            'position_summary', 'status_label', 'created_at', 'updated_at',
            'received_by_name', 'dispatch_history',
        ]
        read_only_fields = [
            'current_quantity', 'not_started_quantity', 'in_process_quantity',
            'completed_quantity', 'rework_quantity', 'rejected_quantity',
            'dispatched_quantity', 'last_reconciled_at', 'reconciled',
            'last_dispatched_at', 'last_dispatched_by',
            'position_summary', 'status_label', 'created_at', 'updated_at',
        ]

    def get_status_label(self, obj):
        if obj.dispatched_quantity >= obj.received_quantity:
            return 'Fully dispatched'
        if obj.completed_quantity:
            return 'In production'
        return 'Received'

    def get_received_by_name(self, obj):
        if not obj.created_by:
            return 'System'
        return obj.created_by.get_full_name() or obj.created_by.username

    def get_dispatch_history(self, obj):
        return [
            {
                'quantity': event.quantity,
                'dispatched_by': (event.dispatched_by.get_full_name() or event.dispatched_by.username) if event.dispatched_by else 'System',
                'created_at': event.created_at,
            }
            for event in obj.dispatch_events.select_related('dispatched_by').all()
        ]
