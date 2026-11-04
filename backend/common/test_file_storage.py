from django.core.files.base import ContentFile
from django.test import SimpleTestCase, override_settings

from common.file_storage import save_uploaded_file, stored_file_url


@override_settings(
    STORAGES={
        'default': {'BACKEND': 'django.core.files.storage.InMemoryStorage'},
        'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'},
    }
)
class FileStorageHelpersTests(SimpleTestCase):
    def test_upload_uses_prefix_and_generates_url(self):
        upload = ContentFile(b'example', name='inspection photo.PNG')

        stored = save_uploaded_file(upload, 'bug_reports/screenshots')

        self.assertTrue(stored.key.startswith('bug_reports/screenshots/inspection_photo-'))
        self.assertTrue(stored.key.endswith('.png'))
        self.assertEqual(stored.url, stored_file_url(stored.key))

    def test_fallback_url_is_used_without_key(self):
        self.assertEqual(
            stored_file_url(None, 'https://legacy.example/file.png'),
            'https://legacy.example/file.png',
        )
