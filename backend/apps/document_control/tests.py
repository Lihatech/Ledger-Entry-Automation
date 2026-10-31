import io
from unittest.mock import patch
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient
from apps.document_control.models import Document, DocumentChangeRequest, DCRNotification, DocumentUserPermission

User = get_user_model()


class AssignedDocumentWorkflowTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.owner = User.objects.create(username='workflow_owner', role='admin')
        self.reviewer = User.objects.create(username='workflow_reviewer', role='operator', access_denials=['document.view_unapproved', 'document.upload', 'document.approve'])
        self.approver = User.objects.create(username='workflow_approver', role='operator', access_denials=['document.view_unapproved', 'document.upload', 'document.approve'])
        self.outsider = User.objects.create(username='workflow_outsider', role='operator')
        self.doc = Document.objects.create(document_number='WORKFLOW-01', title='Workflow test', uploaded_by=self.owner, reviewed_by=self.reviewer, approved_by=self.approver, status='under_review')
        self.url = f'/api/document-control/documents/{self.doc.pk}/'

    def test_assignment_visibility_and_privacy(self):
        for user in (self.reviewer, self.approver):
            self.client.force_authenticate(user)
            response = self.client.get(self.url)
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.data['my_permissions']['can_preview'])
            response = self.client.get('/api/document-control/documents/')
            rows = response.data.get('results', []) if isinstance(response.data, dict) else response.data
            self.assertIn(str(self.doc.pk), [str(row['id']) for row in rows])
        self.client.force_authenticate(self.outsider)
        self.assertEqual(self.client.get(self.url).status_code, 404)

    @patch('apps.document_control.services.doc_mailer._send_async_email')
    def test_sequential_review_approval_and_notification(self, mail):
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.post(self.url + 'approve/').status_code, 400)
        self.assertFalse(DCRNotification.objects.filter(document=self.doc).exists())
        self.client.force_authenticate(self.reviewer)
        self.assertEqual(self.client.post(self.url + 'submit_review/').status_code, 200)
        self.assertTrue(DCRNotification.objects.filter(document=self.doc, recipient=self.approver, action_type='doc_approval_requested').exists())
        self.assertEqual(self.client.post(self.url + 'submit_review/').status_code, 400)
        self.client.force_authenticate(self.approver)
        self.assertEqual(self.client.post(self.url + 'approve/').status_code, 200)
        self.doc.refresh_from_db()
        self.assertEqual(self.doc.status, 'approved')
        self.assertIsNotNone(self.doc.reviewed_at)
        self.assertEqual(self.client.post(self.url + 'reject/').status_code, 400)

    @patch('apps.document_control.services.doc_mailer._send_async_email')
    def test_assigned_reviewer_can_reject(self, mail):
        self.client.force_authenticate(self.reviewer)
        self.assertEqual(self.client.post(self.url + 'reject/', {'comment': 'Needs correction'}).status_code, 200)


class DocumentControlSystemTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        # Users
        self.admin = User.objects.create_user(
            username='admin_user',
            password='password123',
            role='admin',
            first_name='Admin',
            last_name='User',
            email='admin@example.com'
        )
        self.supervisor = User.objects.create_user(
            username='supervisor_user',
            password='password123',
            role='supervisor',
            first_name='Supervisor',
            last_name='User',
            email='supervisor@example.com'
        )
        self.calibrator = User.objects.create_user(
            username='calibrator_user',
            password='password123',
            role='calibrator',
            first_name='Calibrator',
            last_name='User',
            email='calibrator@example.com'
        )
        self.operator = User.objects.create_user(
            username='operator_user',
            password='password123',
            role='operator',
            first_name='Operator',
            last_name='User',
            email='operator@example.com'
        )
        self.inspector = User.objects.create_user(
            username='inspector_user',
            password='password123',
            role='inspector',
            first_name='Inspector',
            last_name='User',
            email='inspector@example.com'
        )
        self.reviewer = User.objects.create_user(
            username='reviewer_user',
            password='password123',
            role='supervisor',
            first_name='Reviewer',
            last_name='User',
            email='reviewer@example.com'
        )

        self.doc_l1 = Document.objects.create(
            document_number='MANUAL-01',
            title='Quality Manual',
            doc_level='L1',
            revision='Rev A',
            status='approved',
            uploaded_by=self.admin,
            cloudinary_url='https://res.cloudinary.com/test/raw/upload/v1/manual.pdf'
        )
        self.doc_l2 = Document.objects.create(
            document_number='SOP-MCH-01',
            title='CNC Machine Setup SOP',
            doc_level='L2',
            revision='Rev A',
            status='approved',
            uploaded_by=self.supervisor,
            cloudinary_url='https://res.cloudinary.com/test/raw/upload/v1/sop.pdf'
        )
        self.doc_l3 = Document.objects.create(
            document_number='WI-QC-05',
            title='Vernier Caliper Work Instruction',
            doc_level='L3',
            revision='Rev B',
            status='approved',
            uploaded_by=self.calibrator,
            cloudinary_url='https://res.cloudinary.com/test/raw/upload/v1/wi.pdf'
        )
        self.doc_l4 = Document.objects.create(
            document_number='DKI/MR/F/05',
            title='Document Change Request Form',
            doc_level='L4',
            revision='Rev 01',
            status='approved',
            uploaded_by=self.admin
        )

        # Grant supervisor permissions on documents
        DocumentUserPermission.objects.create(
            document=self.doc_l1, user=self.supervisor,
            can_preview=True, can_download=True, can_print=True, can_edit=True
        )
        DocumentUserPermission.objects.create(
            document=self.doc_l3, user=self.supervisor,
            can_preview=True, can_download=True, can_print=True, can_edit=True
        )

    def test_level_filtering(self):
        """Verify ?level=L1/L2/L3/L4 filters work accurately."""
        self.client.force_authenticate(user=self.supervisor)

        # Test L1
        res = self.client.get('/api/document-control/documents/?level=L1')
        self.assertEqual(res.status_code, 200)
        docs = res.data if isinstance(res.data, list) else res.data.get('results', [])
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0]['document_number'], 'MANUAL-01')

        # Test L3
        res = self.client.get('/api/document-control/documents/?level=L3')
        self.assertEqual(res.status_code, 200)
        docs = res.data if isinstance(res.data, list) else res.data.get('results', [])
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0]['document_number'], 'WI-QC-05')

    def test_preview_permission_enforcement(self):
        """Users without preview access cannot see delivery/cloudinary URLs and are blocked from /preview/."""
        # 1. Operator has download-only permission (can_preview=False, can_download=True)
        DocumentUserPermission.objects.create(
            document=self.doc_l1, user=self.operator,
            can_preview=False, can_download=True, can_print=False, can_edit=False
        )
        self.client.force_authenticate(user=self.operator)

        # Document list hides delivery_url and cloudinary_url
        res = self.client.get('/api/document-control/documents/')
        self.assertEqual(res.status_code, 200)
        docs = res.data if isinstance(res.data, list) else res.data.get('results', [])
        op_doc = next((d for d in docs if str(d['id']) == str(self.doc_l1.id)), None)
        self.assertIsNotNone(op_doc)
        self.assertIsNone(op_doc.get('delivery_url'))
        self.assertIsNone(op_doc.get('cloudinary_url'))
        self.assertFalse(op_doc['my_permissions']['can_preview'])
        self.assertTrue(op_doc['my_permissions']['can_download'])

        # /preview/ endpoint blocks download-only user with 403 Forbidden
        preview_res = self.client.get(f'/api/document-control/documents/{self.doc_l1.id}/preview/')
        self.assertEqual(preview_res.status_code, 403)

        # /download/ endpoint succeeds with 302 Redirect
        download_res = self.client.get(f'/api/document-control/documents/{self.doc_l1.id}/download/')
        self.assertEqual(download_res.status_code, 302)

        # 2. Inspector has can_preview=True
        DocumentUserPermission.objects.create(
            document=self.doc_l1, user=self.inspector,
            can_preview=True, can_download=False, can_print=False, can_edit=False
        )
        self.client.force_authenticate(user=self.inspector)

        # Document list provides delivery_url
        res = self.client.get('/api/document-control/documents/')
        docs = res.data if isinstance(res.data, list) else res.data.get('results', [])
        insp_doc = next((d for d in docs if str(d['id']) == str(self.doc_l1.id)), None)
        self.assertIsNotNone(insp_doc)
        self.assertIsNotNone(insp_doc.get('delivery_url'))
        self.assertTrue(insp_doc['my_permissions']['can_preview'])

        # /preview/ endpoint allows inspector with 302 Redirect
        preview_res = self.client.get(f'/api/document-control/documents/{self.doc_l1.id}/preview/')
        self.assertEqual(preview_res.status_code, 302)

    def test_role_restrictions_on_dcr_submission(self):
        """Users without DCR create access are strictly blocked from submitting DCRs."""
        # 1. Operator attempts DCR -> 403 Forbidden
        self.client.force_authenticate(user=self.operator)
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l2.id),
            'change_type': 'modification',
            'reason_for_change': 'Operator wants change',
            'existing_revision': 'Rev A',
            'proposed_revision': 'Rev B',
            'reviewer_id': self.reviewer.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 403)
        err = res.data.get('error', '')
        self.assertTrue('Change request creation access required' in err or 'permission to propose changes' in err)

        # 2. Inspector attempts DCR -> 403 Forbidden
        self.client.force_authenticate(user=self.inspector)
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l2.id),
            'change_type': 'modification',
            'reason_for_change': 'Inspector wants change',
            'existing_revision': 'Rev A',
            'proposed_revision': 'Rev B',
            'reviewer_id': self.reviewer.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 403)
        err = res.data.get('error', '')
        self.assertTrue('Change request creation access required' in err or 'permission to propose changes' in err)

    def test_self_assignment_prohibited(self):
        """User cannot assign themselves as reviewer or approver."""
        self.client.force_authenticate(user=self.supervisor)
        # Attempt self-assignment as reviewer
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l2.id),
            'change_type': 'modification',
            'reason_for_change': 'Self review test',
            'existing_revision': 'Rev A',
            'proposed_revision': 'Rev B',
            'reviewer_id': self.supervisor.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 400)
        self.assertIn('cannot assign yourself as the CFT Reviewer', str(res.data))

        # Attempt self-assignment as approver
        self.client.force_authenticate(user=self.admin)
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l2.id),
            'change_type': 'modification',
            'reason_for_change': 'Self approval test',
            'existing_revision': 'Rev A',
            'proposed_revision': 'Rev B',
            'reviewer_id': self.reviewer.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 400)
        self.assertIn('cannot assign yourself as the Approver', str(res.data))

    def test_complete_dcr_workflow(self):
        """Supervisor submits DCR -> Reviewer reviews & approves -> Admin approves -> Doc revision updated."""
        # Step 1: Supervisor submits DCR
        self.client.force_authenticate(user=self.supervisor)
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l2.id),
            'change_type': 'modification',
            'reason_for_change': 'Updated tooling specs',
            'nature_of_change': 'Modified table in section 3.1',
            'existing_revision': 'Rev A',
            'proposed_revision': 'Rev B',
            'reviewer_id': self.reviewer.id,
            'calibrator_id': self.calibrator.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 201)
        dcr_id = res.data['id']
        dcr_number = res.data['dcr_number']
        self.assertTrue(dcr_number.startswith('DCR-'))
        self.assertEqual(res.data['status'], 'awaiting_review')

        # Check Reviewer received in-app notification
        review_notif = DCRNotification.objects.filter(recipient=self.reviewer, dcr_id=dcr_id).first()
        self.assertIsNotNone(review_notif)
        self.assertIn('review', review_notif.title.lower())

        # Step 2: Reviewer reviews and approves
        self.client.force_authenticate(user=self.reviewer)
        res = self.client.post(f'/api/document-control/change-requests/{dcr_id}/submit_review/', {
            'comments': 'Tooling changes verified and feasible.'
        })
        self.assertEqual(res.status_code, 200)
        dcr = DocumentChangeRequest.objects.get(id=dcr_id)
        self.assertEqual(dcr.status, 'awaiting_approval')
        self.assertEqual(dcr.review_remark, 'Tooling changes verified and feasible.')

        # Check Approver received in-app notification
        admin_notif = DCRNotification.objects.filter(recipient=self.admin, dcr_id=dcr_id).first()
        self.assertIsNotNone(admin_notif)
        self.assertIn('approval', admin_notif.title.lower())

        # Step 3: Admin approves DCR
        self.client.force_authenticate(user=self.admin)
        res = self.client.post(f'/api/document-control/change-requests/{dcr_id}/approve/', {
            'comments': 'Approved for release as Rev B.'
        })
        self.assertEqual(res.status_code, 200)
        dcr.refresh_from_db()
        self.assertEqual(dcr.status, 'approved')
        self.assertEqual(dcr.mr_remarks, 'Approved for release as Rev B.')

        # Target document is verified approved
        self.doc_l2.refresh_from_db()
        self.assertEqual(self.doc_l2.status, 'approved')

        # Step 4: PDF Export test
        res = self.client.get(f'/api/document-control/change-requests/{dcr_id}/pdf/')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res['Content-Type'], 'application/pdf')
        self.assertIn(f'filename="{dcr_number}.pdf"', res['Content-Disposition'])
        self.assertTrue(len(res.content) > 1000) # Valid PDF bytes

    def test_dcr_review_rejection_workflow(self):
        """Reviewer rejects DCR -> status becomes rejected, requestor notified, approver bypassed."""
        self.client.force_authenticate(user=self.supervisor)
        res = self.client.post('/api/document-control/change-requests/submit/', {
            'document_id': str(self.doc_l3.id),
            'change_type': 'deletion',
            'reason_for_change': 'Obsolete step',
            'existing_revision': 'Rev B',
            'proposed_revision': 'Rev C',
            'reviewer_id': self.reviewer.id,
            'approver_id': self.admin.id,
        })
        self.assertEqual(res.status_code, 201)
        dcr_id = res.data['id']

        # Reviewer rejects
        self.client.force_authenticate(user=self.reviewer)
        res = self.client.post(f'/api/document-control/change-requests/{dcr_id}/reject_review/', {
            'rejected_reason': 'Step cannot be deleted as it is required by customer audit.'
        })
        self.assertEqual(res.status_code, 200)
        dcr = DocumentChangeRequest.objects.get(id=dcr_id)
        self.assertEqual(dcr.status, 'rejected')
        self.assertEqual(dcr.rejection_stage, 'review')
        self.assertIn('required by customer audit', dcr.rejection_reason)

        # Requestor should have received rejection notification
        notif = DCRNotification.objects.filter(
            recipient=self.supervisor,
            action_type=DCRNotification.ActionType.DCR_REJECTED
        ).first()
        self.assertIsNotNone(notif)
        self.assertIn('rejected', notif.title.lower())
