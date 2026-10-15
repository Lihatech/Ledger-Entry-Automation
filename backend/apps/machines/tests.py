from django.test import TestCase
from rest_framework import serializers
from rest_framework.test import APIRequestFactory

from apps.users.models import User
from .models import Factory, Plant
from .serializers import MachineSerializer


class MachineSerializerPlantAssignmentTests(TestCase):
    def setUp(self):
        self.factory = Factory.objects.create(name='Test Factory', code='TEST')
        self.assigned_plant = Plant.objects.create(
            factory=self.factory, name='Assigned Plant', code='ASSIGNED'
        )
        self.user = User.objects.create_user(
            username='plant-admin', password='test-password', plant=self.assigned_plant
        )
        self.request = APIRequestFactory().post('/api/machines/')
        self.request.user = self.user

    def test_new_machine_uses_the_creators_assigned_plant(self):
        serializer = MachineSerializer(
            data={'machine_code': 'CNC-NEW', 'name': 'New CNC'},
            context={'request': self.request},
        )

        self.assertTrue(serializer.is_valid(), serializer.errors)
        machine = serializer.save()

        self.assertEqual(machine.plant, self.assigned_plant)

    def test_new_machine_without_an_assigned_plant_is_rejected(self):
        self.user.plant = None
        self.user.save(update_fields=['plant'])
        serializer = MachineSerializer(
            data={'machine_code': 'CNC-NO-PLANT', 'name': 'Unassigned CNC'},
            context={'request': self.request},
        )

        self.assertTrue(serializer.is_valid(), serializer.errors)
        with self.assertRaises(serializers.ValidationError):
            serializer.save()
