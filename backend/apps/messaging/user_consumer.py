import asyncio
import json
from urllib.parse import parse_qs
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
        self.authenticated = False

        await self.accept()
        query_token = self._query_token()
        if query_token:
            if not await self.authenticate_token(query_token):
                await self.close(code=4001)
                return
        else:
            self.auth_timeout_task = asyncio.create_task(self._auth_timeout())

    async def disconnect(self, close_code):
        """Leave notification group on disconnect."""
        self._cancel_auth_timeout()
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
                if not await self.authenticate_token(data['token']):
                    await self.close(code=4001)
                    return
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

    async def authenticate_token(self, token):
        try:
            access_token = AccessToken(token)
            self.user = await self.get_user(access_token['user_id'])
        except (TokenError, KeyError, TypeError):
            self.user = None
        if not self.user:
            return False

        self.user_group_name = f'user_notifications_{self.user.id}'
        await self.channel_layer.group_add(self.user_group_name, self.channel_name)
        self.authenticated = True
        self._cancel_auth_timeout()
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': f'Connected to user notifications for user {self.user.id}'
        }))
        return True

    def _query_token(self):
        query_string = self.scope.get('query_string', b'').decode('utf-8')
        return parse_qs(query_string).get('token', [None])[0]

    async def _auth_timeout(self):
        await asyncio.sleep(10)
        if not self.authenticated:
            await self.close(code=4001)

    def _cancel_auth_timeout(self):
        task = getattr(self, 'auth_timeout_task', None)
        if task and task is not asyncio.current_task() and not task.done():
            task.cancel()

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
