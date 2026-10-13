import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'incoming_call_service.dart';
import 'json_http.dart';

const AndroidNotificationChannel _kMessagesChannel = AndroidNotificationChannel(
  'efactor_messages',
  'Messages',
  description: 'Circle Connect and chat message notifications',
  importance: Importance.high,
);

const AndroidNotificationChannel _kCallsChannel = AndroidNotificationChannel(
  'efactor_incoming_calls',
  'Incoming calls',
  description: 'Alerts for incoming Circle Connect calls',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

/// Top-level FCM background handler (must stay top-level for the isolate).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    return;
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
  );
  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_kMessagesChannel);
  await android?.createNotificationChannel(_kCallsChannel);

  if (type == 'INCOMING_CALL' || type == 'CALL') {
    final call = IncomingCallData.fromJson(data);
    await plugin.show(
      call.callId.hashCode,
      call.callerName,
      call.isVideo ? 'Incoming video call' : 'Incoming voice call',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _kCallsChannel.id,
          _kCallsChannel.name,
          channelDescription: _kCallsChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: jsonEncode(data),
    );
    return;
  }

  if (type == 'CALL_CANCELLED' ||
      type == 'CALL_MISSED' ||
      type == 'HANGUP') {
    await plugin.cancel((data['call_id'] ?? data['callId'] ?? '').hashCode);
    return;
  }

  // Data-only message (or notification+data): ensure a tray entry when killed.
  final title = message.notification?.title ??
      data['title']?.toString() ??
      'Efactor';
  final body = message.notification?.body ??
      data['body']?.toString() ??
      data['message']?.toString() ??
      '';
  if (body.isEmpty && message.notification == null && type.isEmpty) {
    return;
  }
  await plugin.show(
    message.messageId?.hashCode ?? message.hashCode,
    title,
    body.isEmpty ? 'New notification' : body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _kMessagesChannel.id,
        _kMessagesChannel.name,
        channelDescription: _kMessagesChannel.description,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(),
    ),
    payload: jsonEncode(data),
  );
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
  StreamSubscription<String>? _tokenSub;

  bool get isReady => _ready;

  Future<void> initialize() async {
    if (_ready || kIsWeb) return;

    try {
      await Firebase.initializeApp();
    } catch (e) {
      logDebug(
        '[PushBootstrap] Firebase not configured ($e). '
        'Copy google-services.json and GoogleService-Info.plist then rebuild.',
      );
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
    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _onMessageOpened(initial);
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
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final map = jsonDecode(payload) as Map<String, dynamic>;
          _routeFromPayload(map);
        } catch (_) {}
      },
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_kMessagesChannel);
    await androidPlugin?.createNotificationChannel(_kCallsChannel);
  }

  void _onForegroundMessage(RemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
    if (type == 'INCOMING_CALL' || type == 'CALL') {
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(_showCallNotification(data));
      return;
    }
    if (type == 'CALL_CANCELLED' ||
        type == 'CALL_MISSED' ||
        type == 'HANGUP') {
      IncomingCallService.instance.handleIncomingPayload(data);
      unawaited(
        _local.cancel((data['call_id'] ?? data['callId'] ?? '').hashCode),
      );
      return;
    }
    unawaited(_showMessageNotification(message));
  }

  void _onMessageOpened(RemoteMessage message) {
    _routeFromPayload(Map<String, dynamic>.from(message.data));
  }

  void _routeFromPayload(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
    if (type == 'INCOMING_CALL' || type == 'CALL') {
      final call = IncomingCallData.fromJson(data);
      unawaited(
        IncomingCallService.instance.acceptCallFromNotification(call),
      );
      return;
    }
    final url = (data['room_url'] ??
            data['url'] ??
            data['deep_link'] ??
            IncomingCallData.defaultCallUrl)
        .toString();
    final call = IncomingCallData(
      callId: 'message_${DateTime.now().millisecondsSinceEpoch}',
      callerId: (data['sender_id'] ?? '').toString(),
      callerName:
          (data['title'] ?? data['sender_name'] ?? 'Message').toString(),
      roomUrl: url,
    );
    unawaited(IncomingCallService.instance.acceptCallFromNotification(call));
  }

  Future<void> _showCallNotification(Map<String, dynamic> data) async {
    final call = IncomingCallData.fromJson(data);
    await _local.show(
      call.callId.hashCode,
      call.callerName,
      call.isVideo ? 'Incoming video call' : 'Incoming voice call',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _kCallsChannel.id,
          _kCallsChannel.name,
          channelDescription: _kCallsChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  Future<void> _showMessageNotification(RemoteMessage message) async {
    final title = message.notification?.title ??
        message.data['title']?.toString() ??
        'Efactor';
    final body = message.notification?.body ??
        message.data['body']?.toString() ??
        message.data['message']?.toString() ??
        '';
    await _local.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _kMessagesChannel.id,
          _kMessagesChannel.name,
          channelDescription: _kMessagesChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: jsonEncode(message.data),
    );
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
