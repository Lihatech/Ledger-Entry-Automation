from rest_framework import viewsets, permissions, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from django.db.models import Q
from django.core.mail import send_mail
from django.conf import settings
import threading
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from .models import Task, TaskAttachment
from .serializers import TaskSerializer, TaskCreateSerializer, TaskCompleteSerializer
from apps.users.permissions import HasAccess

class TaskViewSet(viewsets.ModelViewSet):
    serializer_class = TaskSerializer
    permission_classes = [HasAccess]
    access_key = 'tasks.view'
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def get_permissions(self):
        key = 'tasks.allocate' if self.action in ('create', 'update', 'partial_update', 'destroy', 'resolve_issue') else 'tasks.view'
        return [HasAccess(key)]

    def perform_update(self, serializer):
        if serializer.instance.allocated_by != self.request.user and not self.request.user.has_access('tasks.manage_all'):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only the allocator can change this task.')
        serializer.save()

    def perform_destroy(self, instance):
        if instance.allocated_by != self.request.user and not self.request.user.has_access('tasks.manage_all'):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only the allocator can delete this task.')
        instance.delete()

    def get_queryset(self):
        user = self.request.user
        if user.has_access('tasks.view_all'):
            return Task.objects.all()
        # For non-admins, return tasks they allocated or tasks allocated to them
        return Task.objects.filter(Q(allocated_by=user) | Q(allocated_to=user)).distinct()

    def create(self, request, *args, **kwargs):
        user = request.user
        if not user.has_access('tasks.allocate'):
            return Response({"detail": "Task allocation access required."}, status=status.HTTP_403_FORBIDDEN)
        
        serializer = TaskCreateSerializer(data=request.data)
        if serializer.is_valid():
            task = serializer.save(allocated_by=user)

            # Keep task assignments in the same global notification stream as
            # document-control notifications. The WebSocket event makes the
            # notification appear immediately; the database row preserves it
            # for users who were offline when the task was assigned.
            from apps.document_control.models import DCRNotification

            notification = DCRNotification.objects.create(
                recipient=task.allocated_to,
                title='New task assigned',
                message=f"{task.title} was assigned to you by {user.get_full_name() or user.username}.",
                action_type=DCRNotification.ActionType.GENERAL,
                action_url='/tasks',
            )
            channel_layer = get_channel_layer()
            if channel_layer is not None:
                async_to_sync(channel_layer.group_send)(
                    f'user_notifications_{task.allocated_to_id}',
                    {
                        'type': 'task_assigned_notification',
                        'data': {
                            'id': notification.id,
                            'title': notification.title,
                            'message': notification.message,
                            'action_type': notification.action_type,
                            'action_url': notification.action_url,
                            'is_read': notification.is_read,
                            'created_at': notification.created_at.isoformat(),
                        },
                    },
                )
            
            # Send email notification in background
            if task.allocated_to and task.allocated_to.email:
                def send_task_email():
                    from django.utils.html import escape
                    safe_title = escape(task.title)
                    safe_description = escape(task.description)
                    
                    subject = f"New Task Allocated: {task.title}"
                    message = f"Hi {task.allocated_to.first_name or 'User'},\n\nA new task '{task.title}' has been assigned to you by {user.first_name} {user.last_name}.\n\nDescription: {task.description}\nDeadline: {task.deadline}"
                    html_message = f"""
                    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden;">
                        <div style="background-color: #2563eb; padding: 24px; text-align: center;">
                            <h1 style="color: white; margin: 0; font-size: 24px; font-weight: 600;">New Task Allocated</h1>
                        </div>
                        <div style="padding: 32px 24px; background-color: #ffffff; color: #374151;">
                            <p style="font-size: 16px; margin-top: 0;">Hi <strong>{task.allocated_to.first_name or 'User'}</strong>,</p>
                            <p style="font-size: 16px; line-height: 1.5; margin-bottom: 24px;">
                                A new task has been assigned to you by <strong>{user.first_name} {user.last_name}</strong>.
                            </p>
                            <div style="background-color: #f3f4f6; padding: 16px; border-radius: 6px; margin-bottom: 24px;">
                                <h3 style="margin-top: 0; color: #111827;">{safe_title}</h3>
                                <p style="font-size: 14px; margin-bottom: 8px;"><strong>Description:</strong> {safe_description}</p>
                                <p style="font-size: 14px; margin-bottom: 0; color: #dc2626;"><strong>Deadline:</strong> {task.deadline}</p>
                            </div>
                            <p style="font-size: 14px; color: #6b7280; margin-bottom: 0;">
                                Please check your dashboard to accept and manage this task.
                            </p>
                        </div>
                    </div>
                    """
                    from_email = getattr(settings, 'DEFAULT_FROM_EMAIL', 'noreply@example.com')
                    try:
                        send_mail(subject, message, from_email, [task.allocated_to.email], fail_silently=True, html_message=html_message)
                    except Exception:
                        pass
                
                threading.Thread(target=send_task_email).start()

            return Response(TaskSerializer(task).data, status=status.HTTP_201_CREATED)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    @action(detail=True, methods=['post'])
    def accept(self, request, pk=None):
        task = self.get_object()
        if task.allocated_to != request.user:
            return Response({"detail": "You can only accept tasks assigned to you."}, status=status.HTTP_403_FORBIDDEN)
        
        if task.status not in (Task.Status.PENDING,):
            return Response({"detail": "Only pending tasks can be accepted."}, status=status.HTTP_400_BAD_REQUEST)
        
        task.status = Task.Status.ACCEPTED
        task.save()
        return Response(TaskSerializer(task).data)

    @action(detail=True, methods=['post'])
    def complete(self, request, pk=None):
        task = self.get_object()
        if task.allocated_to != request.user:
            return Response({"detail": "You can only complete tasks assigned to you."}, status=status.HTTP_403_FORBIDDEN)

        if task.status not in (Task.Status.ACCEPTED, Task.Status.PENDING):
            return Response({"detail": "Only accepted or pending tasks can be marked as complete."}, status=status.HTTP_400_BAD_REQUEST)

        # Validate uploaded files (optional)
        files = request.FILES.getlist('files')
        if files:
            file_serializer = TaskCompleteSerializer(data={'files': files})
            if not file_serializer.is_valid():
                return Response(file_serializer.errors, status=status.HTTP_400_BAD_REQUEST)

        task.status = Task.Status.COMPLETED
        task.save()

        # Save attachments
        for f in files:
            TaskAttachment.objects.create(
                task=task,
                file=f,
                file_name=f.name,
                content_type=f.content_type,
                file_size=f.size,
                uploaded_by=request.user,
            )

        return Response(TaskSerializer(task, context={'request': request}).data)

    @action(detail=True, methods=['post'])
    def flag_issue(self, request, pk=None):
        task = self.get_object()
        if task.allocated_to != request.user:
            return Response({"detail": "You can only flag issues for tasks assigned to you."}, status=status.HTTP_403_FORBIDDEN)
        
        if task.status in (Task.Status.COMPLETED, Task.Status.CANCELLED):
            return Response({"detail": "Cannot flag an issue on a completed or cancelled task."}, status=status.HTTP_400_BAD_REQUEST)
        
        issue_desc = request.data.get('issue_description')
        if not issue_desc:
            return Response({"detail": "Issue description is required."}, status=status.HTTP_400_BAD_REQUEST)

        task.status = Task.Status.FLAGGED_ISSUE
        task.issue_description = issue_desc
        task.save()
        # Note: WebSocket/Push notification logic can be triggered here.
        return Response(TaskSerializer(task).data)

    @action(detail=True, methods=['post'])
    def resolve_issue(self, request, pk=None):
        task = self.get_object()
        if task.allocated_by != request.user and not request.user.has_access('tasks.manage_all'):
            return Response({"detail": "Only the allocator or admin can resolve this issue."}, status=status.HTTP_403_FORBIDDEN)
        
        if task.status != Task.Status.FLAGGED_ISSUE:
            return Response({"detail": "Task is not flagged with an issue."}, status=status.HTTP_400_BAD_REQUEST)
        
        action_type = request.data.get('action', 'reopen')
        
        if action_type == 'cancel':
            task.status = Task.Status.CANCELLED
            task.issue_description = None
        else:
            task.status = Task.Status.ACCEPTED
            task.issue_description = None
            if action_type == 'extend':
                new_deadline = request.data.get('new_deadline')
                if new_deadline:
                    task.deadline = new_deadline
            
            instructions = request.data.get('instructions')
            if instructions and instructions.strip():
                task.description = f"{task.description}\n\n[Update]: {instructions.strip()}"

        task.save()
        return Response(TaskSerializer(task).data)
