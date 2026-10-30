import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError

User = get_user_model()


class UserNotificationConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for user-level messaging notifications.
    Notifies user of new messages across ALL their conversations in real-time.
    """

    async def connect(self):
        """Accept WebSocket connection after authentication."""
        self.user = None

        await self.accept()
        self.authenticated = False

    async def disconnect(self, close_code):
        """Leave notification group on disconnect."""
        if hasattr(self, 'user_group_name'):
            await self.channel_layer.group_discard(
                self.user_group_name,
                self.channel_name
            )

    async def receive(self, text_data):
        """Handle ping/pong to keep connection alive."""
        try:
            data = json.loads(text_data)
            if not self.authenticated:
                if data.get('action') != 'auth' or not data.get('token'):
                    await self.close(code=4001)
                    return
                access_token = AccessToken(data['token'])
                self.user = await self.get_user(access_token['user_id'])
                if not self.user:
                    await self.close(code=4001)
                    return
                self.user_group_name = f'user_notifications_{self.user.id}'
                await self.channel_layer.group_add(self.user_group_name, self.channel_name)
                self.authenticated = True
                await self.send(text_data=json.dumps({
                    'type': 'connection_established',
                    'message': f'Connected to user notifications for user {self.user.id}'
                }))
                return
            action = data.get('action')

            if action == 'ping':
                await self.send(text_data=json.dumps({
                    'type': 'pong'
                }))
            else:
                await self.send(text_data=json.dumps({
                    'type': 'error',
                    'message': f'Unknown action: {action}'
                }))

        except (json.JSONDecodeError, TokenError, KeyError, TypeError):
            await self.close(code=4001)

    async def new_message_notification(self, event):
        """Send new message notification to user."""
        await self.send(text_data=json.dumps({
            'type': 'new_message_notification',
            'data': event['data']
        }))

    async def conversation_updated(self, event):
        """Send conversation update notification to user."""
        await self.send(text_data=json.dumps({
            'type': 'conversation_updated',
            'data': event['data']
        }))

    @database_sync_to_async
    def get_user(self, user_id):
        """Get user by ID."""
        try:
            return User.objects.get(id=user_id)
        except User.DoesNotExist:
            return None
