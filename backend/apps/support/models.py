from django.db import models
from django.db.models.signals import post_delete
from django.dispatch import receiver
from django.conf import settings
from common.file_storage import delete_stored_file, stored_file_url

class BugReport(models.Model):
    STATUS_CHOICES = (
        ('open', 'Open'),
        ('in_progress', 'In Progress'),
        ('resolved', 'Resolved'),
    )

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='bug_reports')
    message = models.TextField()
    # Compatibility columns: screenshot_public_id stores the S3 object key and
    # screenshot_url remains as a fallback for records created before S3.
    screenshot_url = models.URLField(blank=True, null=True)
    screenshot_public_id = models.CharField(max_length=255, blank=True, null=True)
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='open')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'bug_reports'
        ordering = ['-created_at']

    def __str__(self):
        return f"BugReport #{self.id} from {self.user.username}"

    @property
    def screenshot_delivery_url(self):
        return stored_file_url(self.screenshot_public_id, self.screenshot_url)


@receiver(post_delete, sender=BugReport)
def delete_bug_report_screenshot(sender, instance, **kwargs):
    delete_stored_file(instance.screenshot_public_id)
