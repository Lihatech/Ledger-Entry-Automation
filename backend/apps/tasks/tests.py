from django.test import TestCase

from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.document_control.models import DCRNotification


User = get_user_model()


class TaskNotificationTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_user(
            username='task-admin',
            email='task-admin@example.com',
            password='testpass123',
            employee_id='TASK-ADMIN',
            role='admin',
        )
        self.operator = User.objects.create_user(
            username='task-operator',
            email='task-operator@example.com',
            password='testpass123',
            employee_id='TASK-OPERATOR',
            role='operator',
        )
        self.client = APIClient()
        self.client.force_authenticate(self.admin)

    @patch('apps.tasks.views.threading.Thread')
    @patch('apps.tasks.views.get_channel_layer', return_value=None)
    def test_task_assignment_creates_global_notification(self, _channel_layer, thread):
        response = self.client.post(
            reverse('task-list'),
            {
                'title': 'Check machine setup',
                'description': 'Verify the first-piece setup.',
                'allocated_to': self.operator.id,
                'deadline': (timezone.now() + timedelta(days=1)).isoformat(),
            },
            format='json',
        )

        self.assertEqual(response.status_code, 201)
        notification = DCRNotification.objects.get(recipient=self.operator)
        self.assertEqual(notification.action_type, DCRNotification.ActionType.GENERAL)
        self.assertEqual(notification.action_url, '/tasks')
        self.assertIn('Check machine setup', notification.message)
        thread.assert_called_once()

# Create your tests here.
