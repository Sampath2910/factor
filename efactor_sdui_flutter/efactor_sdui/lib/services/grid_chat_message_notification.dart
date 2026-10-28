import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One GRID Chat line kept for a conversation's Android MessagingStyle stack.
class GridChatMessageLine {
  const GridChatMessageLine({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.messageType,
    required this.atMs,
  });

  final String messageId;
  final String senderId;
  final String senderName;
  final String body;
  final String messageType;
  final int atMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'message_id': messageId,
        'sender_id': senderId,
        'sender_name': senderName,
        'body': body,
        'msg_type': messageType,
        'message_type': messageType,
        'at_ms': atMs,
      };

  static GridChatMessageLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at_ms'];
    return GridChatMessageLine(
      messageId: (raw['message_id'] ?? '').toString(),
      senderId: (raw['sender_id'] ?? '').toString(),
      senderName: (raw['sender_name'] ?? '').toString(),
      body: (raw['body'] ?? '').toString(),
      messageType:
          (raw['msg_type'] ?? raw['msgType'] ?? raw['message_type'] ?? 'text')
              .toString(),
      atMs: at is int ? at : int.tryParse(at?.toString() ?? '') ?? 0,
    );
  }
}

/// Parsed `NEW_MESSAGE` data payload. FCM delivers every value as a string.
class GridChatMessage {
  const GridChatMessage({
    required this.conversationId,
    required this.messageId,
    required this.messageType,
    required this.title,
    this.groupTitle = '',
    required this.body,
    required this.senderId,
    required this.senderName,
    required this.isGroup,
    required this.locked,
    required this.expiresAt,
    required this.tag,
    required this.receivedAtMs,
  });

  static const String lockedLabel = 'GRID Chat – New message';
  static const int maxLines = 8;
  static const String seenPrefsKey = 'efactor_chat_seen_message_ids_v1';
  static const String stackPrefsKey = 'efactor_chat_message_stacks_v1';

  final String conversationId;
  final String messageId;
  final String messageType;
  final String title;
  final String groupTitle;
  final String body;
  final String senderId;
  final String senderName;
  final bool isGroup;
  final bool locked;
  final DateTime? expiresAt;
  final String tag;
  final int receivedAtMs;

  bool get isExpired {
    final expires = expiresAt;
    if (expires == null) return false;
    return !expires.isAfter(DateTime.now().toUtc());
  }

  String get notificationTag {
    if (tag.isNotEmpty) return tag;
    return 'conv-$conversationId';
  }

  int get notificationId => notificationIdForConversation(conversationId);

  static int notificationIdForConversation(String conversationId) {
    final parsed = int.tryParse(conversationId.trim());
    if (parsed != null) return parsed.abs();
    return conversationId.hashCode.abs();
  }

  static bool isGridChatMessage(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
    final notificationType =
        (data['notification_type'] ?? data['notificationType'] ?? '')
            .toString()
            .toLowerCase();
    return type == 'NEW_MESSAGE' ||
        type == 'CHAT_MESSAGE' ||
        type == 'MESSAGE' ||
        notificationType == 'message';
  }

  static bool isTruthyFlag(Object? raw) {
    if (raw == true || raw == 1) return true;
    final text = raw?.toString().trim().toLowerCase() ?? '';
    return text == '1' || text == 'true' || text == 'yes';
  }

  /// Unix seconds, unix milliseconds, or an ISO-8601 timestamp.
  static DateTime? parseExpiresAt(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    final asInt = int.tryParse(text);
    if (asInt != null) {
      if (asInt >= 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
      }
      if (asInt >= 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(asInt * 1000, isUtc: true);
      }
      return null;
    }
    return DateTime.tryParse(text)?.toUtc();
  }

