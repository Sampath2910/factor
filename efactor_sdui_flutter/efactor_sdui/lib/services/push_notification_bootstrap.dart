import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'incoming_call_service.dart';
import 'json_http.dart';
import '../auth_sdui/auth_secure_storage.dart';
import '../grid_sdui/grid_live_location_service.dart';

/// Call notification channel configured with system default ringtone and USAGE_NOTIFICATION_RINGTONE.
const AndroidNotificationChannel kCallsChannel = AndroidNotificationChannel(
  'grid_calls_v4',
  'Incoming calls',
  description: 'Alerts for incoming Circle Connect calls',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

/// Message notification channel configured with system message sound.
const AndroidNotificationChannel kMessagesChannel = AndroidNotificationChannel(
  'grid_messages_v4',
  'Messages',
  description: 'Circle Connect chat message notifications',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

/// Background notification response handler (runs in background isolate).
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  final actionId = response.actionId ?? '';
  if (actionId == 'stop_live_location') {
    await GridLiveLocationService.instance.stopAll(postStop: true);
    return;
  }

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

  // Explicit, un-swallowable terminal diagnostic banner
  // ignore: avoid_print
  print('''
========================================================================
[FCM_DEBUG] >>> BACKGROUND FCM MESSAGE ARRIVED ON ANDROID! <<<
Message ID: ${message.messageId}
Detected Event/Type: $type
Data Payload: $data
System Notification Tray Payload: ${message.notification?.title} | ${message.notification?.body}
========================================================================
''');

  final plugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('ic_notification');
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
  for (final oldId in const [
    'grid_calls',
    'grid_calls_v2',
    'grid_calls_v3',
    'grid_messages',
    'grid_messages_v2',
    'grid_messages_v3',
  ]) {
    try {
      await android?.deleteNotificationChannel(oldId);
    } catch (_) {}
  }
  await android?.createNotificationChannel(kMessagesChannel);
  await android?.createNotificationChannel(kCallsChannel);

  final isChatMessage = type == 'CHAT_MESSAGE' ||
      type == 'MESSAGE' ||
      type == 'NEW_MESSAGE';

  final isCall = !isChatMessage &&
      (type == 'INCOMING_CALL' ||
          type == 'CALL' ||
          type == 'CALL_REQUEST' ||
          type == 'RINGING' ||
          type == 'VOIP_CALL' ||
          data.containsKey('call_id') ||
          data.containsKey('callId'));

  if (isCall) {
    final call = IncomingCallData.fromJson(data);
    // ignore: avoid_print
    print('[FCM_DEBUG] Rendering background incoming call notification for caller: ${call.callerName} (callId: ${call.callId})');
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
      type == 'CANCEL_CALL' ||
      type == 'REJECTED' ||
      type == 'HANGUP') {
    final callId = (data['call_id'] ?? data['callId'] ?? '').toString();
    await plugin.cancel(callId.hashCode.abs());
    return;
  }

  // Chat message or notification payload
  // ignore: avoid_print
  print('[FCM_DEBUG] Rendering chat message notification: $data');
  await showMessageNotificationOnPlugin(plugin, data, notification: message.notification);
}

/// Posts ringing call notification with FLAG_INSISTENT, 45s timeout, and Answer/Decline buttons.
Future<void> showIncomingCallNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  IncomingCallData call, {
  Map<String, dynamic>? rawData,
}) async {
  final payload = rawData != null ? jsonEncode(rawData) : jsonEncode(call.toJson());
  final notifId = (call.callId.isNotEmpty
          ? call.callId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .abs();
  final callSubtitle = call.body.isNotEmpty
      ? call.body
      : (call.isVideo ? 'Incoming video call' : 'Incoming voice call');

  await plugin.show(
    notifId,
    call.callerName,
    callSubtitle,
    NotificationDetails(
      android: AndroidNotificationDetails(
        kCallsChannel.id,
        kCallsChannel.name,
        channelDescription: kCallsChannel.description,
        icon: 'ic_notification',
        importance: Importance.max,
        priority: Priority.max,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: true,
        timeoutAfter: 45000,
        color: const Color(0xFF0284C7),
        ticker: 'Incoming call from ${call.callerName}',
        additionalFlags: Int32List.fromList([4]), // Notification.FLAG_INSISTENT loops ringtone
        styleInformation: BigTextStyleInformation(
          callSubtitle,
          htmlFormatBigText: true,
          contentTitle: call.callerName,
          htmlFormatContentTitle: true,
          summaryText: call.isVideo ? 'Video Call' : 'Voice Call',
          htmlFormatSummaryText: true,
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'decline',
            'Decline',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'answer',
            'Answer',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
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
  final notifId = (call.callId.isNotEmpty
          ? call.callId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .abs();
  // Cancel previous ringing notification with same callId
  await plugin.cancel(notifId);
  await plugin.cancel(call.callId.hashCode.abs());

  final payloadMap = rawData != null ? Map<String, dynamic>.from(rawData) : call.toJson();
  payloadMap['type'] = 'MISSED_CALL';

  final subtitle = call.body.isNotEmpty
      ? call.body
      : (call.isVideo ? 'Missed video call' : 'Missed voice call');

  await plugin.show(
    notifId,
    call.callerName,
    subtitle,
    NotificationDetails(
      android: AndroidNotificationDetails(
        kMessagesChannel.id,
        kMessagesChannel.name,
        channelDescription: kMessagesChannel.description,
        icon: 'ic_notification',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.missedCall,
        autoCancel: true,
        color: const Color(0xFFEF4444),
        styleInformation: BigTextStyleInformation(
          subtitle,
          contentTitle: call.callerName,
          summaryText: 'Missed Call',
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'callback',
            'Call back',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'message',
            'Message',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
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
  final rawNotifId = int.tryParse(convId) ??
      (convId.isNotEmpty
          ? convId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final notifId = rawNotifId.abs();

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

  final effectiveTitle = title.isNotEmpty ? title : 'Circle Connect';
  final effectiveBody = body.isNotEmpty ? body : 'New message';

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
          icon: 'ic_notification',
          importance: Importance.max,
          priority: Priority.high,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFF0284C7),
          styleInformation: const BigTextStyleInformation(
            'New message',
            contentTitle: 'Circle Connect',
            summaryText: 'Locked Content',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
    return;
  }

  await plugin.show(
    notifId,
    effectiveTitle,
    effectiveBody,
    NotificationDetails(
      android: AndroidNotificationDetails(
        kMessagesChannel.id,
        kMessagesChannel.name,
        channelDescription: kMessagesChannel.description,
        icon: 'ic_notification',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.message,
        autoCancel: true,
        color: const Color(0xFF0284C7),
        styleInformation: BigTextStyleInformation(
          effectiveBody,
          contentTitle: effectiveTitle,
          summaryText: 'Circle Connect Chat',
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'reply',
            'Reply',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            inputs: <AndroidNotificationActionInput>[
              AndroidNotificationActionInput(label: 'Type a reply...'),
            ],
          ),
          AndroidNotificationAction(
            'mark_as_read',
            'Mark as read',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
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
  String? _activeConversationId;

  bool get isReady => _ready;
  String? get activeConversationId => _activeConversationId;

  /// Sets the currently active conversation in Circle Connect chat.
  /// When set, foreground notification banners for this conversation are suppressed.
  void setActiveConversationId(String? conversationId) {
    final cleanId = conversationId?.trim();
    _activeConversationId = (cleanId == null || cleanId.isEmpty) ? null : cleanId;
    debugPrint('[PushBootstrap] Active conversation set to: $_activeConversationId');
    if (_activeConversationId != null) {
      unawaited(clearChatNotifications(_activeConversationId!));
    }
  }

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

    try {
      final launchDetails = await _local.getNotificationAppLaunchDetails();
      if (launchDetails != null &&
          launchDetails.didNotificationLaunchApp &&
          launchDetails.notificationResponse != null) {
        logDebug(
          '[PushBootstrap] App launched from notification action: '
          '${launchDetails.notificationResponse?.actionId} '
          'payload: ${launchDetails.notificationResponse?.payload}',
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleNotificationResponse(launchDetails.notificationResponse!);
        });
      }
    } catch (e) {
      logDebug('[PushBootstrap] getNotificationAppLaunchDetails error: $e');
    }

    try {
      if (IncomingCallService.instance.activeAccessToken == null) {
        final session = await AuthSecureStorage().readSession();
        final token = session['accessToken'];
        final uid = session['userId'];
        if (token != null && token.isNotEmpty) {
          IncomingCallService.instance.activeAccessToken = token;
          if (uid != null) {
            IncomingCallService.instance.activeUserId = int.tryParse(uid);
          }
          final fcmToken = IncomingCallService.instance.deviceToken;
          if (fcmToken != null && fcmToken.isNotEmpty && uid != null) {
            unawaited(
              IncomingCallService.instance.syncDeviceTokenOnLogin(
                userId: uid,
                accessToken: token,
                tokenOverride: fcmToken,
              ),
            );
          }
        }
      }
    } catch (e) {
      logDebug('[PushBootstrap] Cold start session restore error: $e');
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
      if (!kIsWeb && Platform.isIOS) {
        // iOS requires APNs token to be acquired first before FCM token can be generated
        int retries = 0;
        while (retries < 6) {
          final apns = await FirebaseMessaging.instance.getAPNSToken();
          if (apns != null && apns.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          retries++;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        // ignore: avoid_print
        print('''
========================================================================
[FCM_DEBUG] DEVICE FCM TOKEN ACQUIRED FOR USER: $userId
Token: $token
------------------------------------------------------------------------
To test incoming call notification directly from terminal on Mac:
curl -X POST "https://fcm.googleapis.com/fcm/send" \\
  -H "Authorization: key=YOUR_FIREBASE_SERVER_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"to":"$token","priority":"high","data":{"type":"INCOMING_CALL","caller_name":"Direct Terminal Test","call_id":"test_${DateTime.now().millisecondsSinceEpoch}","call_type":"video"}}'
========================================================================
''');
        await IncomingCallService.instance.syncDeviceTokenOnLogin(
          userId: userId,
          accessToken: accessToken,
          tokenOverride: token,
        );
      } else {
        // ignore: avoid_print
        print('[FCM_DEBUG] No FCM token returned from Firebase after login.');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM_DEBUG] ensureTokenSynced failed: $e');
    }
  }

  Future<void> _captureToken(FirebaseMessaging messaging) async {
    try {
      if (!kIsWeb && Platform.isIOS) {
        int retries = 0;
        while (retries < 6) {
          final apns = await messaging.getAPNSToken();
          if (apns != null && apns.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          retries++;
        }
      }
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        // ignore: avoid_print
        print('[FCM_DEBUG] Startup FCM token captured (${token.length} chars): $token');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM_DEBUG] Startup getToken failed: $e');
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
    const android = AndroidInitializationSettings('ic_notification');
    const ios = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final oldId in const [
      'grid_calls',
      'grid_calls_v2',
      'grid_calls_v3',
      'grid_messages',
      'grid_messages_v2',
      'grid_messages_v3',
    ]) {
      try {
        await androidPlugin?.deleteNotificationChannel(oldId);
      } catch (_) {}
    }
    await androidPlugin?.createNotificationChannel(kMessagesChannel);
    await androidPlugin?.createNotificationChannel(kCallsChannel);
  }

  void _onForegroundMessage(RemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();

    // ignore: avoid_print
    print('''
========================================================================
[FCM_DEBUG] >>> FOREGROUND FCM RECEIVED! <<<
Message ID: ${message.messageId}
Type: $type
Data: $data
Notification: ${message.notification?.title} | ${message.notification?.body}
========================================================================
''');

    final isChatMessage = type == 'CHAT_MESSAGE' ||
        type == 'MESSAGE' ||
        type == 'NEW_MESSAGE';

    final isCall = !isChatMessage &&
        (type == 'INCOMING_CALL' ||
            type == 'CALL' ||
            type == 'CALL_REQUEST' ||
            type == 'RINGING' ||
            type == 'VOIP_CALL' ||
            data.containsKey('call_id') ||
            data.containsKey('callId'));

    if (isCall) {
      final call = IncomingCallData.fromJson(data);
      IncomingCallService.instance.handleIncomingPayload(data);
      // Avoid double incoming screen: if Circle Connect is already open and ringing
      // for this callId, do not post a duplicate heads-up notification.
      if (!IncomingCallService.instance.isCallRingingInWeb(call.callId)) {
        unawaited(showIncomingCallNotification(call));
      }
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
        type == 'CANCEL_CALL' ||
        type == 'REJECTED' ||
        type == 'HANGUP') {
      final callId = (data['call_id'] ?? data['callId'] ?? '').toString();
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(handleCallHandled(callId));
      return;
    }

    final convId = (data['conversation_id'] ??
            data['conversationId'] ??
            data['chat_id'] ??
            '')
        .toString()
        .trim();
    if (_activeConversationId != null &&
        convId.isNotEmpty &&
        _activeConversationId == convId) {
      debugPrint(
          '[PushBootstrap] Suppressing foreground notification banner for currently active conversation: $convId');
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

      if (actionId == 'stop_live_location') {
        await GridLiveLocationService.instance.stopAll(postStop: true);
        return;
      }
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

  /// Public API for chat message push notifications.
  Future<void> showMessageNotification(Map<String, dynamic> data) async {
    final convId = (data['conversation_id'] ??
            data['conversationId'] ??
            data['chat_id'] ??
            '')
        .toString()
        .trim();
    if (_activeConversationId != null &&
        convId.isNotEmpty &&
        _activeConversationId == convId) {
      debugPrint(
          '[PushBootstrap] Suppressing showMessageNotification for active conversation: $convId');
      return;
    }
    try {
      await showMessageNotificationOnPlugin(_local, data);
    } catch (e) {
      debugPrint('[PushBootstrap] showMessageNotification error: $e');
    }
  }

  Future<void> handleCallHandled(String callId) async {
    try {
      await _local.cancel(callId.hashCode.abs());
    } catch (_) {}
  }

  Future<void> cancelCallNotification(String callId) async {
    try {
      await _local.cancel(callId.hashCode.abs());
    } catch (_) {}
  }

  Future<void> clearChatNotifications(String conversationId) async {
    try {
      final notifId = (int.tryParse(conversationId) ?? conversationId.hashCode).abs();
      await _local.cancel(notifId);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
