import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Notification channel for Professional Space (GRID) social activity, posts,
/// comments, connections, and messages.
const AndroidNotificationChannel kGridActivityChannel =
    AndroidNotificationChannel(
  'grid_activity',
  'Professional Space',
  description:
      'Notifications for posts, comments, connections, and activity in Professional Space',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

/// Safely validates that a URL belongs to the `efactor.tech` domain.
bool isSafeEfactorUrl(String url) {
  final clean = url.trim();
  if (clean.isEmpty) return false;
  final uri = Uri.tryParse(clean);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == 'efactor.tech' || host.endsWith('.efactor.tech');
}

/// Callback signature allowing tests to capture posted notifications cleanly
/// without invoking native platform channels.
typedef ProfessionalSpaceShowCallback = Future<void> Function(
  int id,
  String? title,
  String? body,
  NotificationDetails details, {
  String? payload,
});

/// One line item retained inside a Professional Space thread's Android
/// `MessagingStyle` stack.
class ProfessionalSpaceMessageLine {
  const ProfessionalSpaceMessageLine({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.atMs,
  });

  final String messageId;
  final String senderId;
  final String senderName;
  final String body;
  final int atMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'message_id': messageId,
        'sender_id': senderId,
        'sender_name': senderName,
        'body': body,
        'at_ms': atMs,
      };

  static ProfessionalSpaceMessageLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at_ms'];
    return ProfessionalSpaceMessageLine(
      messageId: (raw['message_id'] ?? '').toString(),
      senderId: (raw['sender_id'] ?? '').toString(),
      senderName: (raw['sender_name'] ?? '').toString(),
      body: (raw['body'] ?? '').toString(),
      atMs: at is int ? at : int.tryParse(at?.toString() ?? '') ?? 0,
    );
  }
}

/// Parsed metadata for a Professional Space push notification.
class ProfessionalSpacePushSpec {
  const ProfessionalSpacePushSpec({
    required this.tag,
    required this.notifId,
    required this.title,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.messageId,
    required this.targetUrl,
    required this.avatarUrl,
    required this.isGroupConversation,
    required this.receivedAtMs,
  });