  static GridChatMessage? parse(Map<String, dynamic> data) {
    if (!isGridChatMessage(data)) return null;
    final conversationId =
        (data['conversation_id'] ?? data['conversationId'] ?? '')
            .toString()
            .trim();
    if (conversationId.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawGroupTitle =
        (data['group_title'] ?? data['groupTitle'] ?? '').toString().trim();
    final rawTitle = (data['title'] ?? '').toString().trim();
    final effectiveTitle = rawGroupTitle.isNotEmpty ? rawGroupTitle : rawTitle;

    return GridChatMessage(
      conversationId: conversationId,
      messageId: (data['message_id'] ?? data['messageId'] ?? '').toString().trim(),
      messageType: (data['msg_type'] ??
              data['msgType'] ??
              data['message_type'] ??
              data['messageType'] ??
              'text')
          .toString()
          .trim()
          .toLowerCase(),
      title: effectiveTitle,
      groupTitle: rawGroupTitle,
      body: (data['body'] ?? data['message'] ?? data['text'] ?? '').toString(),
      senderId: (data['sender_id'] ?? data['senderId'] ?? '').toString().trim(),
      senderName: (data['sender_name'] ??
              data['senderName'] ??
              data['name'] ??
              data['user_name'] ??
              '')
          .toString()
          .trim(),
      isGroup: isTruthyFlag(data['is_group'] ?? data['isGroup']),
      locked: isTruthyFlag(data['locked']),
      expiresAt: parseExpiresAt(data['expires_at'] ?? data['expiresAt']),
      tag: (data['tag'] ?? '').toString().trim(),
      receivedAtMs: now,
    );
  }

  static bool shouldSuppress({
    required String? activeConversationId,
    required String conversationId,
    required bool appResumed,
  }) {
    if (!appResumed || conversationId.isEmpty) return false;
    return activeConversationId?.trim() == conversationId;
  }

  static bool isDuplicateMessage(String messageId, Iterable<String> seen) {
    final id = messageId.trim();
    if (id.isEmpty) return false;
    return seen.contains(id);
  }
}

/// Cold-start tap or Reply. A pending call Answer is left in place.
class PendingChatOpen {
  const PendingChatOpen({
    required this.conversationId,
    required this.compose,
    required this.needsJs,
    required this.storedAtMs,
  });

  static const Duration ttl = Duration(minutes: 2);
  static const String prefsKey = 'efactor_pending_chat_open_v1';

  final String conversationId;
  final bool compose;
  final bool needsJs;
  final int storedAtMs;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch - storedAtMs > ttl.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'conversation_id': conversationId,
        'compose': compose,
        'needs_js': needsJs,
        'stored_at_ms': storedAtMs,
      };

  static PendingChatOpen? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final conversationId = (raw['conversation_id'] ?? '').toString().trim();
    if (conversationId.isEmpty) return null;
    final stored = raw['stored_at_ms'];
    return PendingChatOpen(
      conversationId: conversationId,
      compose: raw['compose'] == true,
      needsJs: raw['needs_js'] == true,
      storedAtMs: stored is int
          ? stored
          : int.tryParse(stored?.toString() ?? '') ?? 0,
    );
  }
}

/// Android message notifications for GRID Chat.
class GridChatMessageNotifications {
  GridChatMessageNotifications._();
  static final GridChatMessageNotifications instance =
      GridChatMessageNotifications._();

  static const String gridChatUrl = 'https://efactor.tech/index.php/grid-chat';

  final ValueNotifier<PendingChatOpen?> pendingOpenListenable =
      ValueNotifier<PendingChatOpen?>(null);
  PendingChatOpen? _pendingOpen;
  Future<void> _queue = Future<void>.value();

  PendingChatOpen? get pendingOpen {
    final pending = _pendingOpen;
    if (pending != null && pending.isExpired) return null;
    return pending;
  }

  static Uri conversationUri(
    String conversationId, {
    required bool compose,
  }) {
    final params = <String, String>{
      'conversation_id': conversationId,
    };
    if (compose) params['compose'] = '1';
    return Uri.parse(gridChatUrl).replace(queryParameters: params);
  }

  static void chatTrace(String event, String conversationId, String messageId) {
    final t = DateTime.now().millisecondsSinceEpoch;
    // ignore: avoid_print
    print(
      '[CHAT] $event conversation_id=$conversationId message_id=$messageId t=$t',
    );
  }

