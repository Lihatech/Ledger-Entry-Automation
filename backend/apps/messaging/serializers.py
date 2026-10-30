from rest_framework import serializers
from django.contrib.auth import get_user_model
from apps.messaging.models import Conversation, Message, MessageAttachment, MessageRead, MessageReaction

User = get_user_model()


class UserBasicSerializer(serializers.ModelSerializer):
    """Basic user info for messaging context."""
    class Meta:
        model = User
        fields = ['id', 'email', 'first_name', 'last_name', 'role', 'profile_photo']
        read_only_fields = fields


class MessageAttachmentSerializer(serializers.ModelSerializer):
    """Serializer for message attachments."""
    class Meta:
        model = MessageAttachment
        fields = [
            'id', 'file_name', 'file_size', 'file_type',
            'attachment_type', 'cloudinary_url', 'thumbnail_url',
            'uploaded_at'
        ]
        read_only_fields = ['id', 'uploaded_at']


class MessageReadSerializer(serializers.ModelSerializer):
    """Serializer for message read receipts."""
    user = UserBasicSerializer(read_only=True)

    class Meta:
        model = MessageRead
        fields = ['user', 'read_at']
        read_only_fields = fields


class MessageReactionSerializer(serializers.ModelSerializer):
    """Serializer for message reactions."""
    user = UserBasicSerializer(read_only=True)

    class Meta:
        model = MessageReaction
        fields = ['id', 'user', 'emoji', 'created_at']
        read_only_fields = ['id', 'user', 'created_at']


class MessageSerializer(serializers.ModelSerializer):
    """Serializer for messages with attachments and read status."""
    sender = UserBasicSerializer(read_only=True)
    attachments = MessageAttachmentSerializer(many=True, read_only=True)
    read_by = MessageReadSerializer(many=True, read_only=True)
    reactions = MessageReactionSerializer(many=True, read_only=True)
    reply_to_message = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = [
            'id', 'conversation', 'sender', 'content', 'message_type',
            'meeting_link', 'meeting_scheduled_at', 'reply_to',
            'reply_to_message', 'attachments', 'read_by', 'reactions',
            'created_at', 'edited_at', 'is_deleted'
        ]
        read_only_fields = ['id', 'sender', 'conversation', 'created_at', 'edited_at']

    def get_reply_to_message(self, obj):
        """Get basic info of the message being replied to."""
        if obj.reply_to:
            return {
                'id': str(obj.reply_to.id),
                'sender': UserBasicSerializer(obj.reply_to.sender).data,
                'content': obj.reply_to.content[:100],  # First 100 chars
                'created_at': obj.reply_to.created_at,
            }
        return None

    def create(self, validated_data):
        """Create message with current user as sender."""
        validated_data['sender'] = self.context['request'].user
        return super().create(validated_data)


