import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'incoming_call_service.dart';
import 'json_http.dart';

/// Call notification channel configured with system default ringtone and USAGE_NOTIFICATION_RINGTONE.
const AndroidNotificationChannel kCallsChannel = AndroidNotificationChannel(
  'grid_calls',
  'Incoming calls',
  description: 'Alerts for incoming Circle Connect calls',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

/// Message notification channel configured with system message sound.
const AndroidNotificationChannel kMessagesChannel = AndroidNotificationChannel(
  'grid_messages',
  'Messages',
  description: 'Circle Connect chat message notifications',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

/// Background notification response handler (runs in background isolate).
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;

  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final actionId = response.actionId ?? '';

    if (actionId == 'decline') {
      final call = IncomingCallData.fromJson(data);
      await IncomingCallService.instance.declineCall(call);
    } else if (actionId == 'mark_as_read') {
      await handleMarkAsReadFromNotification(data);
    } else if (actionId == 'reply') {
      final input = response.input ?? '';
      if (input.isNotEmpty) {
        await handleSendReplyFromNotification(data, input);
      }
    }
  } catch (e) {
    debugPrint('[PushBootstrap] notificationTapBackground error: $e');
  }
}

/// Top-level FCM background handler (must stay top-level for the isolate).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint('[PushBootstrap] Background Firebase.initializeApp: $e');
  }

  final data = Map<String, dynamic>.from(message.data);
  final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();

  final plugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    const InitializationSettings(
      android: androidInit,
      iOS: DarwinInitializationSettings(),
    ),
    onDidReceiveNotificationResponse: (response) {
      notificationTapBackground(response);
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(kMessagesChannel);
  await android?.createNotificationChannel(kCallsChannel);

  if (type == 'INCOMING_CALL' || type == 'CALL') {
    final call = IncomingCallData.fromJson(data);
    await showIncomingCallNotificationOnPlugin(plugin, call, rawData: data);
    return;
  }

  if (type == 'MISSED_CALL' || type == 'CALL_MISSED') {
    final call = IncomingCallData.fromJson(data);
    await showMissedCallNotificationOnPlugin(plugin, call, rawData: data);
    return;
  }

  if (type == 'CALL_HANDLED' ||
      type == 'CALL_CANCELLED' ||
      type == 'HANGUP') {
    final callId = (data['call_id'] ?? data['callId'] ?? '').toString();
    await plugin.cancel(callId.hashCode);
    return;
  }

  // Chat message or notification payload
  await showMessageNotificationOnPlugin(plugin, data, notification: message.notification);
}

