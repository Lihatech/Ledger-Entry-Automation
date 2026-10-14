import os
import sys
import django
import json

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()

from apps.inspections.models import InspectionSession
from apps.inspections.services import InspectionService

_service = InspectionService()

# Find the specific session
session_id = "f0b14d09-74d9-4bc6-9c63-1d8d8958cf73"
session = InspectionSession.objects.get(session_id=session_id)
print(f"Session: {session.session_id} | Type: {session.inspection_type} | Status: {session.status}")

doc = _service.get_session_document(str(session_id))
completed_slots = []
if doc and 'measurements' in doc:
    slot_set = set()
    for m in doc['measurements']:
        print(f"Meas: {m.get('parameter_code')} | Type: {m.get('inspection_type')} | Slot: {m.get('hourly_slot')}")
        if m.get('inspection_type') == 'hourly':
            slot = m.get('hourly_slot')
            if slot:
                try:
                    slot_set.add(int(slot))
                except Exception:
                    pass
    completed_slots = sorted(list(slot_set))

print(f"Completed Slots: {completed_slots}")
