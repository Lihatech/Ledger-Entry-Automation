import io
import json
from unittest.mock import MagicMock, patch

from rest_framework import status
from rest_framework.test import APITestCase

from apps.users.models import AccessRole, User

from .models import BugReport


class BugReportCreateTests(APITestCase):
    def setUp(self):
        role, _ = AccessRole.objects.get_or_create(
            slug='operator',
            defaults={'name': 'Operator', 'permissions': []},
        )
        if 'support.create' not in role.permissions:
            role.permissions = [*role.permissions, 'support.create']
            role.save(update_fields=['permissions'])

        self.user = User.objects.create_user(
            username='reporter',
            password='password',
            role='operator',
        )
        self.client.force_authenticate(self.user)

    @patch('django.core.mail.EmailMultiAlternatives.send', side_effect=RuntimeError('mail unavailable'))
    def test_report_is_accepted_when_notification_email_fails(self, _send):
        response = self.client.post(
            '/api/support/bug-reports/',
            {'message': 'Second slot does not open'},
            format='multipart',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(BugReport.objects.filter(
            user=self.user,
            message='Second slot does not open',
        ).exists())


class MobileUpdateTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username='updater',
            password='password',
            role='operator',
        )
        self.client.force_authenticate(self.user)

    @patch.dict('os.environ', {'MOBILE_RELEASES_BUCKET': 'releases'})
    @patch('apps.support.views._mobile_releases_client')
    def test_returns_presigned_download_for_newer_version(self, client_factory):
        storage = MagicMock()
        storage.get_object.return_value = {'Body': io.BytesIO(json.dumps({
            'versionCode': 4,
            'versionName': '1.0.2',
            'objectKey': 'android/1.0.2+4/Inspection_Hub.apk',
            'sha256': 'a' * 64,
            'releaseNotes': 'Fixes and improvements',
            'mandatory': False,
        }).encode())}
        storage.generate_presigned_url.return_value = 'https://example.test/update.apk'
        client_factory.return_value = storage

        response = self.client.get('/api/support/mobile-update/?version_code=3')

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['updateAvailable'])
        self.assertEqual(response.data['downloadUrl'], 'https://example.test/update.apk')

    @patch.dict('os.environ', {'MOBILE_RELEASES_BUCKET': 'releases'})
    @patch('apps.support.views._mobile_releases_client')
    def test_does_not_sign_download_when_installed_version_is_current(self, client_factory):
        storage = MagicMock()
        storage.get_object.return_value = {'Body': io.BytesIO(json.dumps({
            'versionCode': 3,
            'versionName': '1.0.1',
            'objectKey': 'android/1.0.1+3/Inspection_Hub.apk',
            'sha256': 'a' * 64,
        }).encode())}
        client_factory.return_value = storage

        response = self.client.get('/api/support/mobile-update/?version_code=3')

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data, {'updateAvailable': False})
        storage.generate_presigned_url.assert_not_called()