class ConversationSerializer(serializers.ModelSerializer):
    """Serializer for conversations with participants and last message."""
    participants = UserBasicSerializer(many=True, read_only=True)
    participant_ids = serializers.ListField(
        child=serializers.IntegerField(),
        write_only=True,
        required=False
    )
    created_by = UserBasicSerializer(read_only=True)
    admin = UserBasicSerializer(read_only=True)
    last_message = serializers.SerializerMethodField()
    unread_count = serializers.SerializerMethodField()
    pinned_messages = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            'id', 'type', 'name', 'description', 'participants',
            'participant_ids', 'created_by', 'admin', 'plant',
            'last_message', 'unread_count', 'pinned_messages', 'created_at', 'updated_at'
        ]
        read_only_fields = ['id', 'created_by', 'created_at', 'updated_at']

    def _get_clear_history(self, obj):
        """Helper to fetch and memoize clear history per conversation."""
        if not hasattr(self, '_clear_histories'):
            self._clear_histories = {}
        if obj.id not in self._clear_histories:
            from apps.messaging.models import ConversationClearHistory
            user = self.context['request'].user
            self._clear_histories[obj.id] = ConversationClearHistory.objects.filter(
                user=user, conversation=obj
            ).first()
        return self._clear_histories[obj.id]

    def get_last_message(self, obj):
        """Get the last message in the conversation."""
        clear_history = self._get_clear_history(obj)
        prefetched = getattr(obj, 'prefetched_recent_messages', None)
        if prefetched is not None and not clear_history:
            last_message = prefetched[0] if prefetched else None
        else:
            queryset = obj.messages.filter(is_deleted=False)
            if clear_history:
                queryset = queryset.filter(created_at__gt=clear_history.cleared_at)
            last_message = queryset.order_by('-created_at').first()
        if last_message:
            return {
                'id': str(last_message.id),
                'sender': UserBasicSerializer(last_message.sender).data,
                'content': last_message.content[:100],  # Preview
                'message_type': last_message.message_type,
                'created_at': last_message.created_at,
            }
        return None

    def get_unread_count(self, obj):
        """Get unread message count for current user."""
        user = self.context['request'].user
        queryset = obj.messages.filter(is_deleted=False)
        
        clear_history = self._get_clear_history(obj)
        
        if clear_history:
            queryset = queryset.filter(created_at__gt=clear_history.cleared_at)
            
        # Messages in this conversation not read by current user
        unread = queryset.exclude(
            read_by__user=user
        ).exclude(sender=user).count()
        return unread

    def get_pinned_messages(self, obj):
        """Get pinned messages with basic info for the banner."""
        queryset = obj.pinned_messages.filter(is_deleted=False)
        
        clear_history = self._get_clear_history(obj)
        
        if clear_history:
            queryset = queryset.filter(created_at__gt=clear_history.cleared_at)
            
        pinned = queryset.order_by('created_at')
        return [
            {
                'id': str(msg.id),
                'content': msg.content[:120],
                'message_type': msg.message_type,
                'sender': UserBasicSerializer(msg.sender).data,
                'created_at': msg.created_at,
            }
            for msg in pinned
        ]

    def create(self, validated_data):
        """Create conversation with participants."""
        participant_ids = validated_data.pop('participant_ids', [])
        current_user = self.context['request'].user

        # Set created_by and admin
        validated_data['created_by'] = current_user
        if validated_data.get('type') == Conversation.Type.GROUP:
            validated_data['admin'] = current_user

        conversation = super().create(validated_data)

        # Add participants
        if participant_ids:
            conversation.participants.set(participant_ids)

        # Always include the creator
        conversation.participants.add(current_user)

        return conversation

    def update(self, instance, validated_data):
        """Update conversation (admin-only fields checked in view)."""
        participant_ids = validated_data.pop('participant_ids', None)

        conversation = super().update(instance, validated_data)

        if participant_ids is not None:
            current_participants = set(conversation.participants.values_list('id', flat=True))
            new_participants = set(participant_ids)
            removed_ids = current_participants - new_participants
            
            conversation.participants.set(participant_ids)
            
            if removed_ids:
                conversation.past_participants.add(*removed_ids)

        return conversation


class ConversationDetailSerializer(ConversationSerializer):
    """Detailed conversation serializer with recent messages."""
    recent_messages = serializers.SerializerMethodField()

    class Meta(ConversationSerializer.Meta):
        fields = ConversationSerializer.Meta.fields + ['recent_messages']

    def get_recent_messages(self, obj):
        """Get the 50 most recent messages."""
        queryset = obj.messages.filter(is_deleted=False)
        clear_history = self._get_clear_history(obj)
        
        if clear_history:
            queryset = queryset.filter(created_at__gt=clear_history.cleared_at)
            
        messages = queryset.order_by('-created_at')[:50]
        return MessageSerializer(messages, many=True, context=self.context).data


class UserSearchSerializer(serializers.ModelSerializer):
    """Serializer for user search results."""
    plant_name = serializers.CharField(source='plant.name', read_only=True)

    class Meta:
        model = User
        fields = [
            'id', 'email', 'first_name', 'last_name', 'role',
            'profile_photo', 'plant', 'plant_name'
        ]
        read_only_fields = fields
