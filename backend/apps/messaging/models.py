import uuid
from django.db import models
from django.conf import settings
from django.db.models.signals import post_delete
from django.dispatch import receiver
from common.file_storage import delete_stored_file, stored_file_url


class Conversation(models.Model):
    """
    Represents a chat (one-to-one or group).
    """
    class Type(models.TextChoices):
        DIRECT = 'direct', 'Direct Message'
        GROUP = 'group', 'Group Chat'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    type = models.CharField(max_length=10, choices=Type.choices)

    # For direct messages: exactly 2 participants
    # For groups: 2+ participants
    participants = models.ManyToManyField('users.User', related_name='conversations')
    past_participants = models.ManyToManyField('users.User', related_name='past_conversations', blank=True)

    # Group chat specific fields
    name = models.CharField(max_length=100, blank=True)  # Group name
    description = models.TextField(blank=True)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        related_name='created_conversations'
    )

    # Group admin (can remove members, change name/description)
    admin = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='administered_groups'
    )

    # Metadata
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)  # Last message time

    # For filtering conversations by plant/organization (optional grouping)
    plant = models.ForeignKey(
        'machines.Plant',
        on_delete=models.SET_NULL,
        null=True,
        blank=True
    )

    # Pinned messages (max 3, like Instagram)
    pinned_messages = models.ManyToManyField(
        'Message',
        blank=True,
        related_name='pinned_in_conversations',
        symmetrical=False,
    )

    class Meta:
        db_table = 'conversations'
        ordering = ['-updated_at']
        indexes = [
            models.Index(fields=['-updated_at']),  # Fast conversation list sorting
        ]

    def __str__(self):
        if self.type == self.Type.GROUP:
            return f"Group: {self.name or 'Unnamed'}"
        return f"Direct conversation {self.id}"


class Message(models.Model):
    """
    Individual message within a conversation.
    """
    class MessageType(models.TextChoices):
        TEXT = 'text', 'Text'
        FILE = 'file', 'File Attachment'
        IMAGE = 'image', 'Image'
        MEETING = 'meeting', 'Meeting Invitation'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conversation = models.ForeignKey(
        Conversation,
        on_delete=models.CASCADE,
        related_name='messages'
    )
    sender = models.ForeignKey(
        'users.User',
        on_delete=models.CASCADE,
        related_name='sent_messages'
    )

    # Message content
    content = models.TextField()  # Text message
    message_type = models.CharField(
        max_length=10,
        choices=MessageType.choices,
        default=MessageType.TEXT
    )

    # For meeting invitations
    meeting_link = models.URLField(blank=True, null=True)  # Google Meet link
    meeting_scheduled_at = models.DateTimeField(blank=True, null=True)

    # Reply/threading support
    reply_to = models.ForeignKey(
        'self',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='replies'
    )

    # Metadata
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    edited_at = models.DateTimeField(null=True, blank=True)
    is_deleted = models.BooleanField(default=False)

    class Meta:
        db_table = 'messages'
        ordering = ['created_at']
        indexes = [
            models.Index(fields=['conversation', '-created_at']),
        ]

    def __str__(self):
        return f"Message from {self.sender.email} at {self.created_at}"


class MessageAttachment(models.Model):
    """
    File attachments for messages.
    Hybrid storage: images in private media storage, documents in PostgreSQL.
    """
    class AttachmentType(models.TextChoices):
        IMAGE = 'image', 'Image'
        DOCUMENT = 'document', 'Document'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    message = models.ForeignKey(
        Message,
        on_delete=models.CASCADE,
        related_name='attachments'
    )

    # File metadata
    file_name = models.CharField(max_length=255)
    file_size = models.PositiveIntegerField()  # in bytes
    file_type = models.CharField(max_length=100)  # MIME type
    attachment_type = models.CharField(
        max_length=10,
        choices=AttachmentType.choices
    )

    # Compatibility columns: cloudinary_public_id stores the media object key;
    # cloudinary_url is a fallback for older records and API compatibility.
    cloudinary_url = models.URLField(blank=True, null=True)
    cloudinary_public_id = models.CharField(max_length=255, blank=True, null=True)

    # For documents: PostgreSQL BLOB
    file_data = models.BinaryField(blank=True, null=True)

    # Thumbnail (Cloudinary auto-generates for images)
    thumbnail_url = models.URLField(blank=True, null=True)

    uploaded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'message_attachments'

    def __str__(self):
        return f"Attachment: {self.file_name}"

    @property
    def delivery_url(self):
        return stored_file_url(self.cloudinary_public_id, self.cloudinary_url)

    @property
    def thumbnail_delivery_url(self):
        return stored_file_url(self.cloudinary_public_id, self.thumbnail_url or self.cloudinary_url)


@receiver(post_delete, sender=MessageAttachment)
def delete_message_attachment_file(sender, instance, **kwargs):
    if (
        instance.attachment_type == MessageAttachment.AttachmentType.IMAGE
        and instance.cloudinary_public_id
        and not MessageAttachment.objects.filter(
            cloudinary_public_id=instance.cloudinary_public_id
        ).exists()
    ):
        delete_stored_file(instance.cloudinary_public_id)


class MessageRead(models.Model):
    """
    Track read receipts (when a user has read a message).
    """
    message = models.ForeignKey(
        Message,
        on_delete=models.CASCADE,
        related_name='read_by'
    )
    user = models.ForeignKey('users.User', on_delete=models.CASCADE)
    read_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'message_reads'
        unique_together = [['message', 'user']]
        indexes = [
            models.Index(fields=['user', 'message']),
        ]

    def __str__(self):
        return f"{self.user.email} read message {self.message.id} at {self.read_at}"


class MessageReaction(models.Model):
    """
    Track emoji reactions to messages.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    message = models.ForeignKey(
        Message,
        on_delete=models.CASCADE,
        related_name='reactions'
    )
    user = models.ForeignKey('users.User', on_delete=models.CASCADE)
    emoji = models.CharField(max_length=10)  # Unicode emoji
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'message_reactions'
        unique_together = [['message', 'user', 'emoji']]
        indexes = [
            models.Index(fields=['message']),
        ]

    def __str__(self):
        return f"{self.user.email} reacted {self.emoji} to message {self.message.id}"


class ConversationClearHistory(models.Model):
    """
    Track when a user clears history for a conversation.
    """
    user = models.ForeignKey('users.User', on_delete=models.CASCADE, related_name='cleared_conversations')
    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name='cleared_history')
    cleared_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'conversation_clear_history'
        unique_together = [['user', 'conversation']]

    def __str__(self):
        return f"{self.user.email} cleared {self.conversation.id} at {self.cleared_at}"
