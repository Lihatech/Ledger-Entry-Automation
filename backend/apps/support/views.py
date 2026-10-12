import json
import os

from rest_framework import generics, permissions, status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.parsers import MultiPartParser, FormParser
from django.core.mail import EmailMessage
from django.conf import settings
from .models import BugReport
from .serializers import BugReportSerializer
from apps.users.permissions import HasAccess
import logging

logger = logging.getLogger(__name__)


def _mobile_releases_client():
    import boto3
    from botocore.config import Config

    return boto3.client(
        's3',
        endpoint_url=os.environ['MOBILE_RELEASES_ENDPOINT'],
        region_name=os.environ.get('MOBILE_RELEASES_REGION', 'auto'),
        aws_access_key_id=os.environ['MOBILE_RELEASES_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['MOBILE_RELEASES_SECRET_ACCESS_KEY'],
        config=Config(
            signature_version='s3v4',
            s3={'addressing_style': 'virtual'},
        ),
    )


class MobileUpdateView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        try:
            installed_version = int(request.query_params.get('version_code', 0))
        except (TypeError, ValueError):
            return Response(
                {'detail': 'version_code must be an integer.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        bucket = os.environ.get('MOBILE_RELEASES_BUCKET')
        if not bucket:
            return Response(
                {'detail': 'Mobile releases are not configured.'},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        try:
            client = _mobile_releases_client()
            manifest_object = client.get_object(
                Bucket=bucket,
                Key='android/latest.json',
            )
            manifest = json.loads(manifest_object['Body'].read())
            latest_version = int(manifest['versionCode'])
            object_key = manifest['objectKey']

            if not isinstance(object_key, str) or not object_key.startswith('android/'):
                raise ValueError('Invalid Android release object key')

            if latest_version <= installed_version:
                return Response({'updateAvailable': False})

            download_url = client.generate_presigned_url(
                'get_object',
                Params={'Bucket': bucket, 'Key': object_key},
                ExpiresIn=900,
            )
            return Response({
                'updateAvailable': True,
                'mandatory': bool(manifest.get('mandatory', False)),
                'versionCode': latest_version,
                'versionName': str(manifest['versionName']),
                'releaseNotes': str(manifest.get('releaseNotes', '')),
                'downloadUrl': download_url,
                'sha256': str(manifest['sha256']),
            })
        except Exception:
            logger.exception('Unable to read the latest mobile release')
            return Response(
                {'detail': 'Unable to check for an app update.'},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

# Try to import Cloudinary — gracefully degrade if not configured
try:
    import cloudinary
    import cloudinary.uploader
except ImportError:
    cloudinary = None


class BugReportListCreateView(generics.ListCreateAPIView):
    serializer_class = BugReportSerializer
    parser_classes = (MultiPartParser, FormParser)

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('support.create')]
        return [HasAccess('support.manage')]

    def get_queryset(self):
        return BugReport.objects.all()

    def perform_create(self, serializer):
        # ── Upload screenshot to Cloudinary if provided ──────────────
        screenshot_url = None
        screenshot_public_id = None
        screenshot_file = self.request.FILES.get('screenshot')

        if screenshot_file and cloudinary:
            try:
                upload_result = cloudinary.uploader.upload(
                    screenshot_file,
                    folder='bug_reports/screenshots',
                    resource_type='image',
                )
                screenshot_url = upload_result.get('secure_url')
                screenshot_public_id = upload_result.get('public_id')
                logger.info(f"Bug report screenshot uploaded to Cloudinary: {screenshot_public_id}")
            except Exception as e:
                logger.warning(f"Cloudinary upload failed, continuing without screenshot: {e}")
        elif screenshot_file and not cloudinary:
            logger.warning("Cloudinary not configured — screenshot will not be stored.")

        bug_report = serializer.save(
            user=self.request.user,
            screenshot_url=screenshot_url,
            screenshot_public_id=screenshot_public_id,
        )

        from django.utils.html import escape

        # ── Send email notification ───────────────────────────────────
        try:
            target_email = getattr(settings, 'SUPPORT_EMAIL', 'admin@example.com')

            safe_username = escape(bug_report.user.username)
            safe_email = escape(bug_report.user.email)
            safe_message = escape(bug_report.message)

            subject = f"New Bug Report: #{bug_report.id} from {safe_username}"
            html_content = f"""
            <html>
                <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
                    <div style="background-color: #f8f9fa; border-radius: 8px; padding: 20px; border: 1px solid #e9ecef;">
                        <h2 style="color: #dc3545; margin-top: 0; border-bottom: 2px solid #dc3545; padding-bottom: 10px;">New Bug Report </h2>

                        <div style="margin-bottom: 20px;">
                            <p style="margin: 0 0 10px 0;"><strong>Report ID:</strong> #{bug_report.id}</p>
                            <p style="margin: 0 0 10px 0;"><strong>User:</strong> {safe_username} ({safe_email})</p>
                            <p style="margin: 0 0 10px 0;"><strong>Status:</strong> <span style="background-color: #ffc107; color: #000; padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: bold;">{bug_report.get_status_display()}</span></p>
                        </div>

                        <div style="background-color: #ffffff; padding: 15px; border-radius: 6px; border: 1px solid #dee2e6; margin-bottom: 20px;">
                            <h3 style="margin-top: 0; color: #495057; font-size: 16px;">Issue Description:</h3>
                            <p style="white-space: pre-wrap; margin-bottom: 0;">{safe_message}</p>
                        </div>

                        {f'<p><strong>Screenshot:</strong> <a href="{bug_report.screenshot_url}">View Screenshot</a></p>' if bug_report.screenshot_url else ''}

                        <p style="font-size: 14px; color: #6c757d; margin-bottom: 0;">Please check the admin dashboard for more details.</p>
                    </div>
                </body>
            </html>
            """

            body = f"""
A new bug/issue has been reported.

User: {bug_report.user.username} ({bug_report.user.email})
Status: {bug_report.get_status_display()}
Message:
{bug_report.message}
{f"Screenshot: {bug_report.screenshot_url}" if bug_report.screenshot_url else ""}

Please check the admin dashboard for more details.
"""

            from django.core.mail import EmailMultiAlternatives

            email = EmailMultiAlternatives(
                subject=subject,
                body=body,
                from_email=settings.DEFAULT_FROM_EMAIL,
                to=[target_email],
            )
            email.attach_alternative(html_content, "text/html")
            email.send(fail_silently=False)

        except Exception:
            # The report is the source of truth. Notification delivery is
            # best-effort and must not make a successfully saved report fail.
            logger.exception("Failed to send bug report email for report %s", bug_report.id)



