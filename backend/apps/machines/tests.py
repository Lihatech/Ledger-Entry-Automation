import io

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from PIL import Image
from rest_framework import serializers
from rest_framework import status
from rest_framework.test import APIRequestFactory, APITestCase

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


@override_settings(
    STORAGES={
        'default': {'BACKEND': 'django.core.files.storage.InMemoryStorage'},
        'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'},
    }
)
class FactoryLogoStorageTests(APITestCase):
    def setUp(self):
        self.factory = Factory.objects.create(name='Logo Factory', code='LOGO')
        self.user = User.objects.create_superuser(
            username='logo-admin', email='logo@example.com', password='password'
        )
        self.client.force_authenticate(self.user)

    def test_logo_upload_uses_default_media_storage(self):
        image_bytes = io.BytesIO()
        Image.new('RGB', (4, 4), color='green').save(image_bytes, format='PNG')
        logo = SimpleUploadedFile(
            'logo.png', image_bytes.getvalue(), content_type='image/png'
        )

        response = self.client.post(
            f'/api/machines/factories/{self.factory.id}/upload-logo/',
            {'logo': logo},
            format='multipart',
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.factory.refresh_from_db()
        self.assertTrue(self.factory.logo.name.startswith('company_logos/'))
        self.assertIn('company_logos/', response.data['logo_url'])
