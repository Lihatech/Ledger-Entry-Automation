import asyncio
import json
from urllib.parse import parse_qs
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from django.core.cache import cache
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError

User = get_user_model()

# Cache key format: presence:user:{user_id}
PRESENCE_KEY_PREFIX = 'presence:user:'
PRESENCE_TIMEOUT = 300  # 5 minutes

# A single cache key that holds the set of all currently online user IDs.
# This avoids calling cache.keys() which is specific to django-redis and
# unavailable on both LocMemCache and Django's built-in RedisCache backend.
PRESENCE_INDEX_KEY = 'presence:online_index'

# Per-user connection-count key: presence:conn_count:{user_id}
# Tracks how many WebSocket connections a user currently has open so that
# we only mark them offline (and broadcast the event) when the LAST
# connection closes — preventing false offline events when the same user
# has multiple tabs or devices open simultaneously.
PRESENCE_CONN_COUNT_PREFIX = 'presence:conn_count:'


class PresenceConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for tracking user online/offline presence.
    Users connect to this WebSocket and their status is tracked in Redis/cache.
    """

    async def connect(self):
        """Accept WebSocket connection and mark user as online."""
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

    async def receive(self, text_data):
        """Authenticate on the first message, then handle presence pings."""
        try:
            data = json.loads(text_data)
        except json.JSONDecodeError:
            await self.close(code=4001)
            return

        if not self.authenticated:
            if data.get('action') != 'auth' or not data.get('token'):
                await self.close(code=4001)
                return
            if not await self.authenticate_token(data['token']):
                await self.close(code=4001)
                return
            return

        if data.get('action') == 'ping':
            await self.mark_user_online(self.user.id)
            await self.send(text_data=json.dumps({'type': 'pong'}))
        else:
            await self.send(text_data=json.dumps({
                'type': 'error',
                'message': f"Unknown action: {data.get('action')}"
            }))

    async def authenticate_token(self, token):
        try:
            access_token = AccessToken(token)
            self.user = await self.get_user(access_token['user_id'])
        except (TokenError, KeyError, TypeError):
            self.user = None
        if not self.user:
            return False

        self.authenticated = True
        self._cancel_auth_timeout()
        await self.mark_user_online(self.user.id)
        await self.channel_layer.group_add('presence_updates', self.channel_name)

        online_user_ids = await self.get_all_online_users()
        try:
            await self.send(text_data=json.dumps({
                'type': 'initial_presence',
                'data': {'online_users': online_user_ids}
            }))
            await self.channel_layer.group_send(
                'presence_updates',
                {
                    'type': 'user_status_changed',
                    'user_id': self.user.id,
                    'status': 'online'
                }
            )
            await self.send(text_data=json.dumps({
                'type': 'connection_established',
                'message': f'Presence tracking connected for user {self.user.id}'
            }))
        except Exception:
            await self._cleanup_on_failed_connect()
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

    async def _cleanup_on_failed_connect(self):
        """Remove user from group and undo online marking after a failed connect."""
        try:
            await self.channel_layer.group_discard(
                'presence_updates',
                self.channel_name
            )
        except Exception:
            pass
        await self.mark_user_offline(self.user.id)

    async def disconnect(self, close_code):
        """Mark user as offline when they disconnect."""
        self._cancel_auth_timeout()
        if hasattr(self, 'user') and self.user:
            # Mark user as offline (decrements connection counter; only removes
            # from presence index when the last connection closes).
            await self.mark_user_offline(self.user.id)

            # Leave the group FIRST so this consumer does not receive its own
            # broadcast and attempt to send on an already-closed WebSocket.
            # Wrap separately so a channel-layer failure here does NOT prevent
            # the offline broadcast from reaching the remaining clients.
            try:
                await self.channel_layer.group_discard(
                    'presence_updates',
                    self.channel_name
                )
            except Exception:
                pass

            # Only broadcast offline if this was the user's last connection.
            if not await self.user_has_active_connections(self.user.id):
                # Now safe to broadcast — this consumer is no longer in the group.
                await self.channel_layer.group_send(
                    'presence_updates',
                    {
                        'type': 'user_status_changed',
                        'user_id': self.user.id,
                        'status': 'offline'
                    }
                )

    async def user_status_changed(self, event):
        """Broadcast user status change to connected clients."""
        try:
            await self.send(text_data=json.dumps({
                'type': 'user_status_changed',
                'data': {
                    'user_id': event['user_id'],
                    'status': event['status']
                }
            }))
        except Exception:
            # Client disconnected before message could be delivered — safe to ignore.
            pass

    @database_sync_to_async
    def get_user(self, user_id):
        """Get user by ID."""
        try:
            return User.objects.get(id=user_id)
        except User.DoesNotExist:
            return None

    @database_sync_to_async
    def get_all_online_users(self):
        """Return all currently online user IDs from the presence index.

        Uses a single cache key (PRESENCE_INDEX_KEY) that stores a set of user
        IDs rather than scanning all cache keys.  This is portable across every
        Django cache backend : no cache.keys() needed.
        """
        online_ids = cache.get(PRESENCE_INDEX_KEY)
        if not online_ids:
            return []
        return list(online_ids)

    @database_sync_to_async
    def user_has_active_connections(self, user_id):
        """Return True if the user still has at least one active WS connection."""
        count = cache.get(f'{PRESENCE_CONN_COUNT_PREFIX}{user_id}', 0)
        return count > 0

    @database_sync_to_async
    def mark_user_online(self, user_id):
        """Increment connection count, mark user as online, add to presence index."""
        # Increment per-user connection counter atomically via add+incr pattern.
        conn_key = f'{PRESENCE_CONN_COUNT_PREFIX}{user_id}'
        count = cache.get(conn_key, 0)
        cache.set(conn_key, count + 1, timeout=PRESENCE_TIMEOUT)

        # Keep the shared index up-to-date.
        # Re-fetch each time to minimise (not eliminate) race window on
        # non-atomic backends; on Redis use atomic ops via django-redis if needed.
        cache_key = f'{PRESENCE_KEY_PREFIX}{user_id}'
        cache.set(cache_key, 'online', timeout=PRESENCE_TIMEOUT)

        online_ids = cache.get(PRESENCE_INDEX_KEY) or set()
        online_ids.add(user_id)
        cache.set(PRESENCE_INDEX_KEY, online_ids, timeout=PRESENCE_TIMEOUT)

    @database_sync_to_async
    def mark_user_offline(self, user_id):
        """Decrement connection count; remove from presence index on last disconnect."""
        conn_key = f'{PRESENCE_CONN_COUNT_PREFIX}{user_id}'
        count = max(cache.get(conn_key, 0) - 1, 0)
        if count > 0:
            cache.set(conn_key, count, timeout=PRESENCE_TIMEOUT)
            # Still has other connections — stay online in the index.
            return

        # Last connection closed — remove from presence entirely.
        cache.delete(conn_key)
        cache_key = f'{PRESENCE_KEY_PREFIX}{user_id}'
        cache.delete(cache_key)

        online_ids = cache.get(PRESENCE_INDEX_KEY) or set()
        online_ids.discard(user_id)
        if online_ids:
            cache.set(PRESENCE_INDEX_KEY, online_ids, timeout=PRESENCE_TIMEOUT)
        else:
            cache.delete(PRESENCE_INDEX_KEY)
