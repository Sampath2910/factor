import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../grid_sdui/grid_in_app_webview_page.dart';
import 'call_lifecycle_tracker.dart';
import 'call_permission_helper.dart';
import 'grid_chat_message_notification.dart';
import 'ongoing_call_service.dart';
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

/// Answer captured from the Android notification before GRID Chat is open.
/// Kept until gridChatCallAction runs on a page that called callUiReady(),
/// or until the call expires, the caller cancels, or the user declines.
class PendingCallAnswer {
  const PendingCallAnswer({
    required this.callId,
    required this.gridId,
    required this.callType,
    required this.callerName,
    required this.callerUserId,
    required this.storedAtMs,
  });

  static const Duration ttl = Duration(seconds: 90);
  static const String prefsKey = 'efactor_pending_call_answer_v1';

  final String callId;
  final String gridId;
  final String callType;
  final String callerName;
  final String callerUserId;
  final int storedAtMs;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch - storedAtMs > ttl.inMilliseconds;

  String get normalizedCallType {
    if (callType.toLowerCase() == 'video') return 'video';
    return 'audio';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'call_id': callId,
        'grid_id': gridId,
        'call_type': normalizedCallType,
        'caller_name': callerName,
        'caller_user_id': callerUserId,
        'stored_at_ms': storedAtMs,
      };

