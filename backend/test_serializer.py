import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from apps.inspections.serializers import RecordMeasurementSerializer

data = {
    'parameter_code': 'P1',
    'measured_value': 10.0,
    'voice_raw_text': '10.00',
    'method': 'voice',
    'hourly_slot': None,
    'inspection_type': None
}

s = RecordMeasurementSerializer(data=data)
print("Is valid?", s.is_valid())
if not s.is_valid():
    print(s.errors)
