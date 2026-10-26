import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../grid_sdui/grid_in_app_webview_page.dart';
import 'call_permission_helper.dart';
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
    this.actionToken = '',
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
  final String actionToken;

  bool get isVideo => callType.toLowerCase() == 'video';

  factory IncomingCallData.fromJson(Map<String, dynamic> json) {
    var rawUrl = (json['url'] ?? json['room_url'] ?? json['roomUrl'] ?? '')
        .toString()
        .trim();
    if (rawUrl.isNotEmpty &&
        !rawUrl.startsWith('http://') &&
        !rawUrl.startsWith('https://')) {
      final sanitized = rawUrl.replaceAll(RegExp(r'^/+'), '');
      rawUrl = 'https://efactor.tech/$sanitized';
    }
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

    final actionToken = (json['action_token'] ??
            json['actionToken'] ??
            json['call_token'] ??
            json['token'] ??
            '')
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
      actionToken: actionToken,
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
        'action_token': actionToken,
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
      'https://efactor.tech/index.php/api/register_device_token';

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

  /// The call ID currently ringing inside the open Circle Connect web page.
  String? activeWebCallId;

  /// Returns true if Circle Connect WebView is currently open in the foreground.
  bool get isCallPageOpen => GridInAppWebViewPage.isPageOpen;

  /// Returns true ONLY if the web page has explicitly called startRinging for this call_id.
  bool isCallRingingInWeb(String callId) {
    if (callId.isEmpty || activeWebCallId == null) return false;
    return activeWebCallId == callId;
  }

  /// Update or register the latest push token discovered from FCM or APNs.
  void setDeviceToken(String token) {
    _deviceToken = token.trim();
    unawaited(GridInAppWebViewPage.updatePushTokenInWeb(_deviceToken!));
  }

  Timer? _callTimeoutTimer;
  static final Set<String> _sentRingingTokens = <String>{};

  /// Dispatches call lifecycle actions (`ringing`, `decline`, etc.) to the
  /// Circle Connect native action API:
  /// POST https://<domain>/grid-chat/api/call/native_action
  /// Body: {"action": "<action>", "action_token": "<actionToken>"}
  /// No login / authentication required; valid for 2 minutes from call push.
  static Future<bool> postNativeAction({
    required String action,
    required String actionToken,
    String? roomUrl,
  }) async {
    final token = actionToken.trim();
    if (token.isEmpty) {
      debugPrint('[NativeCallAction] Skip POST native_action ($action): empty actionToken');
      return false;
    }

    final normalizedAction = action.toLowerCase().trim();
    if (normalizedAction == 'ringing') {
      if (_sentRingingTokens.contains(token)) {
        debugPrint('[NativeCallAction] Skipping duplicate ringing action for token: $token');
        return true;
      }
      _sentRingingTokens.add(token);
    }

    Uri? targetUri;
    if (roomUrl != null && roomUrl.isNotEmpty) {
      final parsed = Uri.tryParse(roomUrl);
      if (parsed != null && parsed.host.isNotEmpty) {
        targetUri = Uri.parse('${parsed.origin}/grid-chat/api/call/native_action');
      }
    }
    targetUri ??= Uri.parse('https://efactor.tech/grid-chat/api/call/native_action');

    final payload = <String, String>{
      'action': normalizedAction,
      'action_token': token,
    };

    final jsonBody = jsonEncode(payload);
    debugPrint('[NativeCallAction] >>> POST $targetUri | Body: $jsonBody');

    try {
      var response = await http
          .post(
            targetUri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonBody,
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
        '[NativeCallAction] <<< Response $targetUri -> Status: ${response.statusCode} | Body: ${response.body}',
      );

      // In WordPress environments without URL rewrite, retry with /index.php/ prefix if 404
      if (response.statusCode == 404 && !targetUri.path.contains('index.php')) {
        final fallbackUri = Uri.parse(
          '${targetUri.origin}/index.php/grid-chat/api/call/native_action',
        );
        debugPrint('[NativeCallAction] 404 received; retrying at fallback $fallbackUri');
        response = await http
            .post(
              fallbackUri,
              headers: const <String, String>{
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonBody,
            )
            .timeout(const Duration(seconds: 10));
        debugPrint(
          '[NativeCallAction] <<< Fallback Response $fallbackUri -> Status: ${response.statusCode} | Body: ${response.body}',
        );
      }

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[NativeCallAction] !!! Failed POST $targetUri ($action): $e');
      return false;
    }
  }

  /// Waits briefly on app cold start until [navigatorKey] is mounted.
  Future<BuildContext?> _waitForNavigatorContext() async {
    var ctx = navigatorKey.currentState?.context;
    if (ctx != null && ctx.mounted) return ctx;
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ctx = navigatorKey.currentState?.context;
      if (ctx != null && ctx.mounted) return ctx;
    }
    return null;
  }

  /// Read WebKit session cookies via native MethodChannel on Android and iOS.
  Future<String> getCookiesForUrl(String url) async {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
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

      // Spec rule: Automatically stop ringing after 60 seconds
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = Timer(const Duration(seconds: 60), () {
        if (currentCall.value?.callId == call.callId) {
          debugPrint(
            '[IncomingCallService] 60s timeout reached, auto-stopping ringing for callId=${call.callId}',
          );
          dismissCall();
          PushNotificationBootstrap.instance.cancelCallNotification(call.callId);
        }
      });

      // Spec rule: Notify server that ringing screen appears
      if (call.actionToken.isNotEmpty) {
        unawaited(postNativeAction(
          action: 'ringing',
          actionToken: call.actionToken,
          roomUrl: call.roomUrl,
        ));
      }

      unawaited(CallPermissionHelper.wakeAndUnlock());
      // Avoid double incoming screen: if Circle Connect is already open in the foreground
      // or already ringing for this callId, do not show a redundant native modal dialog.
      if (!isCallPageOpen && !isCallRingingInWeb(call.callId)) {
        unawaited(_displayIncomingCallModal(call));
      }
    } else if (type == 'MISSED_CALL' ||
        type == 'CALL_MISSED') {
      final call = IncomingCallData.fromJson(payload);
      dismissCall();
      PushNotificationBootstrap.instance.showMissedCallNotification(call);
    } else if (type == 'CALL_HANDLED' ||
        type == 'CALL_CANCELLED' ||
        type == 'CANCEL_CALL' ||
        type == 'REJECTED' ||
        type == 'HANGUP') {
      final callId = (payload['call_id'] ?? payload['callId'] ?? '').toString();
      if (activeWebCallId == callId) {
        activeWebCallId = null;
      }
      dismissCall();
      PushNotificationBootstrap.instance.handleCallHandled(callId);
    }
  }

  /// Dismiss the active incoming call banner/screen.
  void dismissCall() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
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
    activeWebCallId = callId;
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
    if (activeWebCallId == callId || (callId.isEmpty && activeWebCallId != null)) {
      activeWebCallId = null;
    }
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
  /// If closed: opens <url>?call_action=answer&call_id=<call_id>&grid_id=<caller_grid_id>
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
    qp['call_action'] = 'answer';
    qp['call_id'] = call.callId;
    if (call.callerGridId.isNotEmpty) qp['grid_id'] = call.callerGridId;
    if (call.callerName.isNotEmpty) qp['caller_name'] = call.callerName;
    if (call.callerUserId.isNotEmpty) qp['user_id'] = call.callerUserId;
    if (call.callType.isNotEmpty) qp['call_type'] = call.callType;
    final answerUri = uri.replace(queryParameters: qp);

    final targetContext = await _waitForNavigatorContext();
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

  /// User tapped notification body: opens full-screen ringing UI with call_action=show.
  /// If GRID Chat is open: calls window.gridChatCallAction({action: 'show', call_id})
  /// If closed: opens <url>?call_action=show&call_id=<call_id>&grid_id=<caller_grid_id>
  Future<void> showCallScreen(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    dismissCall();

    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.handleCallAction(
        action: 'show',
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
    qp['call_action'] = 'show';
    qp['call_id'] = call.callId;
    if (call.callerGridId.isNotEmpty) qp['grid_id'] = call.callerGridId;
    if (call.callerName.isNotEmpty) qp['caller_name'] = call.callerName;
    if (call.callerUserId.isNotEmpty) qp['user_id'] = call.callerUserId;
    if (call.callType.isNotEmpty) qp['call_type'] = call.callType;
    final showUri = uri.replace(queryParameters: qp);

    final targetContext = await _waitForNavigatorContext();
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: showUri,
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
  /// Handles both cases per Circle Connect specification:
  ///
  /// 1. Push with `action_token` (1:1 calls):
  ///    POSTs to `/grid-chat/api/call/native_action` with `{"action":"decline", "action_token":"<from push>"}`
  ///    requiring no login, preventing 401 Unauthorized errors when app is closed.
  ///
  /// 2. Push without `action_token` (group calls or legacy pushes):
  ///    - If GRID Chat WebView is open: calls `window.gridChatCallAction({action:"decline", call_id, grid_id})`.
  ///    - If closed: opens WebView at `https://<domain>/grid-chat?call_action=decline&call_id=<call_id>&grid_id=<caller_grid_id>`.
  ///    The page then declines through the logged-in session.
  ///    Never sends native_action without a token.
  Future<void> declineCall(
    IncomingCallData call, {
    String? rejectApiUrl,
    http.Client? client,
  }) async {
    debugPrint(
      '[IncomingCallService] >>> declineCall() CALLED for callId=${call.callId}, caller=${call.callerName}, hasToken=${call.actionToken.isNotEmpty} <<<',
    );
    dismissCall();
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    // Case A: If GRID Chat WebView is already open in foreground -> call window.gridChatCallAction
    if (GridInAppWebViewPage.isPageOpen) {
      await GridInAppWebViewPage.handleCallAction(
        action: 'decline',
        callId: call.callId,
        gridId: call.callerGridId,
        userId: call.callerUserId,
        callType: call.callType,
      );
      if (call.actionToken.isNotEmpty) {
        unawaited(postNativeAction(
          action: 'decline',
          actionToken: call.actionToken,
          roomUrl: call.roomUrl,
        ));
      }
      return;
    }

    // Case B: Push has action_token (1:1 calls) -> POST native_action without requiring login
    if (call.actionToken.isNotEmpty) {
      final success = await postNativeAction(
        action: 'decline',
        actionToken: call.actionToken,
        roomUrl: call.roomUrl,
      );
      if (success) {
        debugPrint('[IncomingCallService] declineCall completed via native_action endpoint.');
        return;
      }
    }

    // Case C: Push WITHOUT action_token (group calls or older push) and WebView closed ->
    // Spec rule: Open WebView with call_action=decline&call_id=<call_id>&grid_id=<caller_grid_id>.
    // Page declines through the logged-in session. Never send native_action without a token!
    debugPrint(
      '[IncomingCallService] No action_token; opening WebView with call_action=decline to decline via logged-in session',
    );
    final base = call.roomUrl.isNotEmpty
        ? call.roomUrl
        : IncomingCallData.defaultCallUrl;
    final uri = Uri.parse(base);
    final qp = Map<String, String>.from(uri.queryParameters);
    qp['call_action'] = 'decline';
    qp['call_id'] = call.callId;
    if (call.callerGridId.isNotEmpty) qp['grid_id'] = call.callerGridId;
    if (call.callerName.isNotEmpty) qp['caller_name'] = call.callerName;
    if (call.callerUserId.isNotEmpty) qp['user_id'] = call.callerUserId;
    if (call.callType.isNotEmpty) qp['call_type'] = call.callType;
    final declineUri = uri.replace(queryParameters: qp);

    final targetContext = await _waitForNavigatorContext();
    if (targetContext != null && targetContext.mounted) {
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: declineUri,
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
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

    final targetContext = await _waitForNavigatorContext();
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

    final targetContext = await _waitForNavigatorContext();
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

  /// Tap on banner / name: opens incoming call modal or brings call to focus.
  Future<void> openCallScreenWithoutAction(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    if (isCallRingingInWeb(call.callId)) return;
    if (GridInAppWebViewPage.isPageOpen) return;

    currentCall.value = call;
    await _displayIncomingCallModal(call);
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

    var effectiveUrl = url.trim();
    if (effectiveUrl.isNotEmpty &&
        !effectiveUrl.startsWith('http://') &&
        !effectiveUrl.startsWith('https://')) {
      final sanitized = effectiveUrl.replaceAll(RegExp(r'^/+'), '');
      effectiveUrl = 'https://efactor.tech/$sanitized';
    }
    if (effectiveUrl.isEmpty) {
      effectiveUrl =
          'https://efactor.tech/index.php/grid-chat?conversation_id=$conversationId';
    }
    final uri = Uri.parse(effectiveUrl);
    final targetContext = await _waitForNavigatorContext();
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
      // Backend explicitly requires token_type to be 'fcm' on all platforms (apns_voip is skipped).
      const resolvedTokenType = 'fcm';

      final httpClient = client ?? http.Client();
      final rawToken = (accessToken ?? activeAccessToken ?? '').trim();
      final cleanToken = rawToken.startsWith('Bearer ')
          ? rawToken.substring(7).trim()
          : rawToken;

      final cookies = await getCookiesForUrl('https://efactor.tech/index.php/grid-chat');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (cookies.isNotEmpty) 'Cookie': cookies,
        if (cleanToken.isNotEmpty) ...{
          'Authorization': 'Bearer $cleanToken',
          'access_token': cleanToken,
          'accesstoken': cleanToken,
          'token': cleanToken,
        },
      };

      final payloadMap = <String, dynamic>{
        'device_token': deviceToken,
        'platform': resolvedPlatform,
        'token_type': resolvedTokenType,
        'user_id': userId.toString(),
        if (cleanToken.isNotEmpty) ...{
          'access_token': cleanToken,
          'accesstoken': cleanToken,
          'token': cleanToken,
        },
      };
      final payload = jsonEncode(payloadMap);

      // ignore: avoid_print
      print('[IncomingCallService] Registering push token to backend for user $userId (endpoint: $uri)...');

      var registered = false;
      try {
        final response = await httpClient.post(
          uri,
          headers: headers,
          body: payload,
        );

        // ignore: avoid_print
        print(
          '[IncomingCallService] registerDeviceToken POST $uri -> status=${response.statusCode} body=${response.body}',
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final bodyLower = response.body.toLowerCase();
          if (!bodyLower.contains('"error"') &&
              !bodyLower.contains('"failure"') &&
              response.body.trim() != '[]') {
            registered = true;
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('[IncomingCallService] primary registerDeviceToken error: $e');
      }

      // Also register with Circle Connect / GRID Chat native push token endpoint
      // when using default production endpoints.
      if (backendUrl == null) {
        final gridChatUri = Uri.tryParse(
          'https://efactor.tech/index.php/grid-chat/api/push/native-token',
        );
        if (gridChatUri != null) {
          try {
            final gcResp = await httpClient.post(
              gridChatUri,
              headers: headers,
              body: payload,
            );
            // ignore: avoid_print
            print(
              '[IncomingCallService] registerDeviceToken grid-chat POST $gridChatUri -> status=${gcResp.statusCode} body=${gcResp.body}',
            );
            if (gcResp.statusCode >= 200 && gcResp.statusCode < 300) {
              registered = true;
            }
          } catch (e) {
            // ignore: avoid_print
            print('[IncomingCallService] grid-chat native-token register error: $e');
          }
        }
      }

      if (registered) {
        // ignore: avoid_print
        print('[IncomingCallService] Push token successfully registered on backend for user $userId');
        if (client == null) httpClient.close();
        return true;
      }

      // Try non-index primary URL if uri contains /index.php/api
      if (targetUrl.contains('/index.php/api/register_device_token')) {
        final directApiUri =
            Uri.tryParse('https://efactor.tech/api/register_device_token');
        if (directApiUri != null) {
          final directResp = await httpClient.post(
            directApiUri,
            headers: headers,
            body: payload,
          );
          debugPrint(
            '[IncomingCallService] registerDeviceToken directApi POST $directApiUri status=${directResp.statusCode} body=${directResp.body}',
          );
          if (directResp.statusCode >= 200 && directResp.statusCode < 300) {
            final directBodyLower = directResp.body.toLowerCase();
            if (!directBodyLower.contains('"error"') &&
                !directBodyLower.contains('"failure"') &&
                directResp.body.trim() != '[]') {
              if (client == null) httpClient.close();
              return true;
            }
          }
        }
      }

      // Fallback: Check if backend registered under /v8/api.php
      final fallbackUri = Uri.tryParse(
          'https://efactor.tech/v8/api.php?action=register_device_token');
      if (fallbackUri != null && fallbackUri != uri) {
        final fallbackResp = await httpClient.post(
          fallbackUri,
          headers: headers,
          body: payload,
        );
        debugPrint(
          '[IncomingCallService] registerDeviceToken fallback POST $fallbackUri status=${fallbackResp.statusCode} body=${fallbackResp.body}',
        );
        if (fallbackResp.statusCode >= 200 && fallbackResp.statusCode < 300) {
          final fbLower = fallbackResp.body.toLowerCase();
          // Note: v8/api.php returns [] for unhandled actions, which is NOT a valid registration.
          if (!fbLower.contains('"error"') &&
              !fbLower.contains('"failure"') &&
              fallbackResp.body.trim() != '[]') {
            if (client == null) httpClient.close();
            return true;
          }
        }
      }

      if (client == null) {
        httpClient.close();
      }
      return false;
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

    var token = (tokenOverride ?? _deviceToken ?? '').trim();
    if (token.isEmpty && !kIsWeb) {
      try {
        final fcm = await FirebaseMessaging.instance.getToken();
        if (fcm != null && fcm.isNotEmpty) {
          token = fcm.trim();
          _deviceToken = token;
        }
      } catch (e) {
        debugPrint('[IncomingCallService] FCM token fetch failed: $e');
      }
    }
    if (token.isEmpty) {
      // ignore: avoid_print
      print('[IncomingCallService] No FCM/APNs token available yet to register.');
      return false;
    }

    final success = await registerDeviceTokenWithBackend(
      backendUrl: backendUrl,
      userId: userId,
      deviceToken: token,
      accessToken: accessToken,
      client: client,
    );
    // ignore: avoid_print
    print('''
------------------------------------------------------------------------
[IncomingCallService] Device token registered for user $userId (success=$success)
Token snippet: ${token.length > 25 ? token.substring(0, 25) : token}...
------------------------------------------------------------------------
''');
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

  Future<void> _displayIncomingCallModal(IncomingCallData call) async {
    final ctx = await _waitForNavigatorContext();
    if (ctx == null || !ctx.mounted) return;

    showGeneralDialog<void>(
      context: ctx,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      pageBuilder: (dialogContext, anim1, anim2) {
        return IncomingCallScreen(
          call: call,
          onAccept: () {
            Navigator.of(dialogContext, rootNavigator: true).maybePop();
            acceptCall(ctx, call);
          },
          onDecline: () {
            declineCall(call);
            Navigator.of(dialogContext, rootNavigator: true).maybePop();
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