  Future<void> present(
    FlutterLocalNotificationsPlugin plugin,
    Map<String, dynamic> data, {
    required bool appResumed,
    String? activeConversationId,
  }) {
    return _serialized(() async {
      final message = GridChatMessage.parse(data);
      if (message == null) return;
      if (message.isExpired) {
        chatTrace(
          'dropped expired',
          message.conversationId,
          message.messageId,
        );
        await _removeLine(plugin, message);
        return;
      }
      final seen = await _readSeen();
      if (GridChatMessage.isDuplicateMessage(message.messageId, seen)) {
        chatTrace('duplicate', message.conversationId, message.messageId);
        return;
      }
      if (GridChatMessage.shouldSuppress(
        activeConversationId: activeConversationId,
        conversationId: message.conversationId,
        appResumed: appResumed,
      )) {
        await _rememberSeen(seen, message.messageId);
        await plugin.cancel(message.notificationId, tag: message.notificationTag);
        chatTrace('suppressed', message.conversationId, message.messageId);
        return;
      }
      final stacks = await _readStacks();
      final existing = stacks[message.conversationId];
      final List<GridChatMessageLine> lines;
      final bool locked;
      if (message.locked) {
        locked = true;
        lines = <GridChatMessageLine>[];
      } else {
        locked = false;
        final previous = existing?['locked'] == true
            ? <GridChatMessageLine>[]
            : _linesFrom(existing);
        lines = <GridChatMessageLine>[
          ...previous,
          GridChatMessageLine(
            messageId: message.messageId,
            senderId: message.senderId,
            senderName: message.senderName,
            body: message.body,
            messageType: message.messageType,
            atMs: message.receivedAtMs,
          ),
        ];
        if (lines.length > GridChatMessage.maxLines) {
          lines.removeRange(0, lines.length - GridChatMessage.maxLines);
        }
      }
      stacks[message.conversationId] = <String, dynamic>{
        'locked': locked,
        'title': message.title,
        'group_title': message.groupTitle,
        'is_group': message.isGroup,
        'tag': message.notificationTag,
        'lines': lines.map((line) => line.toJson()).toList(),
      };
      await _writeStacks(stacks);
      await _rememberSeen(seen, message.messageId);
      await _show(plugin, message, lines, locked: locked);
      chatTrace('posted', message.conversationId, message.messageId);
    });
  }