  static final RegExp _messageFromPrefix = RegExp(
    r'^(?:new\s+)?message\s+from\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _nonAlphaNum = RegExp(r'[^a-z0-9]+');

  final String tag;
  final int notifId;
  final String title;
  final String senderId;
  final String senderName;
  final String body;
  final String messageId;
  final String targetUrl;
  final String avatarUrl;
  final bool isGroupConversation;
  final int receivedAtMs;

  /// Parses push [data] and optional FCM [notification] into a normalized spec.
  static ProfessionalSpacePushSpec parse(
    Map<String, dynamic> data, {
    String? notificationTitle,
    String? notificationBody,
    int? nowMs,
  }) {
    final rawTitle = (notificationTitle ??
            data['title'] ??
            data['actor_name'] ??
            'Professional Space')
        .toString()
        .trim();
    final title = rawTitle.isNotEmpty ? rawTitle : 'Professional Space';

    final rawActor = (data['actor_name'] ??
            data['actorName'] ??
            data['sender_name'] ??
            data['senderName'] ??
            data['name'] ??
            data['user_name'] ??
            '')
        .toString()
        .trim();
    final senderName = _resolveSenderName(rawActor, title);

    final rawBody = (notificationBody ??
            data['body'] ??
            data['text'] ??
            data['message'] ??
            '')
        .toString()
        .trim();
    final body = rawBody.isNotEmpty ? rawBody : title;

    final targetUrl =
        (data['target_url'] ?? data['targetUrl'] ?? data['url'] ?? '')
            .toString()
            .trim();
    final postId =
        (data['post_id'] ?? data['postId'] ?? '').toString().trim();
    final explicitGroup = _isTruthy(data['is_group'] ?? data['isGroup']);
    final isGroupConversation = explicitGroup || postId.isNotEmpty;

    final tag = resolveTag(
      data,
      targetUrl: targetUrl,
      senderName: senderName,
      postId: postId,
    );
    final notifId = tag.hashCode.abs();

    final senderIdRaw = (data['sender_id'] ??
            data['senderId'] ??
            data['actor_id'] ??
            data['actorId'] ??
            '')
        .toString()
        .trim();
    final senderId =
        senderIdRaw.isNotEmpty ? senderIdRaw : senderName.toLowerCase();

    final messageId = (data['message_id'] ??
            data['messageId'] ??
            data['msg_id'] ??
            data['msgId'] ??
            data['notification_id'] ??
            data['id'] ??
            '')
        .toString()
        .trim();

    final avatarUrl =
        (data['actor_avatar'] ?? data['sender_avatar'] ?? data['avatar'] ?? '')
            .toString()
            .trim();

    return ProfessionalSpacePushSpec(
      tag: tag,
      notifId: notifId,
      title: isGroupConversation ? title : senderName,
      senderId: senderId,
      senderName: senderName,
      body: body,
      messageId: messageId,
      targetUrl: targetUrl,
      avatarUrl: avatarUrl,
      isGroupConversation: isGroupConversation,
      receivedAtMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Resolves a deterministic per-thread / per-sender tag so consecutive
  /// messages from the same sender stack while different senders stay separate.
  static String resolveTag(
    Map<String, dynamic> data, {
    String? targetUrl,
    String? senderName,
    String? postId,
  }) {
    final explicitTag = (data['tag'] ?? '').toString().trim();
    if (explicitTag.isNotEmpty) return explicitTag;

    for (final key in const <String>[
      'conversation_id',
      'conversationId',
      'thread_id',
      'threadId',
      'chat_id',
      'chatId',
    ]) {
      final val = (data[key] ?? '').toString().trim();
      if (val.isNotEmpty) return 'grid_chat_$val';
    }

    final resolvedPostId = (postId ?? data['post_id'] ?? data['postId'] ?? '')
        .toString()
        .trim();
    if (resolvedPostId.isNotEmpty) return 'grid_post_$resolvedPostId';

    for (final key in const <String>[
      'sender_id',
      'senderId',
      'actor_id',
      'actorId',
    ]) {
      final val = (data[key] ?? '').toString().trim();
      if (val.isNotEmpty) return 'grid_sender_$val';
    }

    final url = (targetUrl ??
            data['target_url'] ??
            data['targetUrl'] ??
            data['url'] ??
            '')
        .toString()
        .trim();
    final uri = url.isNotEmpty ? Uri.tryParse(url) : null;
    if (uri != null && uri.queryParameters.isNotEmpty) {
      for (final param in const <String>[
        'conversation_id',
        'conversation',
        'thread_id',
        'thread',
        'chat_id',
        'chat',
        'user_id',
        'user',
        'sender_id',
        'post_id',
        'post',
      ]) {
        final val = uri.queryParameters[param]?.trim() ?? '';
        if (val.isNotEmpty) return 'grid_${param}_$val';
      }
    }

    final actor = (senderName ?? '').trim().toLowerCase();
    if (actor.isNotEmpty && actor != 'professional space') {
      final slug = actor
          .replaceAll(_nonAlphaNum, '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      if (slug.isNotEmpty) return 'grid_actor_$slug';
    }

    return 'grid_activity';
  }

  static String _resolveSenderName(String rawActor, String title) {
    if (rawActor.isNotEmpty) return rawActor;
    final match = _messageFromPrefix.firstMatch(title);
    if (match != null) {
      final extracted = (match.group(1) ?? '').trim();
      if (extracted.isNotEmpty) return extracted;
    }
    return title;
  }

  static bool _isTruthy(Object? raw) {
    if (raw == true || raw == 1) return true;
    final text = raw?.toString().trim().toLowerCase() ?? '';
    return text == '1' || text == 'true' || text == 'yes';
  }
}

/// Persists unread Professional Space notification lines per thread/sender and
/// renders them using Android `MessagingStyleInformation` (giving WhatsApp-like
/// multi-message stacking and the `Now ^` expand/collapse chevron).
class ProfessionalSpaceNotifications {
  ProfessionalSpaceNotifications._();

  static final ProfessionalSpaceNotifications instance =
      ProfessionalSpaceNotifications._();

  static const String stackPrefsKey = 'efactor_professional_space_stacks_v1';
  static const int maxLines = 8;
  static const int maxThreads = 24;

  Future<void> _queue = Future<void>.value();

  /// Presents a Professional Space push notification, appending it to its
  /// persisted thread stack so consecutive messages stack rather than overwrite.
  Future<void> present(
    FlutterLocalNotificationsPlugin plugin, {
    required Map<String, dynamic> data,
    String? notificationTitle,
    String? notificationBody,
    int? nowMs,
    http.Client? httpClient,
    ProfessionalSpaceShowCallback? showOverride,
  }) {
    return _serialized(() async {
      final spec = ProfessionalSpacePushSpec.parse(
        data,
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
        nowMs: nowMs,
      );

      final stacks = await _readStacks();
      final existing = stacks[spec.tag];
      final previous = _linesFrom(existing);
      final isDup = spec.messageId.isNotEmpty &&
          previous.any((line) => line.messageId == spec.messageId);

      final lines = List<ProfessionalSpaceMessageLine>.from(previous);
      if (!isDup) {
        lines.add(
          ProfessionalSpaceMessageLine(
            messageId: spec.messageId,
            senderId: spec.senderId,
            senderName: spec.senderName,
            body: spec.body,
            atMs: spec.receivedAtMs,
          ),
        );
        if (lines.length > maxLines) {
          lines.removeRange(0, lines.length - maxLines);
        }
      }

      // Refresh insertion order for LRU eviction when too many threads stack.
      stacks.remove(spec.tag);
      stacks[spec.tag] = <String, dynamic>{
        'title': spec.title,
        'is_group': spec.isGroupConversation,
        'lines': lines.map((line) => line.toJson()).toList(),
      };
      while (stacks.length > maxThreads) {
        stacks.remove(stacks.keys.first);
      }
      await _writeStacks(stacks);

      final avatarBytes = await _fetchAvatarBytes(
        spec.avatarUrl,
        httpClient: httpClient,
      );
      final details = buildNotificationDetails(
        spec,
        lines,
        avatarBytes: avatarBytes,
      );

      final payloadMap = <String, dynamic>{
        'type': 'PROFESSIONAL_SPACE_EVENT',
        'target_url': spec.targetUrl,
        'url': spec.targetUrl,
        ...data,
        'tag': spec.tag,
      };
      final encodedPayload = jsonEncode(payloadMap);

      if (showOverride != null) {
        await showOverride(
          spec.notifId,
          spec.title,
          spec.body,
          details,
          payload: encodedPayload,
        );
      } else {
        await plugin.show(
          spec.notifId,
          spec.title,
          spec.body,
          details,
          payload: encodedPayload,
        );
      }
    });
  }

  /// Builds expandable Android `MessagingStyleInformation` + iOS details for
  /// Professional Space notifications (with no action buttons).
  NotificationDetails buildNotificationDetails(
    ProfessionalSpacePushSpec spec,
    List<ProfessionalSpaceMessageLine> lines, {
    Uint8List? avatarBytes,
  }) {
    final ByteArrayAndroidBitmap? largeIconBitmap =
        (avatarBytes != null && avatarBytes.isNotEmpty)
            ? ByteArrayAndroidBitmap(avatarBytes)
            : null;
    final ByteArrayAndroidIcon? personIcon =
        (avatarBytes != null && avatarBytes.isNotEmpty)
            ? ByteArrayAndroidIcon(avatarBytes)
            : null;

    final effectiveLines = lines.isNotEmpty
        ? lines
        : <ProfessionalSpaceMessageLine>[
            ProfessionalSpaceMessageLine(
              messageId: spec.messageId,
              senderId: spec.senderId,
              senderName: spec.senderName,
              body: spec.body,
              atMs: spec.receivedAtMs,
            ),
          ];

    final messagingStyle = MessagingStyleInformation(
      const Person(name: 'You', key: 'self'),
      // For 1:1 messages, null avoids repeating "Sender: Sender".
      conversationTitle: spec.isGroupConversation ? spec.title : null,
      groupConversation: spec.isGroupConversation,
      messages: effectiveLines
          .map(
            (line) => Message(
              line.body.isNotEmpty ? line.body : spec.title,
              DateTime.fromMillisecondsSinceEpoch(line.atMs),
              Person(
                name: line.senderName.isNotEmpty
                    ? line.senderName
                    : spec.senderName,
                key: line.senderId.isNotEmpty ? line.senderId : spec.senderId,
                icon: personIcon,
              ),
            ),
          )
          .toList(),
    );

    final androidDetails = AndroidNotificationDetails(
      kGridActivityChannel.id,
      kGridActivityChannel.name,
      channelDescription: kGridActivityChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.public,
      category: spec.isGroupConversation
          ? AndroidNotificationCategory.social
          : AndroidNotificationCategory.message,
      icon: 'ic_notification',
      largeIcon: largeIconBitmap,
      tag: spec.tag,
      autoCancel: true,
      onlyAlertOnce: false,
      playSound: true,
      enableVibration: true,
      styleInformation: messagingStyle,
      // Strictly NO action buttons (no reply, mark as read, mute)
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    return NotificationDetails(android: androidDetails, iOS: iosDetails);
  }

  /// Clears a single thread stack by [tag].
  Future<void> clearTag(String tag) {
    final clean = tag.trim();
    if (clean.isEmpty) return Future<void>.value();
    return _serialized(() async {
      final stacks = await _readStacks();
      if (stacks.remove(clean) != null) {
        await _writeStacks(stacks);
      }
    });
  }

  /// Clears the persisted stack corresponding to tapped push [data].
  Future<void> clearForData(Map<String, dynamic> data) {
    final spec = ProfessionalSpacePushSpec.parse(data);
    return clearTag(spec.tag);
  }

  /// Clears all persisted Professional Space notification stacks.
  Future<void> clearAll() {
    return _serialized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(stackPrefsKey);
      } catch (_) {}
    });
  }

  Future<Uint8List?> _fetchAvatarBytes(
    String avatarUrl, {
    http.Client? httpClient,
  }) async {
    if (avatarUrl.isEmpty || !isSafeEfactorUrl(avatarUrl)) return null;
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final res = await client
          .get(Uri.parse(avatarUrl))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        return res.bodyBytes;
      }
    } catch (_) {
    } finally {
      if (ownsClient) client.close();
    }
    return null;
  }

  Future<void> _serialized(Future<void> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  List<ProfessionalSpaceMessageLine> _linesFrom(Map<String, dynamic>? entry) {
    final raw = entry?['lines'];
    if (raw is! List) return <ProfessionalSpaceMessageLine>[];
    return raw
        .map(ProfessionalSpaceMessageLine.fromJson)
        .whereType<ProfessionalSpaceMessageLine>()
        .toList();
  }

  Future<Map<String, Map<String, dynamic>>> _readStacks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final raw = prefs.getString(stackPrefsKey);
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
      await prefs.setString(stackPrefsKey, jsonEncode(stacks));
    } catch (_) {}
  }
}
