import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../grid_sdui/grid_in_app_webview_page.dart';
import 'push_notification_bootstrap.dart';

/// Data structure representing an incoming call payload delivered via
/// WebSocket signaling, FCM high-priority push, or APNs VoIP push.
class IncomingCallData {
  const IncomingCallData({
    required this.callId,
    required this.callerId,
    required this.callerName,
    this.callerAvatar,
    this.callType = 'audio',
    required this.roomUrl,
    this.timestamp,
    this.callerGridId = '',
    this.callerUserId = '',
    this.conversationId = '',
    this.tag = '',
    this.body = '',
  });

  static const String defaultCallUrl = 'https://efactor.tech/index.php/grid-chat';

  final String callId;
  final String callerId;
  final String callerName;
  final String? callerAvatar;
  final String callType; // 'audio' or 'video'
  final String roomUrl;
  final int? timestamp;
  final String callerGridId;
  final String callerUserId;
  final String conversationId;
  final String tag;
  final String body;

  bool get isVideo => callType.toLowerCase() == 'video';

  factory IncomingCallData.fromJson(Map<String, dynamic> json) {
    final rawUrl = (json['url'] ?? json['room_url'] ?? json['roomUrl'] ?? '')
        .toString()
        .trim();
    final callerName = (json['title'] ??
            json['caller_name'] ??
            json['callerName'] ??
            json['name'] ??
            'Efactor Member')
        .toString()
        .trim();
    final callerAvatar = (json['icon'] ??
            json['caller_avatar'] ??
            json['callerAvatar'] ??
            json['avatar'])
        ?.toString()
        .trim();
    final callId = (json['call_id'] ?? json['callId'] ?? json['id'] ?? '')
        .toString()
        .trim();
    final callerGridId =
        (json['caller_grid_id'] ?? json['callerGridId'] ?? '').toString().trim();
    final callerUserId = (json['caller_user_id'] ??
            json['callerUserId'] ??
            json['userId'] ??
            '')
        .toString()
        .trim();
    final conversationId = (json['conversation_id'] ??
            json['conversationId'] ??
            '')
        .toString()
        .trim();
    final tag = (json['tag'] ?? '').toString().trim();
    final body = (json['body'] ?? '').toString().trim();
    final callType =
        (json['call_type'] ?? json['callType'] ?? json['type'] ?? 'audio')
            .toString()
            .trim();

    return IncomingCallData(
      callId: callId,
      callerId: callerUserId.isNotEmpty
          ? callerUserId
          : (callerGridId.isNotEmpty
              ? callerGridId
              : (json['caller_id'] ?? '').toString()),
      callerName: callerName.isNotEmpty ? callerName : 'Efactor Member',
      callerAvatar: (callerAvatar != null && callerAvatar.isNotEmpty)
          ? callerAvatar
          : null,
      callType: callType.isNotEmpty ? callType : 'audio',
      roomUrl: rawUrl.isNotEmpty ? rawUrl : defaultCallUrl,
      callerGridId: callerGridId,
      callerUserId: callerUserId,
      conversationId: conversationId,
      tag: tag,
      body: body,
      timestamp: json['timestamp'] is int
          ? json['timestamp'] as int
          : int.tryParse(json['timestamp']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'call_id': callId,
        'caller_id': callerId,
        'caller_name': callerName,
        'caller_avatar': callerAvatar,
        'call_type': callType,
        'room_url': roomUrl,
        'caller_grid_id': callerGridId,
        'caller_user_id': callerUserId,
        'conversation_id': conversationId,
        'tag': tag,
        'body': body,
        'timestamp': timestamp,
      };
}

/// Singleton manager for incoming calls across Circle Connect and WebRTC.
///
/// Handles:
/// 1. Parsing incoming push / signaling payloads (`INCOMING_CALL`, `MISSED_CALL`, `CALL_HANDLED`).
/// 2. Displaying native-grade, full-screen incoming call UI.
/// 3. Seamless handover to [GridInAppWebViewPage] upon Call Accept.
/// 4. Synchronizing the device push token to `/api/register_device_token`.
class IncomingCallService {
  IncomingCallService._();
  static final IncomingCallService instance = IncomingCallService._();

  static const String defaultRegisterTokenUrl =
      'https://efactor.tech/api/register_device_token';

  final ValueNotifier<IncomingCallData?> currentCall =
      ValueNotifier<IncomingCallData?>(null);

  /// Global navigator key reference to allow displaying incoming call UI
  /// or pushing the call WebView even from background notification handlers.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Stored active session credentials for seamless WebView handover.
  String? activeAccessToken;
  int? activeUserId;
  String? _deviceToken;

  /// The cached FCM or APNs device token.
  String? get deviceToken => _deviceToken;

  /// Update or register the latest push token discovered from FCM or APNs.
  void setDeviceToken(String token) {
    _deviceToken = token.trim();
    unawaited(GridInAppWebViewPage.updatePushTokenInWeb(_deviceToken!));
  }

  /// Read Android WebKit session cookies via native MethodChannel.
  Future<String> getCookiesForUrl(String url) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('tech.efactor/circle_connect');
        final cookies =
            await channel.invokeMethod<String>('getCookies', {'url': url});
        if (cookies != null && cookies.isNotEmpty) return cookies;
      } catch (e) {
        debugPrint('[IncomingCallService] getCookies error: $e');
      }
    }
    return '';
  }

  /// Parse and handle an incoming push payload delivered from FCM, APNs, or WebSocket.
  void handleIncomingPayload(Map<String, dynamic> payload) {
    final type =
        (payload['type'] ?? payload['event'] ?? '').toString().toUpperCase();

    if (type == 'INCOMING_CALL' || type == 'CALL') {
      final call = IncomingCallData.fromJson(payload);
      currentCall.value = call;
      _displayIncomingCallModal(call);
    } else if (type == 'MISSED_CALL' ||
        type == 'CALL_MISSED') {
      final call = IncomingCallData.fromJson(payload);
      dismissCall();
      PushNotificationBootstrap.instance.showMissedCallNotification(call);
    } else if (type == 'CALL_HANDLED' ||
        type == 'CALL_CANCELLED' ||
        type == 'HANGUP') {
      final callId = (payload['call_id'] ?? payload['callId'] ?? '').toString();
      dismissCall();
      PushNotificationBootstrap.instance.handleCallHandled(callId);
    }
  }

  /// Dismiss the active incoming call banner/screen.
  void dismissCall() {
    currentCall.value = null;
  }

  /// Triggered by the web page via `CircleConnectPush.startRinging` when a call
  /// arrives over the in-page WebSocket connection while the page is already open.
  Future<void> startRingingFromWeb({
    required String callId,
    required String callerName,
    required String callType,
    required String url,
  }) async {
    final call = IncomingCallData(
      callId: callId,
      callerId: '',
      callerName: callerName,
      callType: callType,
      roomUrl: url,
    );
    currentCall.value = call;
    await PushNotificationBootstrap.instance.showIncomingCallNotification(call);
  }

  /// Triggered by the web page via `CircleConnectPush.stopRinging` when a call
  /// is answered, declined, or ended in the web UI.
  Future<void> stopRingingFromWeb(String callId) async {
    dismissCall();
    await PushNotificationBootstrap.instance.cancelCallNotification(callId);
  }

  /// User accepted the call. Dismiss UI and navigate immediately into Circle Connect WebView.
  /// No custom room URL is needed; loads `https://efactor.tech/index.php/grid-chat`
  /// where the in-page WebSocket + CallOverlay takes over media.
  Future<void> acceptCall(
    BuildContext context,
    IncomingCallData call, {
    String? accessToken,
    int? userId,
  }) async {
    await answerCall(call, context: context);
  }

  /// Trigger call acceptance when opened from a native background notification
  /// or CallKit action without direct BuildContext access.
  Future<void> acceptCallFromNotification(IncomingCallData call) async {
    await answerCall(call);
  }

  /// Answer the call.
  /// If GRID Chat is open: calls window.gridChatCallAction({action: 'answer', call_id})
  /// If closed: opens <url>?call_action=answer&call_id=<call_id>
  Future<void> answerCall(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    dismissCall();
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.handleCallAction(
        action: 'answer',
        callId: call.callId,
      );
      return;
    }

    final base = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final uri = Uri.parse(base);
    final qp = Map<String, String>.from(uri.queryParameters);
    qp['call_action'] = 'answer';
    qp['call_id'] = call.callId;
    final answerUri = uri.replace(queryParameters: qp);

    final targetContext = context ?? navigatorKey.currentState?.context;
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: answerUri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
    }
  }

  /// User declined the call.
  /// Cancels notification, POSTs <url>/api/call/decline with form fields
  /// `call_id` and `caller_grid_id`, and sends the WebView cookies.
  Future<void> declineCall(
    IncomingCallData call, {
    String? rejectApiUrl,
    http.Client? client,
  }) async {
    dismissCall();
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    final targetUrl = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final cookies = await getCookiesForUrl(targetUrl);

    final cleanUrl =
        targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
    final primaryUri = Uri.tryParse('$cleanUrl/api/call/decline');
    final originUri = Uri.tryParse(targetUrl);
    final fallbackUri = originUri != null
        ? Uri.tryParse('${originUri.origin}/api/call/decline')
        : null;

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      if (cookies.isNotEmpty) 'Cookie': cookies,
      if (activeAccessToken != null && activeAccessToken!.isNotEmpty)
        'Authorization': 'Bearer $activeAccessToken',
    };

    final bodyFields = <String, String>{
      'call_id': call.callId,
      'caller_grid_id': call.callerGridId,
    };

    final httpClient = client ?? http.Client();
    try {
      if (primaryUri != null) {
        final resp = await httpClient
            .post(primaryUri, headers: headers, body: bodyFields)
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          if (client == null) httpClient.close();
          return;
        }
      }
      if (fallbackUri != null && fallbackUri != primaryUri) {
        await httpClient
            .post(fallbackUri, headers: headers, body: bodyFields)
            .timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('[IncomingCallService] declineCall error: $e');
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Call back action from missed call notification.
  /// If open: window.gridChatCallAction({action: 'callback', grid_id, user_id, call_type})
  /// If closed: <url>?call_action=callback&grid_id=<grid>&user_id=<uid>&call_type=<type>
  Future<void> callbackCall(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.handleCallAction(
        action: 'callback',
        callId: call.callId,
        gridId: call.callerGridId,
        userId: call.callerUserId,
        callType: call.callType,
      );
      return;
    }

    final base = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final uri = Uri.parse(base);
    final qp = Map<String, String>.from(uri.queryParameters);
    qp['call_action'] = 'callback';
    if (call.callerGridId.isNotEmpty) qp['grid_id'] = call.callerGridId;
    if (call.callerUserId.isNotEmpty) qp['user_id'] = call.callerUserId;
    if (call.callType.isNotEmpty) qp['call_type'] = call.callType;
    final callbackUri = uri.replace(queryParameters: qp);

    final targetContext = context ?? navigatorKey.currentState?.context;
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: callbackUri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
    }
  }

  /// Message action from missed call notification.
  /// If open: window.gridChatCallAction({action: 'message', grid_id, user_id})
  /// If closed: <url>?call_action=message&grid_id=<grid>&user_id=<uid>
  Future<void> messageCall(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.handleCallAction(
        action: 'message',
        callId: call.callId,
        gridId: call.callerGridId,
        userId: call.callerUserId,
      );
      return;
    }

    final base = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final uri = Uri.parse(base);
    final qp = Map<String, String>.from(uri.queryParameters);
    qp['call_action'] = 'message';
    if (call.callerGridId.isNotEmpty) qp['grid_id'] = call.callerGridId;
    if (call.callerUserId.isNotEmpty) qp['user_id'] = call.callerUserId;
    final messageUri = uri.replace(queryParameters: qp);

    final targetContext = context ?? navigatorKey.currentState?.context;
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: messageUri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
    }
  }

  /// Tap on banner / name: opens GRID Chat incoming-call screen without action.
  Future<void> openCallScreenWithoutAction(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    if (GridInAppWebViewPage.isPageOpen) return;

    final uri = Uri.parse(
      call.roomUrl.isNotEmpty ? call.roomUrl : IncomingCallData.defaultCallUrl,
    );
    final targetContext = context ?? navigatorKey.currentState?.context;
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: uri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
    }
  }

  /// Opens or focuses chat by conversationId.
  Future<void> openChatFromNotification({
    required String conversationId,
    required String url,
    BuildContext? context,
  }) async {
    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.openChat(conversationId: conversationId);
      return;
    }

    final uri = Uri.parse(
      url.isNotEmpty
          ? url
          : 'https://efactor.tech/index.php/grid-chat?conversation_id=$conversationId',
    );
    final targetContext = context ?? navigatorKey.currentState?.context;
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: uri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
    }
  }

  /// Sync device FCM / APNs VoIP token to the backend so the server knows
  /// where to send high-priority push notifications when this user is called.
  Future<bool> registerDeviceTokenWithBackend({
    String? backendUrl,
    required String userId,
    required String deviceToken,
    String? platform, // 'android' or 'ios'
    String tokenType = 'fcm', // 'fcm' or 'apns_voip'
    String? accessToken,
    http.Client? client,
  }) async {
    try {
      final targetUrl = backendUrl ?? defaultRegisterTokenUrl;
      final uri = Uri.tryParse(targetUrl);
      if (uri == null) return false;

      final resolvedPlatform = platform ??
          (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

      final httpClient = client ?? http.Client();
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (accessToken != null && accessToken.isNotEmpty)
          'Authorization': 'Bearer $accessToken'
        else if (activeAccessToken != null && activeAccessToken!.isNotEmpty)
          'Authorization': 'Bearer $activeAccessToken',
      };

      final response = await httpClient.post(
        uri,
        headers: headers,
        body: jsonEncode(<String, dynamic>{
          'action': 'register_device_token',
          'user_id': userId,
          'device_token': deviceToken,
          'platform': resolvedPlatform,
          'token_type': tokenType,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
      if (client == null) {
        httpClient.close();
      }
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Automatically called on successful user login or session restore.
  /// Caches the active credentials and synchronizes the push token with the backend.
  Future<bool> syncDeviceTokenOnLogin({
    required String userId,
    String? accessToken,
    String? tokenOverride,
    String? backendUrl,
    http.Client? client,
  }) async {
    activeUserId = int.tryParse(userId);
    activeAccessToken = accessToken;

    final token = (tokenOverride ?? _deviceToken ?? '').trim();
    if (token.isEmpty) {
      debugPrint('[IncomingCallService] No FCM/APNs token available yet to register.');
      return false;
    }

    final success = await registerDeviceTokenWithBackend(
      backendUrl: backendUrl,
      userId: userId,
      deviceToken: token,
      accessToken: accessToken,
      client: client,
    );
    debugPrint(
      '[IncomingCallService] Device token registered for user $userId (success=$success)',
    );
    return success;
  }

  /// Unregister device token upon user logout so the device stops receiving
  /// calls meant for that account.
  Future<bool> unregisterDeviceTokenOnLogout({
    String? userId,
    String? accessToken,
    String? backendUrl,
    http.Client? client,
  }) async {
    final uid = userId ?? activeUserId?.toString();
    if (uid == null || uid.isEmpty) return false;

    final targetUrl = backendUrl ?? defaultRegisterTokenUrl;
    try {
      final uri = Uri.tryParse(targetUrl);
      if (uri == null) return false;

      final httpClient = client ?? http.Client();
      final token = accessToken ?? activeAccessToken;
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty)
          'Authorization': 'Bearer $token',
      };

      final response = await httpClient.post(
        uri,
        headers: headers,
        body: jsonEncode(<String, dynamic>{
          'action': 'unregister_device_token',
          'user_id': uid,
          'device_token': _deviceToken ?? '',
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
      if (client == null) {
        httpClient.close();
      }
      activeAccessToken = null;
      activeUserId = null;
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  void _displayIncomingCallModal(IncomingCallData call) {
    final nav = navigatorKey.currentState;
    if (nav == null || nav.context.mounted == false) return;

    showGeneralDialog<void>(
      context: nav.context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      pageBuilder: (context, anim1, anim2) {
        return IncomingCallScreen(
          call: call,
          onAccept: () => acceptCall(context, call),
          onDecline: () {
            declineCall(call);
            Navigator.of(context, rootNavigator: true).maybePop();
          },
        );
      },
    );
  }
}

/// Full-screen incoming call UI matching WhatsApp and iOS CallKit styling.
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({
    super.key,
    required this.call,
    required this.onAccept,
    required this.onDecline,
  });

  final IncomingCallData call;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              const SizedBox(height: 48),
              // Subtitle badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      call.isVideo ? Icons.videocam : Icons.call,
                      color: const Color(0xFF60A5FA),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      call.isVideo
                          ? 'Circle Connect Video Call'
                          : 'Circle Connect Voice Call',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Caller Name
              Text(
                call.callerName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Incoming call...',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              // Caller Avatar
              Center(
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
                        blurRadius: 40,
                        spreadRadius: 10,
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    backgroundColor: const Color(0xFF1E293B),
                    backgroundImage: (call.callerAvatar != null && call.callerAvatar!.isNotEmpty)
                        ? NetworkImage(call.callerAvatar!)
                        : null,
                    child: (call.callerAvatar == null || call.callerAvatar!.isEmpty)
                        ? Text(
                            call.callerName.isNotEmpty
                                ? call.callerName.substring(0, 1).toUpperCase()
                                : 'C',
                            style: const TextStyle(
                              fontSize: 54,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              const Spacer(),
              // Bottom Action Buttons (Decline / Accept)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    // Decline Button
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        GestureDetector(
                          onTap: onDecline,
                          child: Container(
                            width: 68,
                            height: 68,
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.call_end,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Decline',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    // Accept Button
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        GestureDetector(
                          onTap: onAccept,
                          child: Container(
                            width: 68,
                            height: 68,
                            decoration: const BoxDecoration(
                              color: Color(0xFF22C55E),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              call.isVideo ? Icons.videocam : Icons.call,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Accept',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