  Future<void> clearConversation(
    String conversationId,
    FlutterLocalNotificationsPlugin plugin,
  ) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    final messageId = GridChatMessage.notificationIdForConversation(id);
    try {
      final stacks = await _readStacks();
      final tag = (stacks[id]?['tag'] ?? 'conv-$id').toString();
      stacks.remove(id);
      await _writeStacks(stacks);
      await plugin.cancel(messageId, tag: tag);
      await plugin.cancel(messageId);
    } catch (e) {
      chatTrace('clear failed', id, '');
      debugPrint('[CHAT] clear conversation error: $e');
    }
  }

  Future<void> restorePendingOpen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PendingChatOpen.prefsKey);
      if (raw == null || raw.isEmpty) return;
      final pending = PendingChatOpen.fromJson(jsonDecode(raw));
      if (pending == null || pending.isExpired) {
        await prefs.remove(PendingChatOpen.prefsKey);
        return;
      }
      _setPending(pending);
    } catch (e) {
      // ignore: avoid_print
      print('[CHAT] pending open restore failed error=$e');
    }
  }

  Future<void> storePendingOpen({
    required String conversationId,
    required bool compose,
    required bool needsJs,
  }) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    final pending = PendingChatOpen(
      conversationId: id,
      compose: compose,
      needsJs: needsJs,
      storedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _setPending(pending);
    chatTrace(compose ? 'pending Reply stored' : 'pending open stored', id, '');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PendingChatOpen.prefsKey,
        jsonEncode(pending.toJson()),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[CHAT] pending open persist failed conversation_id=$id error=$e');
    }
  }

  Future<void> clearPendingOpen({required String reason}) async {
    final current = _pendingOpen;
    if (current == null) return;
    _pendingOpen = null;
    pendingOpenListenable.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PendingChatOpen.prefsKey);
    } catch (_) {}
    chatTrace('pending open cleared', current.conversationId, reason);
  }

  void _setPending(PendingChatOpen pending) {
    _pendingOpen = pending;
    pendingOpenListenable.value = pending;
  }

  Future<void> _serialized(Future<void> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _removeLine(
    FlutterLocalNotificationsPlugin plugin,
    GridChatMessage message,
  ) async {
    final stacks = await _readStacks();
    final entry = stacks[message.conversationId];
    if (entry == null) {
      await plugin.cancel(message.notificationId, tag: message.notificationTag);
      return;
    }
    final lines = _linesFrom(entry)
      ..removeWhere((line) => line.messageId == message.messageId && message.messageId.isNotEmpty);
    if (lines.isEmpty || entry['locked'] == true) {
      stacks.remove(message.conversationId);
      await _writeStacks(stacks);
      final tag = (entry['tag'] ?? message.notificationTag).toString();
      await plugin.cancel(message.notificationId, tag: tag);
      return;
    }
    entry['lines'] = lines.map((line) => line.toJson()).toList();
    stacks[message.conversationId] = entry;
    await _writeStacks(stacks);
  }

  Future<void> _show(
    FlutterLocalNotificationsPlugin plugin,
    GridChatMessage message,
    List<GridChatMessageLine> lines, {
    required bool locked,
  }) async {
    final timeout = _timeoutAfter(message.expiresAt);
    final details = locked
        ? NotificationDetails(
            android: AndroidNotificationDetails(
              kMessagesChannelId,
              kMessagesChannelName,
              channelDescription: kMessagesChannelDescription,
              icon: 'ic_notification',
              importance: Importance.max,
              priority: Priority.high,
              visibility: NotificationVisibility.public,
              category: AndroidNotificationCategory.message,
              autoCancel: true,
              onlyAlertOnce: false,
              tag: message.notificationTag,
              timeoutAfter: timeout,
              color: const Color(0xFF0284C7),
              styleInformation: const BigTextStyleInformation(
                GridChatMessage.lockedLabel,
                contentTitle: GridChatMessage.lockedLabel,
              ),
              actions: const <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'reply',
                  'Reply',
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
              ],
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
              categoryIdentifier: 'messages_category',
            ),
          )
        : NotificationDetails(
            android: AndroidNotificationDetails(
              kMessagesChannelId,
              kMessagesChannelName,
              channelDescription: kMessagesChannelDescription,
              icon: 'ic_notification',
              importance: Importance.max,
              priority: Priority.high,
              visibility: NotificationVisibility.public,
              category: AndroidNotificationCategory.message,
              autoCancel: true,
              onlyAlertOnce: false,
              tag: message.notificationTag,
              timeoutAfter: timeout,
              color: const Color(0xFF0284C7),
              styleInformation: MessagingStyleInformation(
                const Person(name: 'You', key: 'self'),
                // For 1:1 chat (is_group = 0), conversationTitle must be null to avoid duplicate "Name: Name".
                // "Name: message" is only for group chats.
                conversationTitle:
                    message.isGroup ? groupConversationTitle(message) : null,
                groupConversation: message.isGroup,
                messages: lines
                    .map(
                      (line) => Message(
                        line.body.isNotEmpty
                            ? line.body
                            : defaultBodyForMessageType(line.messageType),
                        DateTime.fromMillisecondsSinceEpoch(line.atMs),
                        Person(
                          name: line.senderName.isNotEmpty
                              ? line.senderName
                              : message.senderName,
                          key: line.senderId.isNotEmpty
                              ? line.senderId
                              : message.senderId,
                        ),
                      ),
                    )
                    .toList(),
              ),
              actions: const <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'reply',
                  'Reply',
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
              ],
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
              categoryIdentifier: 'messages_category',
            ),
          );
    final title = locked
        ? GridChatMessage.lockedLabel
        : notificationTitle(message);
    final body = locked
        ? GridChatMessage.lockedLabel
        : formatNotificationBody(message);
    await plugin.show(
      message.notificationId,
      title,
      body,
      details,
      payload: jsonEncode(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'notification_type': 'message',
        'conversation_id': message.conversationId,
        'message_id': message.messageId,
        'locked': message.locked ? '1' : '0',
      }),
    );
  }

  static String? groupConversationTitle(GridChatMessage message) {
    if (!message.isGroup) return null;
    if (message.groupTitle.isNotEmpty) return message.groupTitle;
    if (message.title.isNotEmpty) return message.title;
    return 'Group Chat';
  }

  static String notificationTitle(GridChatMessage message) {
    if (!message.isGroup) {
      // On a 1:1 message notification, the title should be just the sender's name.
      if (message.senderName.isNotEmpty) return message.senderName;
      if (message.title.isNotEmpty) return message.title;
      return 'Circle Connect';
    }
    // For group chats, title should be the group title.
    if (message.groupTitle.isNotEmpty) return message.groupTitle;
    if (message.title.isNotEmpty) return message.title;
    if (message.senderName.isNotEmpty) return message.senderName;
    return 'Group Chat';
  }

  static String conversationTitle(GridChatMessage message) =>
      notificationTitle(message);

  /// Formats the notification line like WhatsApp:
  /// For 1:1 (is_group = 0): "message" (or media placeholder)
  /// For group (is_group = 1): "SenderName: message" (e.g. "Pavan Nagapuri: message")
  static String formatNotificationBody(GridChatMessage message) {
    final raw = message.body.trim();
    final content =
        raw.isNotEmpty ? raw : defaultBodyForMessageType(message.messageType);
    if (message.isGroup && message.senderName.isNotEmpty) {
      final prefix = '${message.senderName}:';
      if (content.toLowerCase().startsWith(prefix.toLowerCase())) {
        return content;
      }
      return '${message.senderName}: $content';
    }
    return content;
  }

  static String defaultBodyForMessageType(String type) {
    switch (type.toLowerCase().trim()) {
      case 'image':
      case 'photo':
        return '📷 Photo';
      case 'video':
        return '🎥 Video';
      case 'audio':
      case 'voice':
        return '🎤 Voice message';
      case 'file':
      case 'document':
      case 'pdf':
        return '📄 Document';
      default:
        return 'New message';
    }
  }

  static int? _timeoutAfter(DateTime? expiresAt) {
    if (expiresAt == null) return null;
    final remaining = expiresAt.difference(DateTime.now().toUtc()).inMilliseconds;
    if (remaining < 1000) return 1000;
    const maxTimeout = 12 * 60 * 60 * 1000;
    if (remaining > maxTimeout) return maxTimeout;
    return remaining;
  }

  List<GridChatMessageLine> _linesFrom(Map<String, dynamic>? entry) {
    final raw = entry?['lines'];
    if (raw is! List) return <GridChatMessageLine>[];
    return raw
        .map(GridChatMessageLine.fromJson)
        .whereType<GridChatMessageLine>()
        .toList();
  }

  Future<List<String>> _readSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(GridChatMessage.seenPrefsKey);
      if (raw == null || raw.isEmpty) return <String>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.map((item) => item.toString()).where((id) => id.isNotEmpty).toList();
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _rememberSeen(List<String> seen, String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty || seen.contains(id)) return;
    seen.add(id);
    if (seen.length > 200) {
      seen.removeRange(0, seen.length - 200);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(GridChatMessage.seenPrefsKey, jsonEncode(seen));
    } catch (_) {}
  }

  Future<Map<String, Map<String, dynamic>>> _readStacks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(GridChatMessage.stackPrefsKey);
      if (raw == null || raw.isEmpty) return <String, Map<String, dynamic>>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Map<String, dynamic>>{};
      final stacks = <String, Map<String, dynamic>>{};
      decoded.forEach((key, value) {
        if (value is Map) {
          stacks[key.toString()] = Map<String, dynamic>.from(value);
        }
      });
      return stacks;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  Future<void> _writeStacks(Map<String, Map<String, dynamic>> stacks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(GridChatMessage.stackPrefsKey, jsonEncode(stacks));
    } catch (_) {}
  }
}

const String kMessagesChannelId = 'grid_messages_v4';
const String kMessagesChannelName = 'Messages';
const String kMessagesChannelDescription =
    'Circle Connect chat message notifications';
