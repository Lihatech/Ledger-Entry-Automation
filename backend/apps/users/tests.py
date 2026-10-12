from django.test import TestCase
from rest_framework.test import APIClient

from .models import AccessEvent, AccessRole, User
from .access import COMMON_ACCESS


class AccessControlTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_user(username='access_admin', password='password', role='admin')
        self.operator = User.objects.create_user(username='access_operator', password='password', role='operator')

    def test_display_name_falls_back_to_username(self):
        self.assertEqual(self.operator.display_name, 'access_operator')

        self.operator.first_name = 'Asha'
        self.operator.last_name = 'Patel'
        self.operator.save(update_fields=['first_name', 'last_name'])
        self.assertEqual(self.operator.display_name, 'Asha Patel')

    def test_existing_roles_and_common_access(self):
        self.assertTrue(self.operator.has_access('messages.use'))
        self.assertTrue(self.operator.has_access('document.view'))
        self.assertTrue(self.operator.has_access('document.upload'))
        self.assertFalse(self.operator.has_access('calibration.manage'))
        self.assertTrue(self.admin.has_access('calibration.manage'))
        supervisor = User.objects.create_user(username='access_supervisor_seed', role='supervisor')
        self.assertTrue(supervisor.has_access('quality.inspections.review'))
        self.assertFalse(supervisor.has_access('calibration.view'))

    def test_profile_cannot_change_own_role(self):
        self.client.force_authenticate(self.operator)
        response = self.client.patch('/api/users/me/', {'role': 'admin'}, format='json')
        self.assertEqual(response.status_code, 200)
        self.operator.refresh_from_db()
        self.assertEqual(self.operator.role, 'operator')

    def test_role_update_changes_access_without_new_login(self):
        self.client.force_authenticate(self.admin)
        created = self.client.post('/api/users/access/roles/', {
            'name': 'Plant Auditor', 'permissions': ['quality.reports.view'],
        }, format='json')
        self.assertEqual(created.status_code, 201, created.data)
        slug = created.data['slug']
        assigned = self.client.put(f'/api/users/{self.operator.pk}/access/', {
            'role': slug, 'access_grants': [], 'access_denials': [],
        }, format='json')
        self.assertEqual(assigned.status_code, 200, assigned.data)
        self.operator.refresh_from_db()
        self.assertTrue(self.operator.has_access('quality.reports.view'))
        self.assertFalse(self.operator.has_access('calibration.view'))

        updated = self.client.patch(f'/api/users/access/roles/{slug}/', {
            'permissions': ['quality.reports.view', 'calibration.view'],
        }, format='json')
        self.assertEqual(updated.status_code, 200, updated.data)
        self.assertTrue(self.operator.has_access('calibration.view'))
        self.assertTrue(AccessEvent.objects.filter(action='role_updated', role__slug=slug).exists())

    def test_operator_cannot_create_role_or_account(self):
        self.client.force_authenticate(self.operator)
        self.assertEqual(self.client.post('/api/users/access/roles/', {
            'name': 'Unauthorized', 'permissions': [],
        }, format='json').status_code, 403)
        self.assertEqual(self.client.post('/api/users/register/', {
            'username': 'new_user', 'password': 'password', 'password2': 'password', 'role': 'admin',
        }, format='json').status_code, 403)

    def test_registration_returns_role_slug(self):
        self.client.force_authenticate(self.admin)
        response = self.client.post('/api/users/register/', {
            'username': 'registration_check',
            'password': 'password',
            'password2': 'password',
            'role': 'operator',
        }, format='json')
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data['role'], 'operator')

    def test_custom_overrides_and_common_access(self):
        self.client.force_authenticate(self.admin)
        response = self.client.put(f'/api/users/{self.operator.pk}/access/', {
            'role': 'operator', 'access_grants': ['calibration.view'],
            'access_denials': ['production.daily.view'],
        }, format='json')
        self.assertEqual(response.status_code, 200, response.data)
        self.operator.refresh_from_db()
        self.assertTrue(self.operator.has_access('calibration.view'))
        self.assertFalse(self.operator.has_access('production.daily.view'))
        invalid = self.client.put(f'/api/users/{self.operator.pk}/access/', {
            'role': 'operator', 'access_denials': ['messages.use'],
        }, format='json')
        self.assertEqual(invalid.status_code, 200)
        self.operator.refresh_from_db()
        self.assertFalse(self.operator.has_access('messages.use'))

    def test_role_edit_controls_api(self):
        self.client.force_authenticate(self.admin)
        role = AccessRole.objects.get(slug='supervisor')
        self.client.force_authenticate(User.objects.create_user(
            username='access_supervisor', password='password', role='supervisor'))
        self.assertNotEqual(self.client.post('/api/parts/', {}, format='json').status_code, 403)
        role.permissions = [key for key in role.permissions if key != 'quality.parts.manage']
        role.save(update_fields=['permissions'])
        self.assertEqual(self.client.post('/api/parts/', {}, format='json').status_code, 403)

    def test_common_only_role_cannot_read_operational_data(self):
        AccessRole.objects.create(slug='messenger', name='Messenger', permissions=sorted(COMMON_ACCESS))
        self.operator.role = 'messenger'
        self.operator.save(update_fields=['role'])
        self.client.force_authenticate(self.operator)
        self.assertEqual(self.client.get('/api/parts/').status_code, 403)
        self.assertEqual(self.client.get('/api/machines/').status_code, 403)
        self.assertEqual(self.client.get('/api/document-control/documents/').status_code, 200)
