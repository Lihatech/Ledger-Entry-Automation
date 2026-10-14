from rest_framework import serializers
from apps.machines.models import Machine, Plant
from .models import InventoryReceipt


class InventoryReceiptSerializer(serializers.ModelSerializer):
    plant_name = serializers.CharField(source='plant.name', read_only=True)
    factory_name = serializers.CharField(source='plant.factory.name', read_only=True)
    plant = serializers.PrimaryKeyRelatedField(
        queryset=Plant.objects.filter(is_active=True),
        required=False,
        allow_null=False,
    )
    current_quantity = serializers.IntegerField(read_only=True)
    reconciled = serializers.BooleanField(read_only=True)
    status_label = serializers.SerializerMethodField()
    received_by_name = serializers.SerializerMethodField()
    dispatch_history = serializers.SerializerMethodField()

    class Meta:
        model = InventoryReceipt
        fields = [
            'id', 'plant', 'plant_name', 'factory_name', 'company_name', 'challan_number', 'part_name',
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

    def validate(self, attrs):
        request = self.context.get('request')
        user = getattr(request, 'user', None)
        user_plant_id = getattr(user, 'plant_id', None)
        submitted_plant = attrs.get('plant')

        # A plant-assigned user cannot create or move a receipt into another
        # plant. If omitted, their assigned plant is used automatically.
        if user_plant_id:
            if submitted_plant and submitted_plant.pk != user_plant_id:
                raise serializers.ValidationError({'plant': 'You can only use your assigned plant.'})
            attrs['plant'] = Plant.objects.get(pk=user_plant_id)
        elif submitted_plant is None and self.instance is None:
            steps = attrs.get('machine_sequence_steps') or []
            machine_ids = [step.get('machine_id') for step in steps if isinstance(step, dict) and step.get('machine_id')]
            machines = list(Machine.objects.filter(pk__in=machine_ids).select_related('plant'))
            plant_ids = {machine.plant_id for machine in machines if machine.plant_id}
            if len(set(machine_ids)) != len(machines) or len(plant_ids) != 1:
                raise serializers.ValidationError({'plant': 'Select a plant or add machine steps from one plant.'})
            attrs['plant'] = Plant.objects.get(pk=plant_ids.pop())

        if self.instance and 'plant' in attrs and attrs['plant'].pk != self.instance.plant_id:
            raise serializers.ValidationError({'plant': 'A receipt cannot be moved between plants.'})

        steps = attrs.get('machine_sequence_steps')
        if steps:
            if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
                raise serializers.ValidationError({'machine_sequence_steps': 'Each machine step must be an object.'})
            machine_ids = [step.get('machine_id') for step in steps if step.get('machine_id')]
            if len(machine_ids) != len(steps):
                raise serializers.ValidationError({'machine_sequence_steps': 'Each step must include a machine.'})
            machines = list(Machine.objects.filter(pk__in=machine_ids).select_related('plant'))
            if len(machines) != len(set(machine_ids)):
                raise serializers.ValidationError({'machine_sequence_steps': 'One or more selected machines do not exist.'})
            step_plant_ids = {machine.plant_id for machine in machines}
            receipt_plant_id = (attrs.get('plant') or getattr(self.instance, 'plant', None))
            receipt_plant_id = getattr(receipt_plant_id, 'pk', receipt_plant_id)
            if len(step_plant_ids) != 1 or (receipt_plant_id and step_plant_ids != {receipt_plant_id}):
                raise serializers.ValidationError({'machine_sequence_steps': 'All machines must belong to the receipt plant.'})

        if self.instance is None and not attrs.get('plant'):
            raise serializers.ValidationError({'plant': 'Plant is required for a new receipt.'})
        return attrs

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
