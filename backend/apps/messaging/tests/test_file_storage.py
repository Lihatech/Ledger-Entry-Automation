import io

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from PIL import Image
from rest_framework import status
from rest_framework.test import APITestCase

from apps.users.models import User
from apps.messaging.models import Conversation, Message, MessageAttachment


@override_settings(
    STORAGES={
        'default': {'BACKEND': 'django.core.files.storage.InMemoryStorage'},
        'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'},
    }
)
class MessageImageStorageTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='sender', password='password')
        self.other = User.objects.create_user(username='recipient', password='password')
        self.conversation = Conversation.objects.create(type=Conversation.Type.DIRECT)
        self.conversation.participants.set([self.user, self.other])
        self.message = Message.objects.create(
            conversation=self.conversation,
            sender=self.user,
            content='See image',
        )
        self.client.force_authenticate(self.user)

    def test_image_upload_stores_key_and_returns_compatible_url(self):
        image_bytes = io.BytesIO()
        Image.new('RGB', (4, 4), color='blue').save(image_bytes, format='PNG')
        image = SimpleUploadedFile(
            'machine.png', image_bytes.getvalue(), content_type='image/png'
        )

        response = self.client.post(
            '/api/messaging/upload/',
            {'message_id': str(self.message.id), 'file': image},
            format='multipart',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        attachment = MessageAttachment.objects.get(message=self.message)
        self.assertTrue(attachment.cloudinary_public_id.startswith('messaging/images/'))
        self.assertFalse(attachment.cloudinary_url)
        self.assertIn('messaging/images/', response.data['cloudinary_url'])
