import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../grid_sdui/grid_in_app_webview_page.dart';

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
  });

  static const String defaultCallUrl = 'https://efactor.tech/index.php/grid-chat';

  final String callId;
  final String callerId;
  final String callerName;
  final String? callerAvatar;
  final String callType; // 'audio' or 'video'
  final String roomUrl;
  final int? timestamp;

  bool get isVideo => callType.toLowerCase() == 'video';

  factory IncomingCallData.fromJson(Map<String, dynamic> json) {
    final rawUrl = (json['room_url'] ?? json['roomUrl'] ?? json['url'] ?? '')
        .toString()
        .trim();

    return IncomingCallData(
      callId: (json['call_id'] ?? json['callId'] ?? json['id'] ?? '').toString(),
      callerId: (json['caller_id'] ?? json['callerId'] ?? json['userId'] ?? '').toString(),
      callerName: (json['caller_name'] ?? json['callerName'] ?? json['name'] ?? 'Efactor Member').toString(),
      callerAvatar: json['caller_avatar']?.toString() ?? json['callerAvatar']?.toString() ?? json['avatar']?.toString(),
      callType: (json['call_type'] ?? json['callType'] ?? json['type'] ?? 'audio').toString(),
      roomUrl: rawUrl.isNotEmpty ? rawUrl : defaultCallUrl,
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
        'timestamp': timestamp,
      };
}

/// Singleton manager for incoming calls across Circle Connect and WebRTC.
///
/// Handles:
/// 1. Parsing incoming push / signaling payloads (`INCOMING_CALL`, `CALL_CANCELLED`).
/// 2. Displaying a native-grade, full-screen incoming call UI.
/// 3. Direct transition into [GridInAppWebViewPage] upon Call Accept.
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
  }

  /// Parse and handle an incoming push payload delivered from FCM, APNs, or WebSocket.
  void handleIncomingPayload(Map<String, dynamic> payload) {
    final type =
        (payload['type'] ?? payload['event'] ?? '').toString().toUpperCase();

    if (type == 'INCOMING_CALL' || type == 'CALL') {
      final call = IncomingCallData.fromJson(payload);
      currentCall.value = call;
      _displayIncomingCallModal(call);
    } else if (type == 'CALL_CANCELLED' ||
        type == 'CALL_MISSED' ||
        type == 'HANGUP') {
      dismissCall();
    }
  }

  /// Dismiss the active incoming call banner/screen.
  void dismissCall() {
    currentCall.value = null;
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
    dismissCall();
    final effectiveUrl = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final uri = Uri.tryParse(effectiveUrl);
    if (uri == null) return;

    final token = accessToken ?? activeAccessToken;
    final uid = userId ?? activeUserId;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GridInAppWebViewPage(
          uri: uri,
          title: 'Circle Connect',
          showAppBar: false,
          accessToken: token,
          userId: uid,
        ),
      ),
    );
  }

  /// Trigger call acceptance when opened from a native background notification
  /// or CallKit action without direct BuildContext access.
  Future<void> acceptCallFromNotification(IncomingCallData call) async {
    final navContext = navigatorKey.currentState?.context;
    if (navContext != null && navContext.mounted) {
      await acceptCall(navContext, call);
    }
  }

  /// User declined the call. Send rejection to backend and dismiss UI.
  Future<void> declineCall(
    IncomingCallData call, {
    String? rejectApiUrl,
    http.Client? client,
  }) async {
    dismissCall();
    final url = rejectApiUrl ?? 'https://efactor.tech/api/call_action';
    try {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final httpClient = client ?? http.Client();
        final headers = <String, String>{
          'Content-Type': 'application/json',
          if (activeAccessToken != null && activeAccessToken!.isNotEmpty)
            'Authorization': 'Bearer $activeAccessToken',
        };
        final body = jsonEncode(<String, dynamic>{
          'action': 'call_rejected',
          'call_id': call.callId,
          'caller_id': call.callerId,
          'user_id': activeUserId?.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        });

        await httpClient.post(uri, headers: headers, body: body);
        if (client == null) {
          httpClient.close();
        }
      }
    } catch (_) {}
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
