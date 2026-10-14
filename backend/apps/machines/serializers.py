from rest_framework import serializers
from django.utils.text import slugify
from .models import Factory, Plant, Machine


class FactorySerializer(serializers.ModelSerializer):
    plant_count = serializers.IntegerField(source='plants.count', read_only=True)

    class Meta:
        model  = Factory
        fields = [
            'id', 'name', 'code', 'location',
            'contact_email', 'phone', 'address', 'gstin', 'logo_url', 'industry_type',
            'shift_hours', 'shift_1_start', 'shift_2_start', 'shift_3_start', 'total_shifts_per_day', 'lunch_break_minutes',
            'tea_break_minutes', 'available_working_minutes',
            'is_active', 'plant_count', 'created_at'
        ]

    def to_representation(self, instance):
        ret = super().to_representation(instance)
        # Safely resolve logo_url — CloudinaryField.url can raise if not configured
        url = ret.get('logo_url') or ''
        if not url:
            try:
                logo = getattr(instance, 'logo', None)
                if logo and logo.name:  # name is None/empty when no file is stored
                    url = logo.url
            except Exception:
                url = ''
        if url:
            if not (url.startswith('http://') or url.startswith('https://')):
                request = self.context.get('request')
                if request:
                    ret['logo_url'] = request.build_absolute_uri(url)
                else:
                    ret['logo_url'] = url
            else:
                ret['logo_url'] = url
        return ret


class PlantSerializer(serializers.ModelSerializer):
    code = serializers.CharField(required=False, allow_blank=True)
    factory_name   = serializers.CharField(source='factory.name', read_only=True)
    machine_count  = serializers.IntegerField(source='machines.count', read_only=True)

    class Meta:
        model  = Plant
        fields = ['id', 'factory', 'factory_name', 'name', 'code', 'shift_duration_hours', 'total_break_mins', 'is_active', 'machine_count', 'created_at']

    def create(self, validated_data):
        if not validated_data.get('code'):
            factory = validated_data.get('factory')
            base = slugify(validated_data.get('name', 'plant')).upper().replace('-', '')[:12] or 'PLANT'
            prefix = f'{base}-{factory.pk if factory else 0}'
            code = prefix[:20]
            suffix = 1
            while Plant.objects.filter(code=code).exists():
                suffix += 1
                code = f'{prefix[:17]}-{suffix}'[:20]
            validated_data['code'] = code
        return super().create(validated_data)


class MachineSerializer(serializers.ModelSerializer):
    plant = serializers.PrimaryKeyRelatedField(queryset=Plant.objects.all(), required=False, allow_null=True)
    plant_name   = serializers.SerializerMethodField()
    factory_name = serializers.SerializerMethodField()
    shift_duration_hours = serializers.IntegerField(source='plant.shift_duration_hours', read_only=True)
    total_break_mins = serializers.IntegerField(source='plant.total_break_mins', read_only=True)

    class Meta:
        model  = Machine
        fields = [
            'id', 'plant', 'plant_name', 'factory_name',
            'name', 'machine_code', 'machine_type',
            'manufacturer', 'model_number', 'status',
            'qr_code', 'is_active', 'created_at',
            'shift_duration_hours', 'total_break_mins',
        ]

    def get_plant_name(self, obj):
        return obj.plant.name if obj.plant else None

    def get_factory_name(self, obj):
        return obj.plant.factory.name if (obj.plant and obj.plant.factory) else None

    def create(self, validated_data):
        if not validated_data.get('plant'):
            default_plant = Plant.objects.first()
            if default_plant:
                validated_data['plant'] = default_plant
        return super().create(validated_data)


class MachineListSerializer(serializers.ModelSerializer):
    """Lightweight serializer for dropdowns on the Flutter app."""
    shift_duration_hours = serializers.IntegerField(source='plant.shift_duration_hours', read_only=True)

    class Meta:
        model  = Machine
        fields = ['id', 'machine_code', 'name', 'status', 'qr_code', 'shift_duration_hours']