  factory PendingCallAnswer.fromCall(IncomingCallData call) {
    return PendingCallAnswer(
      callId: call.callId.trim(),
      gridId: call.callerGridId.trim(),
      callType: call.callType,
      callerName: call.callerName,
      callerUserId: call.callerUserId,
      storedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static PendingCallAnswer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final callId = (raw['call_id'] ?? '').toString().trim();
    if (callId.isEmpty) return null;
    final stored = raw['stored_at_ms'];
    final storedAtMs = stored is int
        ? stored
        : int.tryParse(stored?.toString() ?? '') ?? 0;
    return PendingCallAnswer(
      callId: callId,
      gridId: (raw['grid_id'] ?? '').toString().trim(),
      callType: (raw['call_type'] ?? 'audio').toString(),
      callerName: (raw['caller_name'] ?? '').toString(),
      callerUserId: (raw['caller_user_id'] ?? '').toString(),
      storedAtMs: storedAtMs,
    );
  }
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

  /// Android heads-up / full-screen notification is for when GRID Chat cannot
  /// draw its own banner. One call_id, one visible incoming UI.
  static bool shouldPostNativeIncomingNotification({
    required bool circleConnectReady,
  }) {
    return !circleConnectReady;
  }

  int _presentationGeneration = 0;
  bool _nativeRingPlaying = false;
  final Set<String> _answeredCallIds = <String>{};
  final Set<String> _answerJsSentCallIds = <String>{};
  final Set<String> _clearedNotificationCallIds = <String>{};
  final Set<String> _loggedNavigationCallIds = <String>{};
  PendingCallAnswer? _pendingAnswer;
  final ValueNotifier<PendingCallAnswer?> pendingAnswerListenable =
      ValueNotifier<PendingCallAnswer?>(null);

  /// True while the authenticated shell is mounted and can show GRID Chat
  /// itself, without pushing a route on top of the home dashboard.
  bool answerHandoffOwnedByShell = false;

  PendingCallAnswer? get pendingAnswer {
    final pending = _pendingAnswer;
    if (pending != null && pending.isExpired) return null;
    return pending;
  }

  bool get navigatorCovered {
    final nav = navigatorKey.currentState;
    if (nav == null) return false;
    return nav.canPop();
  }

  static void callTrace(String event, String callId) {
    final id = callId.trim();
    final t = DateTime.now().millisecondsSinceEpoch;
    // ignore: avoid_print
    print('[CALL] $event call_id=$id t=$t');
  }

  /// Direct GRID Chat URL for a cold-start or background Answer.
  static Uri answerGridChatUri(PendingCallAnswer pending) {
    final params = <String, String>{
      'call_action': 'answer',
      'call_id': pending.callId,
      'call_type': pending.normalizedCallType,
    };
    if (pending.gridId.isNotEmpty) {
      params['grid_id'] = pending.gridId;
    }
    return Uri.parse(IncomingCallData.defaultCallUrl).replace(
      queryParameters: params,
    );
  }

  void logGridChatNavigation(String callId) {
    final id = callId.trim();
    if (id.isEmpty || !_loggedNavigationCallIds.add(id)) return;
    callTrace('GRID Chat navigation started', id);
  }

  /// First Android Answer wins. Later answer, show, or decline for this id are ignored.
  bool beginAnswer(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return true;
    if (!_answeredCallIds.add(id)) {
      // ignore: avoid_print
      print('[CALL] blocked duplicate answer call_id=$id');
      return false;
    }
    _clearedNotificationCallIds.add(id);
    return true;
  }

  /// Records the notification Answer and keeps it until GRID Chat can take it.
  Future<void> recordNotificationAnswer(IncomingCallData call) async {
    final id = call.callId.trim();
    if (id.isEmpty) return;
    if (!beginAnswer(id)) return;
    callTrace('notification Answer pressed', id);
    await storePendingAnswer(call);
  }

  Future<void> storePendingAnswer(IncomingCallData call) async {
    final pending = PendingCallAnswer.fromCall(call);
    if (pending.callId.isEmpty) return;
    final existing = _pendingAnswer;
    if (existing != null &&
        existing.callId == pending.callId &&
        !existing.isExpired) {
      return;
    }
    _pendingAnswer = pending;
    pendingAnswerListenable.value = pending;
    callTrace('pending Answer stored', pending.callId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PendingCallAnswer.prefsKey,
        jsonEncode(pending.toJson()),
      );
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CALL] pending Answer persist failed call_id=${pending.callId} error=$e',
      );
    }
  }

  Future<void> restorePendingAnswer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PendingCallAnswer.prefsKey);
      if (raw == null || raw.isEmpty) return;
      final pending = PendingCallAnswer.fromJson(jsonDecode(raw));
      if (pending == null || pending.isExpired) {
        await prefs.remove(PendingCallAnswer.prefsKey);
        return;
      }
      _pendingAnswer = pending;
      pendingAnswerListenable.value = pending;
      _answeredCallIds.add(pending.callId);
      _clearedNotificationCallIds.add(pending.callId);
      callTrace('pending Answer stored', pending.callId);
    } catch (e) {
      // ignore: avoid_print
      print('[CALL] pending Answer restore failed error=$e');
    }
  }

  /// Drops the queued Answer after it was injected, or the call is over.
  /// Opening the Activity or WebView must not call this.
  Future<void> clearPendingAnswer({
    required String reason,
    String? callId,
  }) async {
    final current = _pendingAnswer;
    if (current == null) return;
    final id = callId?.trim() ?? '';
    if (id.isNotEmpty && current.callId != id) return;
    _pendingAnswer = null;
    pendingAnswerListenable.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PendingCallAnswer.prefsKey);
    } catch (_) {}
    // ignore: avoid_print
    print(
      '[CALL] pending Answer cleared call_id=${current.callId} reason=$reason',
    );
  }

  Future<void> deliverPendingAnswer() async {
    final pending = pendingAnswer;
    if (pending == null) {
      final stale = _pendingAnswer;
      if (stale != null && stale.isExpired) {
        await clearPendingAnswer(reason: 'expired', callId: stale.callId);
      }
      return;
    }
    if (!GridInAppWebViewPage.isActiveCircleConnect) return;
    final delivered = await GridInAppWebViewPage.injectAnswerOnce(pending.callId);
    if (!delivered) return;
    await clearPendingAnswer(reason: 'delivered', callId: pending.callId);
  }

  Future<void> deliverPendingAnswerWithRetry() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final pending = pendingAnswer;
      if (pending == null) return;
      if (!GridInAppWebViewPage.isActiveCircleConnect) return;
      await deliverPendingAnswer();
      if (pendingAnswer == null || hasDeliveredAnswerJs(pending.callId)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  /// GRID Chat called callUiReady(). Inject the stored Answer once it can run.
  Future<void> onGridChatCallUiReady(String callId) async {
    callTrace('callUiReady() received', callId);
    await deliverPendingAnswerWithRetry();
  }

  bool hasDeliveredAnswerJs(String callId) {
    return _answerJsSentCallIds.contains(callId.trim());
  }

  /// True only the first time the answer script is sent into GRID Chat.
  bool claimAnswerJs(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return true;
    return _answerJsSentCallIds.add(id);
  }

  bool isAnswerInProgress(String callId) {
    final id = callId.trim();
    return id.isNotEmpty && _answeredCallIds.contains(id);
  }

  void markNotificationCleared(String callId) {
    final id = callId.trim();
    if (id.isNotEmpty) {
      _clearedNotificationCallIds.add(id);
    }
  }

  bool shouldIgnoreNotificationBodyTap(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return false;
    return _answeredCallIds.contains(id) ||
        _clearedNotificationCallIds.contains(id);
  }

  /// GRID Chat became ready, was covered, or the app moved between foreground and background.
  void onCircleConnectReadinessChanged() {
    if (GridInAppWebViewPage.isCircleConnectReady) {
      unawaited(
        PushNotificationBootstrap.instance.cancelVisibleIncomingCallNotifications(),
      );
    }
    unawaited(_syncIncomingCallPresentation());
  }

  /// Web confirmed its in-app banner is on screen for [callId].
  void incomingCallDisplayedFromWeb(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return;
    activeWebCallId = id;
    unawaited(_syncIncomingCallPresentation());
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
    http.Client? client,
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
      final postFn = client != null ? client.post : http.post;
      var response = await postFn(
        targetUri,
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonBody,
      ).timeout(const Duration(seconds: 10));

      debugPrint(
        '[NativeCallAction] <<< Response $targetUri -> Status: ${response.statusCode} | Body: ${response.body}',
      );

      // In WordPress environments without URL rewrite, retry with /index.php/ prefix if 404
      if (response.statusCode == 404 && !targetUri.path.contains('index.php')) {
        final fallbackUri = Uri.parse(
          '${targetUri.origin}/index.php/grid-chat/api/call/native_action',
        );
        debugPrint('[NativeCallAction] 404 received; retrying at fallback $fallbackUri');
        response = await postFn(
          fallbackUri,
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonBody,
        ).timeout(const Duration(seconds: 10));
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
    final callId =
        (payload['call_id'] ?? payload['callId'] ?? payload['id'] ?? '').toString().trim();

    if (CallLifecycleTracker.kEndCallTypes.contains(type)) {
      if (callId.isNotEmpty) {
        unawaited(CallLifecycleTracker.markCallFinished(callId));
      }
      unawaited(clearPendingAnswer(reason: type, callId: callId));
      if (activeWebCallId == callId) {
        activeWebCallId = null;
      }
      // When CALL_CANCELLED / CALL_ENDED arrives, call dismissCall() right away. Don't wait for 60-second timer.
      dismissCall();
      PushNotificationBootstrap.instance.handleCallHandled(callId);
      if (type == 'MISSED_CALL' || type == 'CALL_MISSED') {
        final call = IncomingCallData.fromJson(payload);
        PushNotificationBootstrap.instance.showMissedCallNotification(call);
      }
      return;
    }

    if (CallLifecycleTracker.kRingCallTypes.contains(type)) {
      if (callId.isNotEmpty && CallLifecycleTracker.isCallFinishedSync(callId)) {
        debugPrint(
          '[IncomingCallService] Ignoring INCOMING_CALL for already finished callId=$callId',
        );
        return;
      }
      if (OngoingCallService.instance.isCallActive) {
        debugPrint(
          '[IncomingCallService] Ignoring INCOMING_CALL because OngoingCallService is active',
        );
        return;
      }

      final call = IncomingCallData.fromJson(payload);
      currentCall.value = call;

      // Spec rule: Automatically stop ringing after 60 seconds
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = Timer(const Duration(seconds: 60), () {
        if (currentCall.value?.callId == call.callId) {
          debugPrint(
            '[IncomingCallService] 60s timeout reached, auto-stopping ringing for callId=${call.callId}',
          );
          if (call.callId.isNotEmpty) {
            unawaited(CallLifecycleTracker.markCallFinished(call.callId));
          }
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
      // The in-app banner owns the UI while GRID Chat is visible. The native
      // modal is only for when that page is not open.
      if (!isCallPageOpen && !isCallRingingInWeb(call.callId)) {
        unawaited(_displayIncomingCallModal(call));
      }
      unawaited(_syncIncomingCallPresentation());
    }
  }

  /// Dismiss the active incoming call banner/screen and stop native ringing.
  void dismissCall() {
    _presentationGeneration++;
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    currentCall.value = null;
    unawaited(_stopNativeRing());
  }

  /// Triggered by the web page via `CircleConnectPush.startRinging` when a call
  /// arrives over the in-page WebSocket connection while the page is already open.
  /// Keeps the FCM payload when it is the same call_id. Does not post a second UI.
  Future<void> startRingingFromWeb({
    required String callId,
    required String callerName,
    required String callType,
    required String url,
  }) async {
    final id = callId.trim();
    if (OngoingCallService.instance.isCallActive ||
        await CallLifecycleTracker.isOngoingCallActive() ||
        await CallLifecycleTracker.isCallFinished(id)) {
      debugPrint('[IncomingCallService] Ignoring startRingingFromWeb for finished or active call: $id');
      return;
    }
    activeWebCallId = id;
    final existing = currentCall.value;
    if (existing == null || existing.callId != id) {
      currentCall.value = IncomingCallData(
        callId: id,
        callerId: '',
        callerName: callerName,
        callType: callType,
        roomUrl: url,
      );
    }
    await _syncIncomingCallPresentation();
  }

  /// Triggered by the web page via `CircleConnectPush.stopRinging` when a call
  /// is answered, declined, or ended in the web UI.
  Future<void> stopRingingFromWeb(String callId) async {
    final id = callId.trim();
    if (id.isNotEmpty) {
      unawaited(CallLifecycleTracker.markCallFinished(id));
    }
    if (id.isEmpty || activeWebCallId == id) {
      activeWebCallId = null;
    }
    if (id.isEmpty || currentCall.value?.callId == id) {
      dismissCall();
    } else {
      await _stopNativeRing();
    }
    await PushNotificationBootstrap.instance.cancelCallNotification(id);
  }

  /// One incoming call_id shows either the GRID Chat banner or the Android
  /// notification, never both. Ringtone continues through the native ring
  /// while the banner owns the screen.
  Future<void> _syncIncomingCallPresentation() async {
    final generation = ++_presentationGeneration;
    final call = currentCall.value;
    if (call == null) {
      await _stopNativeRing();
      return;
    }

    // Suppress presentation if an active ongoing call exists or this call was already finished
    if (OngoingCallService.instance.isCallActive ||
        await CallLifecycleTracker.isOngoingCallActive() ||
        await CallLifecycleTracker.isCallFinished(call.callId)) {
      debugPrint('[IncomingCallService] Suppressing presentation: active ongoing call or call finished');
      dismissCall();
      await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);
      return;
    }

    final postNotification = shouldPostNativeIncomingNotification(
      circleConnectReady: GridInAppWebViewPage.isCircleConnectReady,
    );
    if (generation != _presentationGeneration) return;

    if (!postNotification) {
      await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);
      if (generation != _presentationGeneration) return;
      if (currentCall.value?.callId == call.callId) {
        await _startNativeRing();
      }
      return;
    }

    await _stopNativeRing();
    if (generation != _presentationGeneration) return;
    if (currentCall.value?.callId != call.callId) return;
    await PushNotificationBootstrap.instance.showIncomingCallNotification(call);
  }

  Future<void> _startNativeRing() async {
    if (_nativeRingPlaying) return;
    final generation = _presentationGeneration;
    _nativeRingPlaying = true;
    try {
      const channel = MethodChannel('tech.efactor/circle_connect');
      await channel.invokeMethod<void>('startIncomingRing');
      if (generation != _presentationGeneration || currentCall.value == null) {
        _nativeRingPlaying = false;
        await channel.invokeMethod<void>('stopIncomingRing');
      }
    } catch (e) {
      _nativeRingPlaying = false;
      debugPrint('[IncomingCallService] startIncomingRing failed: $e');
    }
  }

  Future<void> _stopNativeRing() async {
    if (!_nativeRingPlaying) return;
    _nativeRingPlaying = false;
    try {
      const channel = MethodChannel('tech.efactor/circle_connect');
      await channel.invokeMethod<void>('stopIncomingRing');
    } catch (e) {
      debugPrint('[IncomingCallService] stopIncomingRing failed: $e');
    }
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
  /// The pending Answer stays stored until callUiReady() and one
  /// gridChatCallAction, or until the call expires or is cancelled.
  /// GRID Chat is opened directly. The home dashboard is not pushed first.
  Future<void> answerCall(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    if (call.callId.isNotEmpty) {
      unawaited(CallLifecycleTracker.markCallFinished(call.callId));
    }
    await recordNotificationAnswer(call);
    dismissCall();
    await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);

    if (GridInAppWebViewPage.isActiveCircleConnect) {
      if (GridInAppWebViewPage.isCircleConnectReady) {
        await deliverPendingAnswerWithRetry();
      }
      return;
    }

    if (answerHandoffOwnedByShell && !navigatorCovered) {
      return;
    }

    final pending = pendingAnswer;
    final targetContext = navigatorKey.currentState?.context;
    if (pending == null || targetContext == null || !targetContext.mounted) {
      return;
    }
    logGridChatNavigation(pending.callId);
    await Navigator.of(targetContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GridInAppWebViewPage(
          uri: IncomingCallService.answerGridChatUri(pending),
          title: 'Circle Connect',
          showAppBar: false,
          accessToken: activeAccessToken,
          userId: activeUserId,
        ),
      ),
    );
  }

  /// User tapped notification body: opens full-screen ringing UI with call_action=show.
  /// If GRID Chat is open: calls window.gridChatCallAction({action: 'show', call_id})
  /// If closed: opens <url>?call_action=show&call_id=<call_id>&grid_id=<caller_grid_id>
  Future<void> showCallScreen(
    IncomingCallData call, {
    BuildContext? context,
  }) async {
    if (isAnswerInProgress(call.callId) ||
        shouldIgnoreNotificationBodyTap(call.callId)) {
      // ignore: avoid_print
      print(
        '[CALL] blocked show call_id=${call.callId} reason=answer_or_notification_clear',
      );
      return;
    }
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
    if (call.callId.isNotEmpty) {
      unawaited(CallLifecycleTracker.markCallFinished(call.callId));
    }
    if (isAnswerInProgress(call.callId)) {
      // ignore: avoid_print
      print(
        '[CALL] blocked decline call_id=${call.callId} reason=already_answered',
      );
      dismissCall();
      await PushNotificationBootstrap.instance.cancelCallNotification(call.callId);
      return;
    }
    await clearPendingAnswer(reason: 'decline', callId: call.callId);
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
        client: client,
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
  /// A loaded GRID Chat page gets one gridChatOpenChat call.
  /// A cold start opens the grid-chat URL and does not cover a pending Answer.
  Future<void> openChatFromNotification({
    required String conversationId,
    required String url,
    bool compose = false,
    BuildContext? context,
  }) async {
    final id = conversationId.trim();
    final messages = GridChatMessageNotifications.instance;
    if (id.isNotEmpty) {
      GridChatMessageNotifications.chatTrace(
        compose ? 'Reply pressed' : 'notification pressed',
        id,
        '',
      );
      if (GridInAppWebViewPage.isChatUiReady) {
        final delivered = await GridInAppWebViewPage.openChat(
          conversationId: id,
          compose: compose,
        );
        if (delivered) {
          await messages.clearPendingOpen(reason: 'delivered');
          return;
        }
      }
      final current = GridInAppWebViewPage.activeCircleConnectUri;
      if (current != null &&
          current.queryParameters['conversation_id'] == id &&
          (current.queryParameters['compose'] == '1') == compose) {
        return;
      }
      if (GridInAppWebViewPage.isActiveCircleConnect) {
        await messages.storePendingOpen(
          conversationId: id,
          compose: compose,
          needsJs: true,
        );
        return;
      }
      final existing = messages.pendingOpen;
      if (existing != null &&
          existing.conversationId == id &&
          existing.compose == compose &&
          !existing.needsJs) {
        return;
      }
      await messages.storePendingOpen(
        conversationId: id,
        compose: compose,
        needsJs: false,
      );
      if (pendingAnswer != null) return;
      if (answerHandoffOwnedByShell && !navigatorCovered) return;
      final targetContext = navigatorKey.currentState?.context;
      if (targetContext == null || !targetContext.mounted) return;
      GridChatMessageNotifications.chatTrace(
        'GRID Chat navigation started',
        id,
        '',
      );
      await Navigator.of(targetContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GridInAppWebViewPage(
            uri: GridChatMessageNotifications.conversationUri(
              id,
              compose: compose,
            ),
            title: 'Circle Connect',
            showAppBar: false,
            accessToken: activeAccessToken,
            userId: activeUserId,
          ),
        ),
      );
      return;
    }

    var effectiveUrl = url.trim();
    if (effectiveUrl.isNotEmpty &&
        !effectiveUrl.startsWith('http://') &&
        !effectiveUrl.startsWith('https://')) {
      final sanitized = effectiveUrl.replaceAll(RegExp(r'^/+'), '');
      effectiveUrl = 'https://efactor.tech/$sanitized';
    }
    if (effectiveUrl.isEmpty) return;
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
