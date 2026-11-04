from rest_framework import serializers
from .models import BugReport

class BugReportSerializer(serializers.ModelSerializer):
    user = serializers.ReadOnlyField(source='user.username')
    user_email = serializers.ReadOnlyField(source='user.email')
    screenshot = serializers.SerializerMethodField()

    def get_screenshot(self, obj):
        return obj.screenshot_delivery_url

    class Meta:
        model = BugReport
        fields = ['id', 'user', 'user_email', 'message', 'screenshot', 'status', 'created_at']
        read_only_fields = ['id', 'status', 'created_at']

