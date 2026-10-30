import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError

from apps.messaging.models import Conversation, Message, MessageRead
from apps.messaging.serializers import MessageSerializer

User = get_user_model()


class MessagingConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for real-time messaging.
    Handles message sending, typing indicators, and read receipts.
    """

    async def connect(self):
        """Accept WebSocket connection after authentication."""
        self.conversation_id = self.scope['url_route']['kwargs']['conversation_id']
        self.room_group_name = f'messaging_{self.conversation_id}'
        self.user = None

        await self.accept()
        self.authenticated = False

    async def disconnect(self, close_code):
        """Leave room group on disconnect."""
        if hasattr(self, 'room_group_name'):
            await self.channel_layer.group_discard(
                self.room_group_name,
                self.channel_name
            )

    async def receive(self, text_data):
        """Receive message from WebSocket and handle different actions."""
        if not self.authenticated:
            if not await self.authenticate(text_data):
                await self.close(code=4001)
            return

        # Enforce active-participant authorization for every action
        is_participant = await self.verify_participant()
        if not is_participant:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': 'You are no longer an active participant in this conversation'
            }))
            await self.close(code=4003)
            return

        try:
            data = json.loads(text_data)
            action = data.get('action')

            if action == 'send_message':
                await self.handle_send_message(data.get('data', {}))
            elif action == 'mark_read':
                await self.handle_mark_read(data.get('data', {}))
            elif action == 'typing':
                await self.handle_typing(data.get('data', {}))
            else:
                await self.send(text_data=json.dumps({
                    'type': 'error',
                    'message': f'Unknown action: {action}'
                }))

        except json.JSONDecodeError:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': 'Invalid JSON'
            }))
        except Exception as e:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': str(e)
            }))

    async def authenticate(self, text_data):
        """Authenticate using the first WebSocket message, never the URL."""
        try:
            data = json.loads(text_data)
            if data.get('action') != 'auth' or not data.get('token'):
                return False
            access_token = AccessToken(data['token'])
            self.user = await self.get_user(access_token['user_id'])
            if not self.user or not await self.verify_participant():
                return False
        except (json.JSONDecodeError, TokenError, KeyError, TypeError):
            return False

        await self.channel_layer.group_add(self.room_group_name, self.channel_name)
        self.authenticated = True
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': f'Connected to conversation {self.conversation_id}'
        }))
        return True

    async def handle_send_message(self, data):
        """Handle sending a new message."""
        content = data.get('content', '').strip()
        message_type = data.get('message_type', 'text')
        reply_to_id = data.get('reply_to')

        if not content and message_type == 'text':
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': 'Message content cannot be empty'
            }))
            return

        # Create message in database
        message = await self.create_message(
            content=content,
            message_type=message_type,
            reply_to_id=reply_to_id
        )

        if not message:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': 'Failed to create message'
            }))
            return

        # Serialize message
        message_data = await self.serialize_message(message)

        # Send confirmation back to sender with message ID
        await self.send(text_data=json.dumps({
            'type': 'message_sent',
            'data': message_data
        }))

        # Broadcast to room group (for OTHER users viewing this conversation)
        # Note: Sender already received the message via 'message_sent' above
        await self.channel_layer.group_send(
            self.room_group_name,
            {
                'type': 'new_message',
                'message': message_data,
                'sender_id': self.user.id  # Pass sender ID to exclude them
            }
        )

        # Notify all conversation participants (for real-time updates in conversation list)
        participant_ids = await self.get_conversation_participants()
        for participant_id in participant_ids:
            await self.channel_layer.group_send(
                f'user_notifications_{participant_id}',
                {
                    'type': 'new_message_notification',
                    'data': {
                        'conversation_id': self.conversation_id,
                        'message': message_data
                    }
                }
            )

    async def handle_mark_read(self, data):
        """Handle marking a message as read."""
        message_id = data.get('message_id')

        if not message_id:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': 'message_id is required'
            }))
            return

        # Mark message as read
        read_receipt = await self.mark_message_read(message_id)

        if read_receipt:
            # Broadcast read receipt to room group (wrapped in 'data' key for client compatibility)
            await self.channel_layer.group_send(
                self.room_group_name,
                {
                    'type': 'message_read',
                    'data': {
                        'message_id': message_id,
                        'read_by': {
                            'id': self.user.id,
                            'email': self.user.email,
                            'first_name': self.user.first_name,
                            'last_name': self.user.last_name,
                        },
                        'read_at': read_receipt['read_at']
                    }
                }
            )

    async def handle_typing(self, data):
        """Handle typing indicator."""
        is_typing = data.get('is_typing', False)

        # Broadcast typing indicator to room group
        await self.channel_layer.group_send(
            self.room_group_name,
            {
                'type': 'user_typing',
                'user': {
                    'id': self.user.id,
                    'email': self.user.email,
                    'first_name': self.user.first_name,
                    'last_name': self.user.last_name,
                },
                'is_typing': is_typing
            }
        )

    async def new_message(self, event):
        """Send new message to WebSocket (exclude sender - they already got message_sent)."""
        sender_id = event.get('sender_id')

        # Don't send to the sender - they already received it via message_sent
        if sender_id and sender_id == self.user.id:
            return

        await self.send(text_data=json.dumps({
            'type': 'new_message',
            'data': event['message']
        }))

    async def message_read(self, event):
        """Send read receipt to WebSocket."""
        await self.send(text_data=json.dumps({
            'type': 'message_read',
            'data': event['data']
        }))

    async def user_typing(self, event):
        """Send typing indicator to WebSocket (exclude sender)."""
        # Don't send typing indicator to the user who is typing
        if event['user']['id'] != self.user.id:
            await self.send(text_data=json.dumps({
                'type': 'user_typing',
                'data': {
                    'user': event['user'],
                    'is_typing': event['is_typing']
                }
            }))

    async def message_deleted(self, event):
        """Send message deletion notification to WebSocket."""
        await self.send(text_data=json.dumps({
            'type': 'message_deleted',
            'data': event['data']
        }))

    async def message_reaction(self, event):
        """Send reaction update to WebSocket clients."""
        await self.send(text_data=json.dumps({
            'type': 'message_reaction',
            'data': event['data']
        }))

    # Database operations (sync_to_async wrappers)

    @database_sync_to_async
    def get_user(self, user_id):
        """Get user by ID."""
        try:
            return User.objects.get(id=user_id)
        except User.DoesNotExist:
            return None

    @database_sync_to_async
    def verify_participant(self):
        """Verify user is a participant in the conversation."""
        try:
            conversation = Conversation.objects.get(id=self.conversation_id)
            return conversation.participants.filter(id=self.user.id).exists()
        except Conversation.DoesNotExist:
            return False

    @database_sync_to_async
    def create_message(self, content, message_type, reply_to_id=None):
        """Create a new message in the database."""
        try:
            conversation = Conversation.objects.get(id=self.conversation_id)

            # Get reply_to message if provided
            reply_to = None
            if reply_to_id:
                try:
                    reply_to = Message.objects.get(id=reply_to_id)
                except Message.DoesNotExist:
                    pass

            message = Message.objects.create(
                conversation=conversation,
                sender=self.user,
                content=content,
                message_type=message_type,
                reply_to=reply_to
            )

            # Update conversation timestamp
            from django.utils import timezone
            conversation.updated_at = timezone.now()
            conversation.save(update_fields=['updated_at'])

            return message

        except Exception as e:
            print(f"Error creating message: {e}")
            return None

    @database_sync_to_async
    def serialize_message(self, message):
        """Serialize message for WebSocket transmission."""
        from rest_framework.request import Request
        from django.http import HttpRequest
        import uuid
        from datetime import datetime

        # Create a mock request for serializer context
        request = HttpRequest()
        request.user = self.user
        drf_request = Request(request)

        serializer = MessageSerializer(message, context={'request': drf_request})
        data = serializer.data

        # Convert to plain Python dict with JSON-safe types
        def make_json_safe(obj):
            if isinstance(obj, dict):
                return {k: make_json_safe(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [make_json_safe(i) for i in obj]
            elif isinstance(obj, uuid.UUID):
                return str(obj)
            elif isinstance(obj, datetime):
                return obj.isoformat()
            elif hasattr(obj, 'isoformat'):  # date, time objects
                return obj.isoformat()
            return obj

        return make_json_safe(dict(data))

    @database_sync_to_async
    def mark_message_read(self, message_id):
        """Mark a message as read by the current user."""
        try:
            message = Message.objects.get(id=message_id)

            # Verify message belongs to this conversation (prevent cross-conversation reads)
            if str(message.conversation_id) != str(self.conversation_id):
                return None

            # Don't mark own messages as read
            if message.sender == self.user:
                return None

            read_receipt, created = MessageRead.objects.get_or_create(
                message=message,
                user=self.user
            )

            return {
                'read_at': read_receipt.read_at.isoformat()
            }

        except Message.DoesNotExist:
            return None

    @database_sync_to_async
    def get_conversation_participants(self):
        """Get all participant IDs for the current conversation."""
        try:
            conversation = Conversation.objects.get(id=self.conversation_id)
            return list(conversation.participants.values_list('id', flat=True))
        except Conversation.DoesNotExist:
            return []
