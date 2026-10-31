import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

class MessagingService {
  static String get baseUrl => ApiService.baseUrl;
  static String get wsUrl {
    if (ApiService.baseUrl.startsWith('https://')) {
      return ApiService.baseUrl.replaceFirst('https://', 'wss://').replaceFirst('/api', '');
    } else {
      return ApiService.baseUrl.replaceFirst('http://', 'ws://').replaceFirst('/api', '');
    }
  }

  WebSocketChannel? _channel;
  Function(Map<String, dynamic>)? onMessageReceived;
  Function(Map<String, dynamic>)? onMessageSent;
  Function(Map<String, dynamic>)? onTypingIndicator;
  Function(Map<String, dynamic>)? onMessageRead;
  Function(String)? onMessageDeleted;
  Function(Map<String, dynamic>)? onMessageReaction;

  Future<String?> _getToken() async {
    return await ApiService.getToken();
  }

  Future<Map<String, String>> _getHeaders() async {
    final token = await _getToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // Fetch conversations
  Future<List<dynamic>> fetchConversations() async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/messaging/conversations/'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['results'] != null) return decoded['results'] as List;
        return [];
      } else {
        throw Exception('Failed to load conversations');
      }
    } catch (e) {
      print('Error fetching conversations: $e');
      return [];
    }
  }

  // Fetch messages for a conversation
  Future<Map<String, dynamic>> fetchMessages(
    String conversationId, {
    int offset = 0,
    int limit = 50,
  }) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse(
          '$baseUrl/messaging/conversations/$conversationId/messages/?offset=$offset&limit=$limit',
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load messages');
      }
    } catch (e) {
      print('Error fetching messages: $e');
      return {'results': [], 'count': 0, 'next_offset': null};
    }
  }

  // Clear history for a conversation
  Future<bool> clearHistory(String conversationId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/clear/'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        print('Failed to clear history: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('Error clearing history: $e');
      return false;
    }
  }

  // Leave group conversation
  Future<bool> leaveGroup(String conversationId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.delete(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/'),
        headers: headers,
      );

      if (response.statusCode == 204) {
        return true;
      } else {
        print('Failed to leave group: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('Error leaving group: $e');
      return false;
    }
  }

  // Create new conversation
  Future<Map<String, dynamic>?> createConversation({
    required String type,
    required List<int> participantIds,
    String? name,
    String? description,
  }) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/'),
        headers: headers,
        body: json.encode({
          'type': type,
          'participant_ids': participantIds,
          'name': name ?? '',
          'description': description ?? '',
        }),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to create conversation: ${response.statusCode}');
      }
    } catch (e) {
      print('Error creating conversation: $e');
      return null;
    }
  }

  // Search users
  Future<List<dynamic>> searchUsers(String query) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/messaging/users/search/?q=${Uri.encodeComponent(query)}'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['results'] != null) return decoded['results'] as List;
        return [];
      } else {
        throw Exception('Failed to search users');
      }
    } catch (e) {
      print('Error searching users: $e');
      return [];
    }
  }

  // Upload file
  Future<Map<String, dynamic>?> uploadFile(File file, String messageId) async {
    try {
      final token = await _getToken();
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/messaging/upload/'),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.fields['message_id'] = messageId;
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 201) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to upload file');
      }
    } catch (e) {
      print('Error uploading file: $e');
      return null;
    }
  }

  String? _currentConversationId;
  bool _shouldReconnect = true;

  // Connect to WebSocket
  void connectWebSocket(String conversationId) async {
    _currentConversationId = conversationId;
    _shouldReconnect = true;

    final token = await _getToken();
    if (token == null) {
      print('No token available for WebSocket connection');
      return;
    }

    try {
      final uri = Uri.parse('$wsUrl/ws/messaging/$conversationId/');
      _channel = WebSocketChannel.connect(uri);
      _channel!.sink.add(json.encode({'type': 'auth', 'action': 'auth', 'token': token}));

      _channel!.stream.listen(
        (message) {
          final data = json.decode(message);
          _handleWebSocketMessage(data);
        },
        onError: (error) {
          print('WebSocket error: $error');
        },
        onDone: () {
          print('WebSocket connection closed');
          // Only reconnect if shouldReconnect flag is true and callbacks are still set
          if (_shouldReconnect &&
              _currentConversationId == conversationId &&
              (onMessageReceived != null || onTypingIndicator != null || onMessageRead != null)) {
            Future.delayed(const Duration(seconds: 3), () {
              // Double-check callbacks still exist before reconnecting
              if (onMessageReceived != null || onTypingIndicator != null || onMessageRead != null) {
                connectWebSocket(conversationId);
              }
            });
          }
        },
      );
    } catch (e) {
      print('Error connecting to WebSocket: $e');
    }
  }

  void _handleWebSocketMessage(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'connection_established':
        print('WebSocket connected: ${data['message']}');
        break;

      case 'message_sent':
        // Server confirmation that OUR message was saved — add it to the local list
        if (onMessageSent != null) {
          onMessageSent!(data['data']);
        }
        break;

      case 'new_message':
        // Message from another user in the conversation
        if (onMessageReceived != null) {
          onMessageReceived!(data['data']);
        }
        break;

      case 'message_read':
        if (onMessageRead != null) {
          onMessageRead!(data['data']);
        }
        break;

      case 'user_typing':
        if (onTypingIndicator != null) {
          onTypingIndicator!(data['data']);
        }
        break;

      case 'message_deleted':
        if (onMessageDeleted != null) {
          onMessageDeleted!(data['data']['message_id'].toString());
        }
        break;

      case 'message_reaction':
        if (onMessageReaction != null) {
          onMessageReaction!(data['data'] as Map<String, dynamic>);
        }
        break;

      case 'error':
        print('WebSocket error: ${data['message']}');
        break;

      default:
        print('Unknown message type: ${data['type']}');
    }
  }

  // Send message via WebSocket
  Future<void> sendMessage({required String content, String messageType = 'text', String? replyTo, String? conversationId}) async {
    if (_channel != null) {
      _channel!.sink.add(json.encode({
        'action': 'send_message',
        'data': {
          'content': content,
          'message_type': messageType,
          'reply_to': replyTo,
        }
      }));
    } else if (conversationId != null) {
      // Fallback to REST if WebSocket is not connected (e.g. from Meet invite)
      try {
        final headers = await _getHeaders();
        await http.post(
          Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/'),
          headers: headers,
          body: json.encode({
            'content': content,
            'message_type': messageType,
          }),
        );
      } catch (e) {
        print('Error sending message via REST: $e');
      }
    } else {
      print('WebSocket not connected and no conversationId provided for REST fallback');
    }
  }

  // Send message with attachment (REST)
  // Fix 5: Enforces a 20 MB size limit before buffering to avoid memory exhaustion.
  // Fix 4: Deletes the created message if the upload step fails (non-atomic operation
  //         made safe by compensating delete on failure).
  static const int _maxAttachmentBytes = 20 * 1024 * 1024; // 20 MB

  Future<Map<String, dynamic>?> sendAttachment({
    required String conversationId,
    required List<int> bytes,
    required String filename,
    required String messageType,
  }) async {
    // Fix 5: Reject files larger than the size limit before creating any server state.
    if (bytes.length > _maxAttachmentBytes) {
      throw ArgumentError(
        'File "$filename" exceeds the ${_maxAttachmentBytes ~/ (1024 * 1024)} MB size limit.'
      );
    }

    try {
      final headers = await _getHeaders();

      // 1. Create empty message first
      final messageRes = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/'),
        headers: headers,
        body: json.encode({
          'content': filename,
          'message_type': messageType,
        }),
      );

      if (messageRes.statusCode == 201) {
        final message = json.decode(messageRes.body);
        final messageId = message['id'];

        // 2. Upload file
        var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/messaging/upload/'));
        request.headers.addAll({
          'Authorization': headers['Authorization']!,
        });
        request.fields['message_id'] = messageId;

        request.files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: filename)
        );

        final uploadRes = await request.send();
        if (uploadRes.statusCode == 201) {
          final resBody = await uploadRes.stream.bytesToString();
          final attachmentData = json.decode(resBody);
          message['attachments'] = [attachmentData];
          return message;
        }

        // Fix 4: Upload failed — delete the orphan message to keep DB consistent.
        try {
          await http.delete(
            Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/$messageId/'),
            headers: headers,
          );
        } catch (e) {
          print('Warning: failed to clean up orphan message $messageId after upload failure: $e');
        }
        return null;
      }
      return null;
    } catch (e) {
      print('Error sending attachment: $e');
      return null;
    }
  }

  // Mark message as read
  void markAsRead(String messageId) {
    if (_channel == null) return;

    _channel!.sink.add(json.encode({
      'action': 'mark_read',
      'data': {
        'message_id': messageId,
      }
    }));
  }

  // Send typing indicator
  void sendTypingIndicator(bool isTyping) {
    if (_channel == null) return;

    _channel!.sink.add(json.encode({
      'action': 'typing',
      'data': {
        'is_typing': isTyping,
      }
    }));
  }

  // Disconnect WebSocket
  void disconnectWebSocket() {
    _shouldReconnect = false; // Prevent reconnection after intentional disconnect
    _currentConversationId = null;
    _channel?.sink.close();
    _channel = null;
  }

  WebSocketChannel? _presenceChannel;
  Map<int, bool> onlineUsers = {};
  void Function(Map<int, bool>)? onPresenceUpdated;

  void connectPresenceWebSocket() async {
    final token = await _getToken();
    if (token == null) return;
    try {
      final uri = Uri.parse('$wsUrl/ws/presence/');
      _presenceChannel = WebSocketChannel.connect(uri);
      _presenceChannel!.sink.add(json.encode({'type': 'auth', 'action': 'auth', 'token': token}));
      _presenceChannel!.stream.listen(
        (message) {
          final data = json.decode(message);
          if (data['type'] == 'initial_presence') {
            final users = data['data']['online_users'] as List;
            for (var u in users) onlineUsers[u as int] = true;
            if (onPresenceUpdated != null) onPresenceUpdated!(onlineUsers);
          } else if (data['type'] == 'user_status_changed') {
            final userId = data['data']['user_id'] as int;
            final status = data['data']['status'] as String;
            onlineUsers[userId] = status == 'online';
            if (onPresenceUpdated != null) onPresenceUpdated!(onlineUsers);
          }
        },
        onError: (e) => print('Presence WS error: $e'),
        onDone: () => print('Presence WS closed'),
      );
    } catch (e) {
      print('Presence WS connection error: $e');
    }
  }

  void disconnectPresenceWebSocket() {
    _presenceChannel?.sink.close();
    _presenceChannel = null;
  }

  // Mark message as read via HTTP (fallback)
  Future<void> markMessageAsReadHttp(String conversationId, String messageId) async {
    try {
      final headers = await _getHeaders();
      await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/$messageId/read/'),
        headers: headers,
      );
    } catch (e) {
      print('Error marking message as read: $e');
    }
  }

  // Get conversation details
  Future<Map<String, dynamic>?> getConversation(String conversationId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return null;
    } catch (e) {
      print('Error fetching conversation: $e');
      return null;
    }
  }

  // Delete message
  Future<bool> deleteMessage(String messageId) async {
    try {
      final headers = await _getHeaders();
      // Look up conversation ID from cached messages if possible
      String? convId = _currentConversationId;
      if (convId == null) return false;
      
      final response = await http.delete(
        Uri.parse('$baseUrl/messaging/conversations/$convId/messages/$messageId/'),
        headers: headers,
      );
      return response.statusCode == 204;
    } catch (e) {
      print('Error deleting message: $e');
      return false;
    }
  }

  // Pin message
  Future<bool> pinMessage(String conversationId, String messageId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/pin-message/'),
        headers: headers,
        body: json.encode({'message_id': messageId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Error pinning message: $e');
      return false;
    }
  }

  // React to message
  Future<bool> reactToMessage(String conversationId, String messageId, String emoji) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/$messageId/react/'),
        headers: headers,
        body: json.encode({'emoji': emoji}),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error reacting to message: $e');
      return false;
    }
  }

  // Remove reaction from message
  Future<bool> removeReaction(String conversationId, String messageId, String emoji) async {
    try {
      final headers = await _getHeaders();
      final response = await http.delete(
        Uri.parse('$baseUrl/messaging/conversations/$conversationId/messages/$messageId/react/'),
        headers: headers,
        body: json.encode({'emoji': emoji}),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Error removing reaction: $e');
      return false;
    }
  }

  // Forward message
  Future<bool> forwardMessage(String originalConversationId, String messageId, String targetConversationId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('$baseUrl/messaging/conversations/$originalConversationId/messages/$messageId/forward/'),
        headers: headers,
        body: json.encode({'target_conversation_id': targetConversationId}),
      );
      return response.statusCode == 201;
    } catch (e) {
      print('Error forwarding message: $e');
      return false;
    }
  }
}
