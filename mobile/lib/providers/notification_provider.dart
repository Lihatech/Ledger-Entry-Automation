import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/notification_item.dart';
import '../services/notification_service.dart';

/// Shared notification state for the mobile application.
///
/// The provider is intentionally passive in Phase 1: it does not start a
/// socket or automatically change the existing screens. Later phases can add
/// loading, real-time events, persistence, and navigation against this stable
/// state boundary.
class NotificationProvider extends ChangeNotifier {
  final NotificationService _service;
  List<NotificationItem> _items = const [];
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _messageReconnectTimer;
  bool _shouldReconnectMessages = false;
  bool _messageSocketConnected = false;
  String? _currentUserId;
  Set<String> _locallyReadIds = <String>{};
  String? _readStateKey;
  String? _initializedUserKey;

  NotificationProvider({NotificationService? service})
    : _service = service ?? NotificationService();

  List<NotificationItem> get items => List.unmodifiable(_items);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get unreadCount => _items.where((item) => !item.isRead).length;
  bool get isMessageSocketConnected => _messageSocketConnected;

  Future<void> initializeForUser({String? userId}) async {
    final userKey = userId ?? 'anonymous';
    if (_initializedUserKey == userKey && _shouldReconnectMessages) return;
    _initializedUserKey = userKey;
    await startMessageNotifications(userId: userId);
    await Future.wait([loadDcrNotifications(), loadMessageNotifications()]);
  }

  Future<void> startMessageNotifications({String? userId}) async {
    await _setUser(userId);
    _currentUserId = userId;
    if (_shouldReconnectMessages && _messageSocketConnected) return;
    _shouldReconnectMessages = true;
    _messageReconnectTimer?.cancel();
    await _connectMessageNotifications();
  }

  Future<void> _connectMessageNotifications() async {
    if (!_shouldReconnectMessages) return;
    try {
      await _service.connectMessageNotifications(
        _handleMessageSocketEvent,
        _scheduleMessageReconnect,
      );
      _messageSocketConnected = true;
      notifyListeners();
    } catch (error) {
      _messageSocketConnected = false;
      _errorMessage = error.toString();
      notifyListeners();
      _scheduleMessageReconnect();
    }
  }

  void _handleMessageSocketEvent(Map<String, dynamic> event) {
    if (event['type'] == 'task_assigned_notification') {
      final data = event['data'];
      if (data is! Map) return;
      addOrUpdate(
        NotificationItem(
          id: 'dcr-${data['id']}',
          category: NotificationCategory.system,
          title: data['title']?.toString() ?? 'New task assigned',
          message: data['message']?.toString() ?? '',
          createdAt: DateTime.tryParse(data['created_at']?.toString() ?? ''),
          backendNotificationId: int.tryParse('${data['id']}'),
          action: data['action_url']?.toString() ?? '/tasks',
          metadata: {'notification_type': data['action_type'] ?? 'general'},
        ),
      );
      return;
    }
    if (event['type'] != 'new_message_notification') return;
    final data = event['data'];
    if (data is! Map) return;
    final message = data['message'];
    if (message is! Map) return;

    final sender = message['sender'];
    final senderId = sender is Map ? sender['id']?.toString() : null;
    if (_currentUserId != null && senderId == _currentUserId) return;

    final messageId = message['id']?.toString();
    final conversationId = data['conversation_id']?.toString();
    if (messageId == null || conversationId == null) return;

    final senderName = sender is Map
        ? (sender['username'] ?? sender['first_name'] ?? 'Someone').toString()
        : 'Someone';
    final content = message['content']?.toString();
    addOrUpdate(
      NotificationItem(
        id: 'message-$messageId',
        category: NotificationCategory.message,
        title: senderName,
        message: content?.isNotEmpty == true ? content! : 'New message',
        createdAt: DateTime.tryParse(message['created_at']?.toString() ?? ''),
        conversationId: conversationId,
        action: 'open_conversation',
        metadata: {'message_type': message['message_type'] ?? 'text'},
      ),
    );
  }

  void _scheduleMessageReconnect() {
    if (!_shouldReconnectMessages || _messageReconnectTimer?.isActive == true) {
      return;
    }
    _messageSocketConnected = false;
    notifyListeners();
    _messageReconnectTimer = Timer(
      const Duration(seconds: 3),
      _connectMessageNotifications,
    );
  }