/// Posts ringing call notification with FLAG_INSISTENT, 45s timeout, and Answer/Decline buttons.
Future<void> showIncomingCallNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  IncomingCallData call, {
  Map<String, dynamic>? rawData,
}) async {
  final payload = rawData != null ? jsonEncode(rawData) : jsonEncode(call.toJson());

  await plugin.show(
    call.callId.hashCode,
    call.callerName,
    call.body.isNotEmpty
        ? call.body
        : (call.isVideo ? 'Incoming video call' : 'Incoming voice call'),
    NotificationDetails(
      android: AndroidNotificationDetails(
        kCallsChannel.id,
        kCallsChannel.name,
        channelDescription: kCallsChannel.description,
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: true,
        timeoutAfter: 45000,
        additionalFlags: Int32List.fromList([4]), // Notification.FLAG_INSISTENT loops ringtone
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'decline',
            'Decline',
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'answer',
            'Answer',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    ),
    payload: payload,
  );
}

/// Posts missed call notification with Call back and Message action buttons.
Future<void> showMissedCallNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  IncomingCallData call, {
  Map<String, dynamic>? rawData,
}) async {
  // Cancel previous ringing notification with same callId
  await plugin.cancel(call.callId.hashCode);

  final payloadMap = rawData != null ? Map<String, dynamic>.from(rawData) : call.toJson();
  payloadMap['type'] = 'MISSED_CALL';

  await plugin.show(
    call.callId.hashCode,
    call.callerName,
    call.body.isNotEmpty
        ? call.body
        : (call.isVideo ? 'Missed video call' : 'Missed voice call'),
    NotificationDetails(
      android: AndroidNotificationDetails(
        kMessagesChannel.id,
        kMessagesChannel.name,
        channelDescription: kMessagesChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.missedCall,
        autoCancel: true,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'callback',
            'Call back',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'message',
            'Message',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    ),
    payload: jsonEncode(payloadMap),
  );
}

/// Posts chat message notification with inline Reply and Mark as read buttons.
Future<void> showMessageNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data, {
  RemoteNotification? notification,
}) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
  final notifId = int.tryParse(convId) ??
      (convId.isNotEmpty
          ? convId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final isLocked = data['locked'] == true || data['locked'] == 'true';
  final title = notification?.title ??
      (data['title'] ??
       data['caller_name'] ??
       data['sender_name'] ??
       data['name'] ??
       data['user_name'] ??
       data['sender'] ??
       'Circle Connect')
          .toString();
  final body = notification?.body ??
      (data['body'] ??
       data['message'] ??
       data['text'] ??
       data['content'] ??
       'New message')
          .toString();

  if (isLocked) {
    await plugin.show(
      notifId,
      'Circle Connect',
      'New message',
      NotificationDetails(
        android: AndroidNotificationDetails(
          kMessagesChannel.id,
          kMessagesChannel.name,
          channelDescription: kMessagesChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: jsonEncode(data),
    );
    return;
  }

  await plugin.show(
    notifId,
    title.isNotEmpty ? title : 'Circle Connect',
    body.isNotEmpty ? body : 'New message',
    NotificationDetails(
      android: AndroidNotificationDetails(
        kMessagesChannel.id,
        kMessagesChannel.name,
        channelDescription: kMessagesChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'reply',
            'Reply',
            showsUserInterface: true,
            inputs: <AndroidNotificationActionInput>[
              AndroidNotificationActionInput(label: 'Type a reply...'),
            ],
          ),
          AndroidNotificationAction(
            'mark_as_read',
            'Mark as read',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(),
    ),
    payload: jsonEncode(data),
  );
}

/// Sends Mark as read request to server with WebView cookies.
Future<void> handleMarkAsReadFromNotification(Map<String, dynamic> data) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
  final msgId = (data['message_id'] ?? data['messageId'] ?? '').toString();
  var targetUrl =
      (data['url'] ?? IncomingCallData.defaultCallUrl).toString().trim();
  if (targetUrl.isNotEmpty &&
      !targetUrl.startsWith('http://') &&
      !targetUrl.startsWith('https://')) {
    targetUrl =
        'https://efactor.tech/${targetUrl.replaceAll(RegExp(r'^/+'), '')}';
  }

  final cookies =
      await IncomingCallService.instance.getCookiesForUrl(targetUrl);
  final cleanUrl = targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
  final primaryUri = Uri.tryParse('$cleanUrl/api/chat/read');
  final originUri = Uri.tryParse(targetUrl);
  final fallbackUri = originUri != null
      ? Uri.tryParse('${originUri.origin}/index.php/grid-chat/api/chat/read')
      : null;

  final headers = <String, String>{
    'Content-Type': 'application/x-www-form-urlencoded',
    if (cookies.isNotEmpty) 'Cookie': cookies,
    if (IncomingCallService.instance.activeAccessToken != null)
      'Authorization':
          'Bearer ${IncomingCallService.instance.activeAccessToken}',
  };

  final bodyFields = <String, String>{
    'conversation_id': convId,
    'message_id': msgId,
  };

  try {
    if (primaryUri != null) {
      final resp = await http
          .post(primaryUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    }
    if (fallbackUri != null && fallbackUri != primaryUri) {
      await http
          .post(fallbackUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
    }
  } catch (e) {
    debugPrint('[PushBootstrap] markAsRead error: $e');
  }
}

/// Sends Reply request to server with WebView cookies.
Future<void> handleSendReplyFromNotification(
  Map<String, dynamic> data,
  String replyText,
) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
  var targetUrl =
      (data['url'] ?? IncomingCallData.defaultCallUrl).toString().trim();
  if (targetUrl.isNotEmpty &&
      !targetUrl.startsWith('http://') &&
      !targetUrl.startsWith('https://')) {
    targetUrl =
        'https://efactor.tech/${targetUrl.replaceAll(RegExp(r'^/+'), '')}';
  }
  final clientId =
      'reply_${DateTime.now().millisecondsSinceEpoch}_${convId.hashCode}';

  final cookies =
      await IncomingCallService.instance.getCookiesForUrl(targetUrl);
  final cleanUrl = targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
  final primaryUri = Uri.tryParse('$cleanUrl/api/chat/send');
  final originUri = Uri.tryParse(targetUrl);
  final fallbackUri = originUri != null
      ? Uri.tryParse('${originUri.origin}/index.php/grid-chat/api/chat/send')
      : null;

  final headers = <String, String>{
    'Content-Type': 'application/x-www-form-urlencoded',
    if (cookies.isNotEmpty) 'Cookie': cookies,
    if (IncomingCallService.instance.activeAccessToken != null)
      'Authorization':
          'Bearer ${IncomingCallService.instance.activeAccessToken}',
  };

  final bodyFields = <String, String>{
    'conversation_id': convId,
    'message_type': 'text',
    'body': replyText,
    'client_id': clientId,
  };

  try {
    if (primaryUri != null) {
      final resp = await http
          .post(primaryUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    }
    if (fallbackUri != null && fallbackUri != primaryUri) {
      await http
          .post(fallbackUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
    }
  } catch (e) {
    debugPrint('[PushBootstrap] sendReply error: $e');
  }
}

/// Wires FCM + local notifications into [IncomingCallService].
///
/// Requires `android/app/google-services.json` and
/// `ios/Runner/GoogleService-Info.plist`. Without them, [initialize] no-ops
/// so the app still boots.
class PushNotificationBootstrap {
  PushNotificationBootstrap._();
  static final PushNotificationBootstrap instance =
      PushNotificationBootstrap._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  var _ready = false;
  Future<void>? _initFuture;
  StreamSubscription<String>? _tokenSub;

  bool get isReady => _ready;

  Future<void> initialize() async {
    if (_ready || kIsWeb) return;
    if (_initFuture != null) return _initFuture;
    _initFuture = _doInitialize();
    return _initFuture;
  }

  Future<void> _doInitialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (e) {
      logDebug(
        '[PushBootstrap] Firebase not configured ($e). '
        'Copy google-services.json and GoogleService-Info.plist then rebuild.',
      );
      _initFuture = null;
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _initLocalNotifications();
    await requestNotificationPermission();

    final messaging = FirebaseMessaging.instance;
    await _captureToken(messaging);

    _tokenSub = messaging.onTokenRefresh.listen((refreshed) {
      IncomingCallService.instance.setDeviceToken(refreshed);
      unawaited(_syncTokenIfLoggedIn(refreshed));
    });

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpened);
    try {
      final initial = await messaging
          .getInitialMessage()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (initial != null) {
        _onMessageOpened(initial);
      }
    } catch (e) {
      logDebug('[PushBootstrap] getInitialMessage error: $e');
    }

    _ready = true;
    logDebug('[PushBootstrap] READY');
  }

  /// Call after login (or anytime) to refresh OS permission + FCM token.
  Future<void> requestNotificationPermission() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      }
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: true,
        provisional: false,
      );
      if (Platform.isIOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (e) {
      logDebug('[PushBootstrap] permission request failed: $e');
    }
  }

  /// Ensures a token is present and synced after authentication.
  Future<void> ensureTokenSynced({
    required String userId,
    required String accessToken,
  }) async {
    if (!_ready) {
      await initialize();
    }
    await requestNotificationPermission();
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        logDebug('[PushBootstrap] FCM TOKEN: $token');
        await IncomingCallService.instance.syncDeviceTokenOnLogin(
          userId: userId,
          accessToken: accessToken,
          tokenOverride: token,
        );
      } else {
        logDebug('[PushBootstrap] No FCM token after login');
      }
    } catch (e) {
      logDebug('[PushBootstrap] ensureTokenSynced failed: $e');
    }
  }

  Future<void> _captureToken(FirebaseMessaging messaging) async {
    try {
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        logDebug('[PushBootstrap] FCM token acquired (${token.length} chars)');
        logDebug('[PushBootstrap] FCM TOKEN: $token');
      }
    } catch (e) {
      logDebug('[PushBootstrap] getToken failed: $e');
    }
  }

  Future<void> _syncTokenIfLoggedIn(String token) async {
    final uid = IncomingCallService.instance.activeUserId;
    final access = IncomingCallService.instance.activeAccessToken;
    if (uid == null || access == null || access.isEmpty) return;
    await IncomingCallService.instance.syncDeviceTokenOnLogin(
      userId: uid.toString(),
      accessToken: access,
      tokenOverride: token,
    );
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(kMessagesChannel);
    await androidPlugin?.createNotificationChannel(kCallsChannel);
  }

  void _onForegroundMessage(RemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();

    if (type == 'INCOMING_CALL' || type == 'CALL') {
      final call = IncomingCallData.fromJson(data);
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(showIncomingCallNotification(call));
      return;
    }
    if (type == 'MISSED_CALL' || type == 'CALL_MISSED') {
      final call = IncomingCallData.fromJson(data);
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(showMissedCallNotification(call));
      return;
    }
    if (type == 'CALL_HANDLED' ||
        type == 'CALL_CANCELLED' ||
        type == 'HANGUP') {
      final callId = (data['call_id'] ?? data['callId'] ?? '').toString();
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(handleCallHandled(callId));
      return;
    }
    unawaited(showMessageNotificationOnPlugin(_local, data, notification: message.notification));
  }

  void _onMessageOpened(RemoteMessage message) {
    _handlePayloadMap(Map<String, dynamic>.from(message.data));
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type =
          (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
      final actionId = response.actionId;

      if (actionId == 'decline') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.declineCall(call);
        return;
      }
      if (actionId == 'answer') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.answerCall(call);
        return;
      }
      if (actionId == 'callback') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.callbackCall(call);
        return;
      }
      if (actionId == 'message') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.messageCall(call);
        return;
      }
      if (actionId == 'mark_as_read') {
        await handleMarkAsReadFromNotification(data);
        final convId = (data['conversation_id'] ??
                data['conversationId'] ??
                '')
            .toString();
        final notifId = int.tryParse(convId) ?? convId.hashCode;
        await _local.cancel(notifId);
        return;
      }
      if (actionId == 'reply') {
        final input = response.input ?? '';
        if (input.isNotEmpty) {
          await handleSendReplyFromNotification(data, input);
          final convId = (data['conversation_id'] ??
                  data['conversationId'] ??
                  '')
              .toString();
          final notifId = int.tryParse(convId) ?? convId.hashCode;
          await _local.cancel(notifId);
        }
        return;
      }

      // No button clicked -> user tapped notification banner / full-screen intent
      if (type == 'INCOMING_CALL' || type == 'CALL') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.openCallScreenWithoutAction(call);
      } else if (type == 'MISSED_CALL') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.openCallScreenWithoutAction(call);
      } else {
        // Message notification tap
        final convId = (data['conversation_id'] ??
                data['conversationId'] ??
                '')
            .toString();
        final url = (data['url'] ?? '').toString();
        await IncomingCallService.instance.openChatFromNotification(
          conversationId: convId,
          url: url,
        );
      }
    } catch (e) {
      debugPrint('[PushBootstrap] _handleNotificationResponse error: $e');
    }
  }

  void _handlePayloadMap(Map<String, dynamic> data) {
    final type =
        (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
    if (type == 'INCOMING_CALL' || type == 'CALL') {
      final call = IncomingCallData.fromJson(data);
      unawaited(
        IncomingCallService.instance.openCallScreenWithoutAction(call),
      );
      return;
    }
    if (type == 'MISSED_CALL') {
      final call = IncomingCallData.fromJson(data);
      unawaited(
        IncomingCallService.instance.openCallScreenWithoutAction(call),
      );
      return;
    }
    final convId =
        (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
    final url = (data['url'] ?? '').toString();
    unawaited(
      IncomingCallService.instance.openChatFromNotification(
        conversationId: convId,
        url: url,
      ),
    );
  }

  /// Public API called by [IncomingCallService] and [GridInAppWebViewPage].
  Future<void> showIncomingCallNotification(IncomingCallData call) async {
    try {
      await showIncomingCallNotificationOnPlugin(_local, call);
    } catch (e) {
      debugPrint('[PushBootstrap] showIncomingCallNotification error: $e');
    }
  }

  Future<void> showMissedCallNotification(IncomingCallData call) async {
    try {
      await showMissedCallNotificationOnPlugin(_local, call);
    } catch (e) {
      debugPrint('[PushBootstrap] showMissedCallNotification error: $e');
    }
  }

  Future<void> handleCallHandled(String callId) async {
    try {
      await _local.cancel(callId.hashCode);
    } catch (_) {}
  }

  Future<void> cancelCallNotification(String callId) async {
    try {
      await _local.cancel(callId.hashCode);
    } catch (_) {}
  }

  Future<void> clearChatNotifications(String conversationId) async {
    try {
      final notifId = int.tryParse(conversationId) ?? conversationId.hashCode;
      await _local.cancel(notifId);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
