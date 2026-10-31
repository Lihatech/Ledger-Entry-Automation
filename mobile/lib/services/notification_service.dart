import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/notification_item.dart';
import 'document_control_service.dart';
import 'api_service.dart';
import 'messaging_service.dart';

/// Backend boundary for notification data.
///
/// Network orchestration stays here instead of inside widgets/providers. This
/// phase only adapts the existing DCR notification API; message WebSocket and
/// supervisor persistence are added in later phases.
class NotificationService {
  final DocumentControlService _documentControlService;
  final MessagingService _messagingService;
  WebSocketChannel? _messageChannel;
  StreamSubscription<dynamic>? _messageSubscription;

  NotificationService({
    DocumentControlService? documentControlService,
    MessagingService? messagingService,
  }) : _documentControlService =
           documentControlService ?? DocumentControlService(),
       _messagingService = messagingService ?? MessagingService();

  Future<List<NotificationItem>> fetchDcrNotifications() async {
    final notifications = await _documentControlService.getNotifications();
    return notifications.map(_fromDcrNotification).toList();
  }

  Future<int> fetchDcrUnreadCount() {
    return _documentControlService.getUnreadNotificationCount();
  }

  Future<List<NotificationItem>> fetchMessageNotifications() async {
    final conversations = await _messagingService.fetchConversations();
    return conversations
        .whereType<Map>()
        .map((conversation) => Map<String, dynamic>.from(conversation))
        .where((conversation) => _asInt(conversation['unread_count']) > 0)
        .map(_fromConversation)
        .toList();
  }

  Future<void> markDcrAsRead(int id) {
    return _documentControlService.markNotificationAsRead(id);
  }

  Future<void> markDcrAsUnread(int id) {
    return _documentControlService.markNotificationAsUnread(id);
  }

  Future<void> markAllDcrAsRead() {
    return _documentControlService.markAllNotificationsAsRead();
  }

  /// Connect to the authenticated user-level messaging notification socket.
  /// The caller owns reconnection policy; this service only owns the socket.
  Future<void> connectMessageNotifications(
    void Function(Map<String, dynamic> event) onEvent,
    void Function() onDisconnected,
  ) async {
    await disconnectMessageNotifications();
    final token = await ApiService.getToken();
    if (token == null || token.isEmpty) return;

    final uri = Uri.parse(
      '${MessagingService.wsUrl}/ws/messaging/notifications/',
    );
    _messageChannel = WebSocketChannel.connect(uri);
    _messageChannel!.sink.add(
      jsonEncode({'type': 'auth', 'action': 'auth', 'token': token}),
    );
    _messageSubscription = _messageChannel!.stream.listen(
      (rawEvent) {
        try {
          final decoded = jsonDecode(rawEvent as String);
          if (decoded is Map<String, dynamic>) onEvent(decoded);
        } catch (_) {
          // Ignore malformed socket events; the stream remains usable.
        }
      },
      onError: (_) => onDisconnected(),
      onDone: onDisconnected,
      cancelOnError: false,
    );
  }

  Future<void> disconnectMessageNotifications() async {
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _messageChannel?.sink.close();
    _messageChannel = null;
  }

  NotificationItem _fromDcrNotification(DCRNotification notification) {
    return NotificationItem(
      id: 'dcr-${notification.id}',
      category: _categoryFor(notification.notificationType),
      title: notification.title,
      message: notification.message,
      createdAt: DateTime.tryParse(notification.createdAt),
      isRead: notification.isRead,
      backendNotificationId: notification.id,
      dcrId: notification.dcrId,
      dcrNumber: notification.dcrNumber,
      metadata: {'notification_type': notification.notificationType},
    );
  }

  NotificationItem _fromConversation(Map<String, dynamic> conversation) {
    final conversationId = conversation['id']?.toString() ?? '';
    final lastMessage = conversation['last_message'] as Map<String, dynamic>?;
    final sender = lastMessage?['sender'] as Map<String, dynamic>?;
    final senderName =
        sender?['username']?.toString() ??
        sender?['first_name']?.toString() ??
        'New message';
    final content = lastMessage?['content']?.toString();
    final messageId =
        lastMessage?['id']?.toString() ??
        '$conversationId-${conversation['updated_at'] ?? conversation['unread_count']}';

    return NotificationItem(
      id: 'message-$messageId',
      category: NotificationCategory.message,
      title: senderName,
      message: content?.isNotEmpty == true
          ? content!
          : 'You have unread messages.',
      createdAt: DateTime.tryParse(
        lastMessage?['created_at']?.toString() ??
            conversation['updated_at']?.toString() ??
            '',
      ),
      conversationId: conversationId,
      action: 'open_conversation',
      metadata: {'unread_count': _asInt(conversation['unread_count'])},
    );
  }

  int _asInt(dynamic value) =>
      value is int ? value : int.tryParse('$value') ?? 0;

  NotificationCategory _categoryFor(String type) {
    final normalized = type.toLowerCase();
    if (normalized.contains('document')) return NotificationCategory.document;
    if (normalized.contains('message')) return NotificationCategory.message;
    if (normalized.contains('dcr') || normalized.contains('change')) {
      return NotificationCategory.dcr;
    }
    return NotificationCategory.system;
  }
}