  Future<void> stopMessageNotifications() async {
    _shouldReconnectMessages = false;
    _messageReconnectTimer?.cancel();
    _messageReconnectTimer = null;
    _messageSocketConnected = false;
    await _service.disconnectMessageNotifications();
    notifyListeners();
  }

  Future<void> loadDcrNotifications() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final dcrItems = await _service.fetchDcrNotifications();
      _items = _merge(
        dcrItems,
        _items.where((item) {
          return item.category != NotificationCategory.dcr &&
              item.category != NotificationCategory.document &&
              item.category != NotificationCategory.system;
        }).toList(),
      );
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMessageNotifications() async {
    try {
      final messageItems = await _service.fetchMessageNotifications();
      replaceCategory(NotificationCategory.message, messageItems);
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> markAsRead(NotificationItem item) async {
    if (item.isRead) return;

    final wasLocallyRead = _locallyReadIds.contains(item.id);
    _locallyReadIds.add(item.id);
    _replace(item.copyWith(isRead: true));
    await _persistReadState();
    notifyListeners();

    if (item.backendNotificationId != null) {
      try {
        await _service.markDcrAsRead(item.backendNotificationId!);
      } catch (error) {
        if (!wasLocallyRead) _locallyReadIds.remove(item.id);
        _replace(item);
        await _persistReadState();
        _errorMessage = error.toString();
        notifyListeners();
      }
    }
  }

  Future<void> markAsUnread(NotificationItem item) async {
    if (!item.isRead) return;

    final wasLocallyRead = _locallyReadIds.remove(item.id);
    _replace(item.copyWith(isRead: false));
    await _persistReadState();
    notifyListeners();

    if (item.backendNotificationId != null) {
      try {
        await _service.markDcrAsUnread(item.backendNotificationId!);
      } catch (error) {
        if (wasLocallyRead) _locallyReadIds.add(item.id);
        _replace(item);
        await _persistReadState();
        _errorMessage = error.toString();
        notifyListeners();
      }
    }
  }

  Future<void> markAllAsRead() async {
    final previous = _items;
    final previousReadIds = {..._locallyReadIds};
    _locallyReadIds.addAll(_items.map((item) => item.id));
    _items = _items.map((item) => item.copyWith(isRead: true)).toList();
    await _persistReadState();
    notifyListeners();

    try {
      await _service.markAllDcrAsRead();
    } catch (error) {
      _locallyReadIds = previousReadIds;
      _items = previous;
      await _persistReadState();
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  void addOrUpdate(NotificationItem item) {
    _replace(_applyReadState(item));
    notifyListeners();
  }

  void replaceCategory(
    NotificationCategory category,
    List<NotificationItem> items,
  ) {
    _items = [
      ..._items.where((item) => item.category != category),
      ...items.map(_applyReadState),
    ];
    _items.sort((a, b) {
      final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    notifyListeners();
  }

  void clear() {
    _items = const [];
    _errorMessage = null;
    notifyListeners();
  }

  void resetForLogout() {
    _initializedUserKey = null;
    unawaited(stopMessageNotifications());
    clear();
  }

  Future<void> _setUser(String? userId) async {
    final key = 'notification_read_ids_${userId ?? 'anonymous'}';
    if (_readStateKey == key) return;
    _readStateKey = key;
    final prefs = await SharedPreferences.getInstance();
    _locallyReadIds = (prefs.getStringList(key) ?? <String>[]).toSet();
  }

  Future<void> _persistReadState() async {
    final key = _readStateKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, _locallyReadIds.toList());
  }

  NotificationItem _applyReadState(NotificationItem item) {
    if (item.isRead) {
      _locallyReadIds.add(item.id);
      return item;
    }
    return _locallyReadIds.contains(item.id)
        ? item.copyWith(isRead: true)
        : item;
  }

  @override
  void dispose() {
    _shouldReconnectMessages = false;
    _messageReconnectTimer?.cancel();
    _service.disconnectMessageNotifications();
    super.dispose();
  }

  void _replace(NotificationItem item) {
    final index = _items.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      _items = [..._items, item];
      return;
    }

    final updated = [..._items];
    updated[index] = item;
    _items = updated;
  }

  List<NotificationItem> _merge(
    List<NotificationItem> first,
    List<NotificationItem> second,
  ) {
    final byId = <String, NotificationItem>{};
    for (final item in [...first, ...second]) {
      byId[item.id] = item;
    }
    final merged = byId.values.toList();
    merged.sort((a, b) {
      final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return merged;
  }
}
