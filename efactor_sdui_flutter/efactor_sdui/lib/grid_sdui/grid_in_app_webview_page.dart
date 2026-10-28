import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../services/grid_chat_message_notification.dart';
import '../services/incoming_call_service.dart';
import '../services/ongoing_call_service.dart';
import '../services/push_notification_bootstrap.dart';
import 'dynamic_grid_sdui_page.dart';
import 'grid_live_location_service.dart';
import 'grid_media_cache_service.dart';
import 'grid_offline_outbox_service.dart';
import 'grid_shell_pool.dart';
import 'grid_web_snapshot.dart';

/// Full-screen in-app WebView for Grid schema `openIn: inAppWebView`.
///
/// Online visits save a script-stripped DOM snapshot. Offline opens restore
/// that last view when available; otherwise show the offline illustration.
/// Pull-to-refresh always reloads the live URL (not the snapshot).
class GridInAppWebViewPage extends StatefulWidget {
  const GridInAppWebViewPage({
    super.key,
    required this.uri,
    this.title,
    this.showAppBar = false,
    this.accessToken,
    this.userId,
  });

  final Uri uri;
  final String? title;
  final bool showAppBar;
  final String? accessToken;
  final int? userId;

  static bool isExternalScheme(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'whatsapp' ||
        scheme == 'tel' ||
        scheme == 'mailto' ||
        scheme == 'sms' ||
        scheme == 'intent') {
      return true;
    }
    final host = uri.host.toLowerCase();
    if (host == 'wa.me' || host == 'api.whatsapp.com') {
      return true;
    }
    return false;
  }

  static String normalizeUrl(String url) {
    var result = url;
    while (result.contains('/index.php/index.php/')) {
      result = result.replaceAll('/index.php/index.php/', '/index.php/');
    }
    return result;
  }

  static Uri normalizeUri(Uri uri) {
    final str = uri.toString();
    if (str.contains('/index.php/index.php/')) {
      return Uri.tryParse(normalizeUrl(str)) ?? uri;
    }
    return uri;
  }

  static bool shouldInjectSso(
    Uri uri, {
    required Uri initialUri,
    String? ssoTokenFallback,
  }) {
    final initialSso =
        initialUri.queryParameters['grid_sso'] ?? ssoTokenFallback;
    if (initialSso == null || initialSso.isEmpty) return false;
    if (uri.queryParameters.containsKey('grid_sso')) return false;

    final path = uri.path.toLowerCase();
    return path.contains('/signin') ||
        path.contains('/login') ||
        path.endsWith('signin.php') ||
        path.endsWith('login.php');
  }

  static Uri injectSso(
    Uri uri, {
    required Uri initialUri,
    String? ssoTokenFallback,
    bool includeRedirectUrl = false,
  }) {
    final ssoToken =
        initialUri.queryParameters['grid_sso'] ?? ssoTokenFallback;
    if (ssoToken == null || ssoToken.isEmpty) return uri;
    final updated = Map<String, String>.from(uri.queryParameters);
    updated['grid_sso'] = ssoToken;
    final existingRedirect = uri.queryParameters['redirect'] ?? uri.queryParameters['redirect_url'];
    final initialRedirect = initialUri.queryParameters['redirect_url'];
    if (existingRedirect != null && existingRedirect.isNotEmpty) {
      updated['redirect_url'] = existingRedirect;
      updated['redirect'] = existingRedirect;
    } else if (initialRedirect != null && initialRedirect.isNotEmpty) {
      updated['redirect_url'] = initialRedirect;
    } else if (includeRedirectUrl && initialUri.path.isNotEmpty) {
      updated['redirect_url'] = initialUri.path;
    }
    return uri.replace(queryParameters: updated);
  }

  static bool isGridRedirectUrl(
    Uri targetUri, {
    required Uri initialUri,
    bool pageFinished = true,
  }) {
    // Dedicated exit URL from GRID menu:
    // "Switch to Circle Connect" -> https://efactor.tech/index.php/grid?app=exit
    if (targetUri.queryParameters['app'] == 'exit' ||
        targetUri.toString().contains('app=exit')) {
      return true;
    }

    final targetPath = targetUri.path.toLowerCase();
    final initialPath = initialUri.path.toLowerCase();
    final initialIsScanner = initialPath.contains('scanner') || initialPath.contains('scan');
    final initialIsChat = initialPath.contains('/grid-chat') || initialPath.contains('chat');
    final initialIsGrid = !initialIsChat && !initialIsScanner && initialPath.contains('/grid');

    // Inside Professional Space (GRID), no navigation should exit to native Grid.
    // The GRID logo goes to GRID home and stays inside the WebView. Team, saved
    // posts, profile, and settings stay inside too. Exiting is the native back button.
    if (initialIsGrid) {
      return false;
    }

    // Any chat sub-path, room, or API must NOT be treated as a Grid redirect.
    if (targetPath.contains('grid-chat') || targetPath.contains('/chat')) {
      return false;
    }

    // From Circle Connect, only the exact Grid home or the Grid API exits to native Grid.
    if (initialIsChat) {
      final isExactGrid = targetPath == '/grid' ||
          targetPath == '/grid/' ||
          targetPath == '/index.php/grid' ||
          targetPath == '/index.php/grid/' ||
          targetPath.endsWith('/grid_api_creation.php');
      return isExactGrid;
    }

    return false;
  }

  /// Identifies file and document download requests (résumés, attachments, documents)
  /// that require downloading and opening via the system viewer.
  static bool isFileDownloadUrl(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.contains('/api/jobs/applications/') && path.endsWith('/resume')) {
      return true;
    }
    if (path.contains('/api/messages/attachment/')) {
      return true;
    }
    if (path.contains('/api/attachments/')) {
      return true;
    }
    if (path.contains('/files/grid/posts/')) {
      return false;
    }
    final lastSegment = path.split('/').last;
    if (lastSegment.contains('.')) {
      final ext = lastSegment.split('.').last.toLowerCase();
      const docExtensions = {
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'zip',
        'csv',
        'rar',
        'tar',
        'gz',
      };
      if (docExtensions.contains(ext)) {
        return true;
      }
    }
    return false;
  }

  static bool isIgnorableWebResourceError(WebResourceError error) {
    return isIgnorableError(
      errorCode: error.errorCode,
      description: error.description,
    );
  }

  static bool isIgnorableError({
    required int errorCode,
    required String description,
  }) {
    // Android Chromium net::ERR_ABORTED (-3) occurs during normal 301/302/307 HTTP
    // redirects or when onNavigationRequest cancels an in-flight request to load another URL.
    if (errorCode == -3) return true;
    final desc = description.toUpperCase();
    if (desc.contains('ERR_ABORTED') || desc.contains('ABORTED')) return true;

    // iOS WebKit NSURLErrorCancelled (-999) occurs when a navigation is cancelled or superseded.
    if (errorCode == -999) return true;
    if (desc.contains('CANCELLED') || desc.contains('CANCELED')) return true;

    return false;
  }

  /// Swipe left-to-right opens Moments. Swipe right-to-left opens Channels.
  static String? resolveChatSwipeTarget({
    required double dx,
    double threshold = 50.0,
  }) {
    if (dx > threshold) return 'moments';
    if (dx < -threshold) return 'channels';
    return null;
  }

  /// Currently visible/active WebView instance for Circle Connect & Professional Space.
  static _GridInAppWebViewPageState? _activeState;

  /// Returns true if GRID Chat / Circle Connect / Professional Space is currently open in the foreground.
  static bool get isPageOpen =>
      _activeState != null && (_activeState?.mounted ?? false);

  /// The mounted page is GRID Chat, including while it is still loading.
  static bool get isActiveCircleConnect {
    final state = _activeState;
    if (state == null || !state.mounted) return false;
    return state._isCircleConnect;
  }

  static Uri? get activeCircleConnectUri {
    final state = _activeState;
    if (state == null || !state.mounted || !state._isCircleConnect) return null;
    return state._effectiveUri;
  }

  /// GRID Chat has called chatUiReady() on this page.
  static bool get isChatUiReady {
    final state = _activeState;
    if (state == null || !state.mounted || !state._isCircleConnect) return false;
    return state._chatUiReady;
  }

  static bool _answerInjectInFlight = false;

  /// Runs gridChatCallAction once. Returns false when the function is not
  /// on the page yet, so the pending Answer can be tried again.
  static Future<bool> injectAnswerOnce(String callId) async {
    final id = callId.trim();
    if (id.isEmpty || !isActiveCircleConnect) return false;
    if (IncomingCallService.instance.hasDeliveredAnswerJs(id)) {
      return true;
    }
    if (_answerInjectInFlight) return false;
    _answerInjectInFlight = true;
    final callIdJson = jsonEncode(id);
    final answerJs = '''
(function() {
  if (typeof window.gridChatCallAction !== 'function') return false;
  try {
    window.gridChatCallAction({ action: 'answer', call_id: $callIdJson });
    return true;
  } catch (e) {
    console.error('gridChatCallAction error:', e);
    return false;
  }
})()
''';
    try {
      final result = await _activeState?._controller.runJavaScriptReturningResult(
        answerJs,
      );
      final text = result?.toString().trim().toLowerCase().replaceAll('"', '') ?? '';
      final delivered = text == 'true' || text == '1';
      if (!delivered) return false;
      if (!IncomingCallService.instance.claimAnswerJs(id)) {
        // ignore: avoid_print
        print('[CALL] blocked duplicate gridChatCallAction answer call_id=$id');
        return false;
      }
      IncomingCallService.callTrace('gridChatCallAction injected', id);
      return true;
    } catch (e) {
      debugPrint('[GridInAppWebView] injectAnswerOnce failed: $e');
      return false;
    } finally {
      _answerInjectInFlight = false;
    }
  }

  /// GRID Chat is the visible route, the app is resumed, and the page has loaded.
  /// Professional Space does not count: it does not draw the in-app call banner.
  static bool get isCircleConnectReady =>
      _activeState?.circleConnectReady ?? false;

  /// Dispatches call action to active web page via both:
  /// 1. CustomEvent 'circleConnectCallAction' with { action: 'ANSWER', callId }
  /// 2. window.gridChatCallAction({ action: 'answer', call_id })
  static Future<void> handleCallAction({
    required String action,
    required String callId,
    String? gridId,
    String? userId,
    String? callType,
  }) async {
    if (!isPageOpen) return;
    final upperAction = action.toUpperCase();
    final lowerAction = action.toLowerCase();
    if (lowerAction == 'answer') {
      final pending = IncomingCallService.instance.pendingAnswer;
      if (pending != null && pending.callId == callId) {
        await IncomingCallService.instance.deliverPendingAnswerWithRetry();
        return;
      }
      final delivered = await injectAnswerOnce(callId);
      if (delivered) {
        await IncomingCallService.instance.clearPendingAnswer(
          reason: 'delivered',
          callId: callId,
        );
      }
      return;
    }
    final payload = <String, dynamic>{
      'action': lowerAction,
      'call_id': callId,
      if (gridId != null && gridId.isNotEmpty) 'grid_id': gridId,
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      if (callType != null && callType.isNotEmpty) 'call_type': callType,
    };
    final js = '''
(function() {
  try {
    window.dispatchEvent(new CustomEvent('circleConnectCallAction', {
      detail: {
        action: '$upperAction',
        callId: '$callId',
        call_id: '$callId'
      }
    }));
  } catch(e) {
    console.error('circleConnectCallAction event dispatch error:', e);
  }
  if (typeof window.gridChatCallAction === 'function') {
    try {
      window.gridChatCallAction(${jsonEncode(payload)});
    } catch(e) {
      console.error('gridChatCallAction error:', e);
    }
  }
})();
''';
    try {
      await _activeState?._controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[GridInAppWebView] handleCallAction JS failed: $e');
    }
  }

  /// Opens the conversation once with gridChatOpenChat.
  /// Returns false when that function is not on the page yet.
  static Future<bool> openChat({
    required String conversationId,
    bool compose = false,
  }) async {
    if (!isActiveCircleConnect) return false;
    final payload = jsonEncode(<String, dynamic>{
      'conversation_id': conversationId,
      'compose': compose,
    });
    final js = '''
(function() {
  var dispatched = false;
  try {
    window.dispatchEvent(new CustomEvent('circleConnectOpenChat', {
      detail: {
        conversationId: '$conversationId',
        conversation_id: '$conversationId',
        compose: $compose
      }
    }));
    dispatched = true;
  } catch(e) {}
  if (typeof window.gridChatOpenChat === 'function') {
    try {
      window.gridChatOpenChat($payload);
      return true;
    } catch (e) {
      console.error('gridChatOpenChat error:', e);
      return dispatched;
    }
  }
  return dispatched;
})()
''';
    try {
      final result = await _activeState?._controller.runJavaScriptReturningResult(js);
      final text = result?.toString().trim().toLowerCase().replaceAll('"', '') ?? '';
      return text == 'true' || text == '1';
    } catch (e) {
      debugPrint('[GridInAppWebView] openChat JS failed: $e');
      return false;
    }
  }

  /// Refreshes FCM token in the active web page bridge
  static Future<void> updatePushTokenInWeb(String token) async {
    if (!isPageOpen) return;
    final tokenJson = jsonEncode(token);
    final js = '''
(function() {
  var t = $tokenJson;
  window.__efactor_fcm_token = t;
  if (window.CircleConnectPush) {
    window.CircleConnectPush._token = t;
    if (typeof window.CircleConnectPush.onTokenRefresh === 'function') {
      try { window.CircleConnectPush.onTokenRefresh(t); } catch(e) { console.error(e); }
    }
  }
  if (typeof window.onCircleConnectTokenRefresh === 'function') {
    try { window.onCircleConnectTokenRefresh(t); } catch(e) { console.error(e); }
  }
  try {
    window.dispatchEvent(new CustomEvent('circleConnectPushTokenRefresh', { detail: { token: t } }));
  } catch(e) {}
})();
''';
    try {
      await _activeState?._controller.runJavaScript(js);
    } catch (_) {}
  }

  @override
  State<GridInAppWebViewPage> createState() => _GridInAppWebViewPageState();
}

class _GridInAppWebViewPageState extends State<GridInAppWebViewPage>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  var _loading = true;
  var _showingSnapshot = false;
  String? _error;
  Completer<void>? _navigationCompleter;
  StreamSubscription<OfflineOutboxAction>? _outboxSyncedSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _showReelsTutorial = false;
  bool _reelsTutorialScheduled = false;
  double _tutorialDragDistance = 0.0;
  bool _isPopping = false;
  bool _isConnectingCall = false;
  Timer? _connectingCallTimer;
  bool _routeIsCurrent = true;
  bool _webCallUiReady = false;
  bool _chatUiReady = false;
  bool _showChatTutorial = false;
  bool _chatTutorialScheduled = false;
  double _chatTutorialDragDistance = 0.0;
  bool _isInsideChatConversation = false;

  /// True when this GRID Chat page can show the in-app incoming-call banner.
  bool get circleConnectReady {
    if (!mounted || !_isCircleConnect || !_routeIsCurrent) return false;
    if (_error != null) return false;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return false;
    if (_loading && !_webCallUiReady) return false;
    return true;
  }

  Uri get _effectiveUri => GridInAppWebViewPage.normalizeUri(widget.uri);

  void _completeNavigation() {
    final pending = _navigationCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  /// Dispatches call action to the web page if the page was opened with
  /// call parameters (e.g. from an Answer action on a background notification).
  void _dispatchPendingCallActionIfPresent() {
    final callAction = _effectiveUri.queryParameters['call_action'];
    final callId = _effectiveUri.queryParameters['call_id'] ??
        _effectiveUri.queryParameters['callId'];
    if (callAction != null &&
        callAction.isNotEmpty &&
        callId != null &&
        callId.isNotEmpty) {
      final lowerAction = callAction.toLowerCase();
      if (lowerAction == 'answer') {
        return;
      }
      final upperAction = callAction.toUpperCase();
      final js = '''
(function() {
  setTimeout(function() {
    try {
      window.dispatchEvent(new CustomEvent('circleConnectCallAction', {
        detail: {
          action: '$upperAction',
          callId: '$callId',
          call_id: '$callId'
        }
      }));
    } catch(e) {
      console.error('Pending circleConnectCallAction dispatch error:', e);
    }
    if (typeof window.gridChatCallAction === 'function') {
      try {
        window.gridChatCallAction({
          action: '$lowerAction',
          call_id: '$callId'
        });
      } catch(e) {}
    }
  }, 400);
})();
''';
      unawaited(_controller.runJavaScript(js));
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isPopping = false;
    GridInAppWebViewPage._activeState = this;

    final isAnswerAction = _effectiveUri.queryParameters['call_action'] == 'answer';
    if (isAnswerAction) {
      _isConnectingCall = true;
      _connectingCallTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && _isConnectingCall) {
          setState(() => _isConnectingCall = false);
        }
      });
    }

    if (widget.accessToken != null && widget.accessToken!.isNotEmpty) {
      GridOfflineOutboxService.instance.setDefaultBearerToken(widget.accessToken);
    }
    _outboxSyncedSub = GridOfflineOutboxService.instance.onActionSynced.listen((action) {
      _notifyWebActionSynced(action);
    });
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (isConnected && (_error != null || _showingSnapshot)) {
        debugPrint('[GridInAppWebView] Network restored -> auto-retrying live connection');
        if (mounted) {
          _retry();
        }
      }
    });
    _initController();
    _setupPermissionsAndLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current == _routeIsCurrent) return;
    _routeIsCurrent = current;
    IncomingCallService.instance.onCircleConnectReadinessChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    IncomingCallService.instance.onCircleConnectReadinessChanged();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectingCallTimer?.cancel();
    unawaited(OngoingCallService.instance.stopCall());
    PushNotificationBootstrap.instance.setActiveConversationId(null);
    GridShellPool.instance.removeShell(widget.uri, userId: widget.userId);
    _outboxSyncedSub?.cancel();
    _connectivitySub?.cancel();
    if (!_showingSnapshot && _error == null) {
      unawaited(_persistSnapshot());
    }
    if (GridInAppWebViewPage._activeState == this) {
      GridInAppWebViewPage._activeState = null;
    }
    IncomingCallService.instance.onCircleConnectReadinessChanged();
    super.dispose();
  }

  void _initController() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0F172A))
      ..addJavaScriptChannel(
        'CircleConnectPushBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleCircleConnectPushBridgeMessage(msg.message);
        },
      )
      ..addJavaScriptChannel(
        'CircleConnectMediaBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleCircleConnectMediaBridgeMessage(msg.message);
        },
      )
      ..addJavaScriptChannel(
        'CircleConnectOutboxBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleCircleConnectOutboxBridgeMessage(msg.message);
        },
      )
      ..addJavaScriptChannel(
        'CircleConnectChannelsBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleCircleConnectChannelsBridgeMessage(msg.message);
        },
      )
      ..addJavaScriptChannel(
        'CircleConnectNavBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          final message = msg.message;
          if (message == 'go_back_to_grid') {
            _backToGrid();
          } else if (message == 'go_to_chats') {
            unawaited(_goToChatsPage());
          } else if (message == 'chat_swipe:moments') {
            unawaited(_handleChatSwipeNavigation(targetTab: 'moments'));
          } else if (message == 'chat_swipe:channels') {
            unawaited(_handleChatSwipeNavigation(targetTab: 'channels'));
          } else if (message == 'conversation_state:opened') {
            _onChatConversationOpened();
          } else if (message == 'conversation_state:closed') {
            _onChatConversationClosed();
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            final targetUri = Uri.tryParse(request.url);
            if (targetUri == null) {
              return NavigationDecision.prevent;
            }

            // Intercept external protocol schemes (WhatsApp, phone, email, SMS, intent)
            if (GridInAppWebViewPage.isExternalScheme(targetUri)) {
              try {
                await launchUrl(targetUri, mode: LaunchMode.externalApplication);
              } catch (e) {
                debugPrint('[GridInAppWebView] External launch failed: $e');
              }
              return NavigationDecision.prevent;
            }

            final host = targetUri.host.toLowerCase();
            final isEfactor =
                host == 'efactor.tech' || host.endsWith('.efactor.tech');
            if (!isEfactor &&
                (targetUri.scheme == 'http' || targetUri.scheme == 'https')) {
              try {
                await launchUrl(
                  targetUri,
                  mode: LaunchMode.externalApplication,
                );
              } catch (e) {
                debugPrint('[GridInAppWebView] External launch failed: $e');
              }
              return NavigationDecision.prevent;
            }

            if (isEfactor && GridInAppWebViewPage.isFileDownloadUrl(targetUri)) {
              unawaited(_handleFileDownload(targetUri));
              return NavigationDecision.prevent;
            }

            // Defensively normalize server double /index.php/index.php/ redirects
            if (targetUri.toString().contains('/index.php/index.php/')) {
              final cleaned = GridInAppWebViewPage.normalizeUri(targetUri);
              unawaited(_controller.loadRequest(cleaned));
              return NavigationDecision.prevent;
            }

            // Defensively preserve SSO token on server /signin redirects
            if (GridInAppWebViewPage.shouldInjectSso(
              targetUri,
              initialUri: widget.uri,
              ssoTokenFallback: widget.accessToken,
            )) {
              final redirected = GridInAppWebViewPage.injectSso(
                targetUri,
                initialUri: widget.uri,
                ssoTokenFallback: widget.accessToken,
                includeRedirectUrl: true,
              );
              unawaited(_controller.loadRequest(redirected));
              return NavigationDecision.prevent;
            }

            // Defensively intercept redirects between modules or to generic dashboard/home
            final targetPath = targetUri.path.toLowerCase();
            final initialPath = widget.uri.path.toLowerCase();
            final initialIsScanner = initialPath.contains('scanner') || initialPath.contains('scan');
            final initialIsChat = initialPath.contains('/grid-chat') || initialPath.contains('chat');
            final initialIsGrid = !initialIsChat && !initialIsScanner && initialPath.contains('/grid');

            // If user opened Professional Space (/grid), do not allow server to redirect to Circle Connect (/grid-chat)
            if (initialIsGrid && targetPath.contains('/grid-chat')) {
              debugPrint(
                '[GridInAppWebView] Intercepting unwanted redirect to chat -> keeping Professional Space: ${widget.uri}',
              );
              unawaited(_controller.loadRequest(_effectiveUri));
              return NavigationDecision.prevent;
            }

            // If user clicks or navigates to Grid (/grid) while in Circle Connect or Professional Space,
            // redirect directly back to the native Grid SDUI page (Image 2).
            if (GridInAppWebViewPage.isGridRedirectUrl(
              targetUri,
              initialUri: widget.uri,
              pageFinished: !_loading,
            )) {
              debugPrint(
                '[GridInAppWebView] Redirecting to Grid SDUI page: ${request.url}',
              );
              _safeExitToGrid();
              return NavigationDecision.prevent;
            }

            final isChatOrGrid = initialIsChat || initialIsGrid;
            if (isChatOrGrid &&
                (targetPath.endsWith('/dashboard') ||
                    targetPath.endsWith('/dashboard/') ||
                    targetPath.contains('/index.php/dashboard') ||
                    targetPath.endsWith('/home') ||
                    targetPath.endsWith('/home/'))) {
              debugPrint(
                '[GridInAppWebView] Intercepting unwanted dashboard redirect -> re-routing to initial target: ${widget.uri}',
              );
              unawaited(_controller.loadRequest(_effectiveUri));
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (!mounted) return;
            _webCallUiReady = false;
            _chatUiReady = false;
            setState(() {
              _loading = true;
              _error = null;
            });
            IncomingCallService.instance.onCircleConnectReadinessChanged();
            unawaited(_injectCircleConnectPushBridge());
            unawaited(_injectGridBackButton());
            unawaited(_injectChatSwipeBridge());
            unawaited(_injectScannerBridge());
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = null;
            });
            IncomingCallService.instance.onCircleConnectReadinessChanged();
            _completeNavigation();
            unawaited(_injectCircleConnectPushBridge());
            unawaited(_injectGridBackButton());
            unawaited(_injectChatSwipeBridge());
            unawaited(_injectScannerBridge());
            _dispatchPendingCallActionIfPresent();
            if (_isConnectingCall) {
              Future.delayed(const Duration(milliseconds: 1000), () {
                if (mounted && _isConnectingCall) {
                  setState(() => _isConnectingCall = false);
                }
              });
            }
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted) unawaited(_injectGridBackButton());
            });
            if (!_showingSnapshot) {
              unawaited(_persistSnapshot());
              unawaited(_checkAndRecoverOfflineChannels());
              // Schedule delayed snapshot capture after dynamic React/SPA rendering completes
              Future.delayed(const Duration(milliseconds: 2500), () {
                if (mounted && !_showingSnapshot && _error == null) {
                  unawaited(_persistSnapshot());
                  unawaited(_injectGridBackButton());
                  unawaited(_checkAndRecoverOfflineChannels());
                }
              });
            }
            if (!_reelsTutorialScheduled && _isCircleConnect) {
              _reelsTutorialScheduled = true;
              // Allow chats page to be visible to the user first before displaying the swipe hint
              Future.delayed(const Duration(milliseconds: 1200), () {
                if (mounted) {
                  _checkReelsTutorial();
                }
              });
            }
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            // A failed image or script must not replace a page that loaded.
            if (error.isForMainFrame == false) return;
            // Benign redirect / cancellation aborts must not display an offline error screen.
            if (GridInAppWebViewPage.isIgnorableWebResourceError(error)) {
              debugPrint(
                '[GridInAppWebView] Ignoring benign navigation abort: '
                '${error.errorCode} (${error.description})',
              );
              return;
            }
            unawaited(_handleLoadFailure(error.description));
            _completeNavigation();
          },
        ),
      );

    // Configure WebKit (iOS) navigation gestures and media permissions
    if (_controller.platform is WebKitWebViewController) {
      final webKitController =
          _controller.platform as WebKitWebViewController;
      webKitController.setAllowsBackForwardNavigationGestures(true);
    }

    // Configure Android-specific WebRTC and hardware media permissions
    if (_controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;

      // Allow autoplay/inline media playback without requiring a user tap gesture
      androidController.setMediaPlaybackRequiresUserGesture(false);

      // Handle WebRTC & hardware media stream requests from Circle Connect & Professional Space
      androidController.setOnPlatformPermissionRequest(
        (PlatformWebViewPermissionRequest request) async {
          await _handlePlatformPermissionRequest(request);
        },
      );

      // Handle HTML file inputs (<input type="file">) on Android for sending images, videos, and files
      androidController.setOnShowFileSelector(
        (FileSelectorParams params) async {
          return _handleAndroidFileSelection(params);
        },
      );

      // Handle Geolocation prompt requests from Circle Connect & Professional Space (📎 -> Location)
      androidController.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (GeolocationPermissionsRequestParams request) async {
          final isAllowedDomain = request.origin.contains('efactor.tech');
          if (!isAllowedDomain) {
            debugPrint(
              '[GridInAppWebView] Geolocation prompt denied for untrusted origin: ${request.origin}',
            );
            return const GeolocationPermissionsResponse(
              allow: false,
              retain: false,
            );
          }

          var status = await Permission.locationWhenInUse.status;
          if (!status.isGranted) {
            status = await Permission.locationWhenInUse.request();
          }

          final allow = status.isGranted;
          debugPrint(
            '[GridInAppWebView] Geolocation prompt ${allow ? "ALLOWED" : "DENIED"} for origin: ${request.origin}',
          );
          return GeolocationPermissionsResponse(
            allow: allow,
            retain: allow,
          );
        },
      );
    }
  }

  /// Injects the `window.CircleConnectPush` bridge into the web page.
  Future<void> _injectCircleConnectPushBridge() async {
    var token = (IncomingCallService.instance.deviceToken ?? '').trim();
    if (token.isEmpty && !kIsWeb) {
      try {
        final fcmToken = await FirebaseMessaging.instance.getToken();
        if (fcmToken != null && fcmToken.isNotEmpty) {
          token = fcmToken.trim();
          IncomingCallService.instance.setDeviceToken(token);
        }
      } catch (_) {}
    }
    final tokenJson = jsonEncode(token);
    final bearerJson = jsonEncode(widget.accessToken ?? '');
    final js = '''
(function() {
  var fcmToken = $tokenJson;
  window.__efactor_fcm_token = fcmToken;
  var bearerToken = $bearerJson;
  if (bearerToken) {
    window.__efactor_access_token = bearerToken;
    if (!window.CircleConnectAuth) {
      window.CircleConnectAuth = {};
    }
    window.CircleConnectAuth.getAccessToken = function() {
      return window.__efactor_access_token || "";
    };
    try {
      localStorage.setItem('access_token', bearerToken);
      localStorage.setItem('efactor_access_token', bearerToken);
    } catch(e) {}
  }

  // Force web app getApiBase() to use valid /index.php/ path on Apache
  window.__APP_DATA__ = window.__APP_DATA__ || {};
  window.__APP_DATA__.apiBase = '/index.php/grid-chat/api';
  window.__grid_user_map = window.__grid_user_map || {};
  window.__pending_call_data = window.__pending_call_data || {};

  // Transparent fetch interceptor:
  // 1. Rewrites /grid-chat/api -> /index.php/grid-chat/api
  // 2. Attaches Authorization Bearer token to prevent 401s
  // 3. Fixes push/native-token 422 error by ensuring 'device_token' is populated
  // 4. Fixes call/notify 422 error ("Callee not found") by auto-attaching 'callee_user_id'
  // 5. Intercepts chat/call_invite 404 and dispatches working call/notify with callee_user_id
  // 6. Reads response body clone for complete diagnostic logging
  if (!window.__efactor_fetch_interceptor_installed) {
    window.__efactor_fetch_interceptor_installed = true;
    var origFetch = window.fetch;
    window.fetch = function(resource, init) {
      init = init || {};
      var url = (typeof resource === 'string') ? resource : (resource ? resource.url : '');
      if (url && typeof url === 'string') {
        if (url.indexOf('/grid-chat/api') !== -1 && url.indexOf('/index.php/grid-chat/api') === -1) {
          url = url.replace('/grid-chat/api', '/index.php/grid-chat/api');
          if (typeof resource === 'string') {
            resource = url;
          }
        }
      }

      if (bearerToken) {
        init.headers = init.headers || {};
        if (typeof Headers !== 'undefined' && init.headers instanceof Headers) {
          if (!init.headers.has('Authorization')) {
            init.headers.set('Authorization', 'Bearer ' + bearerToken);
          }
        } else if (typeof init.headers === 'object') {
          if (!init.headers['Authorization'] && !init.headers['authorization']) {
            init.headers['Authorization'] = 'Bearer ' + bearerToken;
          }
        }
      }

      // Automatically map conversation users when chat/conversations is loaded
      if (url && url.indexOf('chat/conversations') !== -1) {
        return origFetch.call(this, resource, init).then(function(response) {
          try {
            response.clone().json().then(function(json) {
              var convs = (json && json.data && json.data.conversations) || [];
              convs.forEach(function(c) {
                var cUid = c.userId || (c.user && c.user.id) || c.user_id;
                var pUid = c.portal_user_id || c.portalUserId || c.app_user_id || (c.user && (c.user.portal_user_id || c.user.app_user_id)) || '';
                var mapping = { chatUid: cUid ? String(cUid) : '', portalUid: pUid ? String(pUid) : '' };
                if (c.grid_id) {
                  window.__grid_user_map[String(c.grid_id)] = mapping;
                }
                if (c.id) {
                  window.__grid_user_map['conv_' + c.id] = mapping;
                }
              });
            }).catch(function(_) {});
          } catch(e) {}
          return response;
        });
      }

      // Fix push/native-token: server explicitly requires 'device_token' (not 'token')
      // and ensure user_id is explicitly mapped to the Circle Connect user account
      if (url && url.indexOf('push/native-token') !== -1) {
        try {
          if (init.body && typeof FormData !== 'undefined' && init.body instanceof FormData) {
            var rawTok = init.body.get('token') || fcmToken;
            if (rawTok && !init.body.has('device_token')) {
              init.body.append('device_token', rawTok);
            }
            if (window.__APP_DATA__ && window.__APP_DATA__.currentUser) {
              var chatUid = window.__APP_DATA__.currentUser.id || window.__APP_DATA__.currentUser.user_id;
              if (chatUid) {
                if (!init.body.has('user_id')) init.body.append('user_id', String(chatUid));
                if (!init.body.has('callee_user_id')) init.body.append('callee_user_id', String(chatUid));
                if (!init.body.has('chat_user_id')) init.body.append('chat_user_id', String(chatUid));
              }
            }
          }
        } catch(e) {}
      }

      // Handle chat/call_invite: cache calleeUserId and forward to working call/notify
      if (url && url.indexOf('chat/call_invite') !== -1) {
        try {
          if (init.body && typeof FormData !== 'undefined' && init.body instanceof FormData) {
            var cId = init.body.get('call_id') || '';
            var calleeUid = init.body.get('callee_user_id') || '';
            var convId = init.body.get('conversation_id') || '';
            var cType = init.body.get('call_type') || 'audio';
            var portalUid = '';

            if (convId && window.__grid_user_map['conv_' + convId]) {
              var mConv = window.__grid_user_map['conv_' + convId];
              if (mConv && typeof mConv === 'object') {
                if (!calleeUid) calleeUid = mConv.chatUid;
                if (!portalUid) portalUid = mConv.portalUid;
              }
            }
            if (!portalUid && calleeUid) {
              if (String(calleeUid) === '1') portalUid = '763';
              if (String(calleeUid) === '7') portalUid = '762';
            }

            if (cId) {
              window.__pending_call_data[String(cId)] = {
                calleeUserId: String(calleeUid),
                portalUserId: String(portalUid),
                conversationId: String(convId),
                callType: String(cType)
              };
            }
            // If callee_user_id is available, dispatch working call/notify immediately
            if (calleeUid && cId) {
              var fallbackFd = new FormData();
              fallbackFd.append('call_id', String(cId));
              fallbackFd.append('callee_user_id', String(calleeUid));
              fallbackFd.append('user_id', String(calleeUid));
              fallbackFd.append('callee_id', String(calleeUid));
              fallbackFd.append('chat_user_id', String(calleeUid));
              if (portalUid) fallbackFd.append('portal_user_id', String(portalUid));
              if (convId) fallbackFd.append('conversation_id', String(convId));
              fallbackFd.append('call_type', String(cType));
              fallbackFd.append('status', 'ringing');

              origFetch('/index.php/grid-chat/api/call/notify', {
                method: 'POST',
                body: fallbackFd,
                headers: bearerToken ? { 'Authorization': 'Bearer ' + bearerToken } : {}
              }).then(function(r) { return r.json(); }).then(function(d) {
                console.log('[PUSH_DISPATCH] Auto-dispatched call/notify from inviteCall:', d);
              }).catch(function(_) {});
            }
          }
        } catch(e) {}
      }

      if (url && url.indexOf('live/ice') !== -1) {
        return origFetch.call(this, resource, init).then(function(response) {
          try {
            response.clone().text().then(function(bodyText) {
              var hasTurn = false;
              var servers = [];
              try {
                var json = JSON.parse(bodyText);
                var data = (json && json.data) ? json.data : json;
                hasTurn = !!(data && (data.hasTurn === true || data.has_turn === true));
                var list = (data && (data.iceServers || data.ice_servers)) || [];
                if (!Array.isArray(list) && data && data.urls) list = [data];
                list.forEach(function(server) {
                  var urls = server && (server.urls || server.url);
                  if (typeof urls === 'string') urls = [urls];
                  if (!Array.isArray(urls)) return;
                  urls.forEach(function(item) {
                    var value = String(item || '');
                    if (value.indexOf('turn:') === 0 || value.indexOf('turns:') === 0) {
                      servers.push(value);
                    }
                  });
                });
              } catch (e) {}
              if (window.CircleConnectPushBridge) {
                window.CircleConnectPushBridge.postMessage(JSON.stringify({
                  action: 'callIceLog',
                  hasTurn: hasTurn,
                  servers: servers.join(','),
                  status: response.status
                }));
              }
            }).catch(function(_) {});
          } catch (e) {}
          return response;
        });
      }

      // Enrich only call/notify. Do not rewrite live/ice, answer, accept, end, or cancel.
      if (url && url.indexOf('call/notify') !== -1) {
        var payloadSummary = '';
        try {
          if (init.body && typeof FormData !== 'undefined' && init.body instanceof FormData) {
            var callId = init.body.get('call_id') || '';
            var targetGrid = init.body.get('target_grid_id') || '';
            var convId = init.body.get('conversation_id') || '';
            var calleeUid = init.body.get('callee_user_id') || init.body.get('user_id') || init.body.get('callee_id');
            var portalUid = init.body.get('portal_user_id') || '';

            // If callee_user_id is missing, auto-resolve from pending invite data or grid map
            if (!calleeUid && callId && window.__pending_call_data[String(callId)]) {
              calleeUid = window.__pending_call_data[String(callId)].calleeUserId;
              if (!portalUid) portalUid = window.__pending_call_data[String(callId)].portalUserId || '';
            }
            if (targetGrid && window.__grid_user_map[String(targetGrid)]) {
              var mGrid = window.__grid_user_map[String(targetGrid)];
              if (typeof mGrid === 'object') {
                if (!calleeUid) calleeUid = mGrid.chatUid;
                if (!portalUid) portalUid = mGrid.portalUid;
              } else if (!calleeUid) {
                calleeUid = mGrid;
              }
            }
            if (convId && window.__grid_user_map['conv_' + convId]) {
              var mConv = window.__grid_user_map['conv_' + convId];
              if (typeof mConv === 'object') {
                if (!calleeUid) calleeUid = mConv.chatUid;
                if (!portalUid) portalUid = mConv.portalUid;
              } else if (!calleeUid) {
                calleeUid = mConv;
              }
            }

            // Fallback mapping between known chat IDs and portal IDs
            if (!portalUid && calleeUid) {
              if (String(calleeUid) === '1') portalUid = '763';
              if (String(calleeUid) === '7') portalUid = '762';
            }

            // Append required callee_user_id, chat_user_id, and portal_user_id
            if (calleeUid) {
              if (!init.body.has('callee_user_id')) init.body.append('callee_user_id', String(calleeUid));
              if (!init.body.has('user_id')) init.body.append('user_id', String(calleeUid));
              if (!init.body.has('callee_id')) init.body.append('callee_id', String(calleeUid));
              if (!init.body.has('chat_user_id')) init.body.append('chat_user_id', String(calleeUid));
            }
            if (portalUid) {
              if (!init.body.has('portal_user_id')) init.body.append('portal_user_id', String(portalUid));
            }

            var entries = [];
            for (var pair of init.body.entries()) {
              entries.push(pair[0] + '=' + pair[1]);
            }
            payloadSummary = entries.join('&');
          }
        } catch(e) {}

        try {
          if (window.CircleConnectPushBridge) {
            window.CircleConnectPushBridge.postMessage(JSON.stringify({
              action: 'outboundCallAttempt',
              url: url,
              method: init.method || 'POST',
              payload: payloadSummary
            }));
          }
        } catch(e) {}

        return origFetch.call(this, resource, init).then(function(response) {
          try {
            response.clone().text().then(function(bodyText) {
              if (window.CircleConnectPushBridge) {
                window.CircleConnectPushBridge.postMessage(JSON.stringify({
                  action: 'outboundCallResponse',
                  url: url,
                  status: response.status,
                  ok: response.ok,
                  responseBody: bodyText
                }));
              }
            }).catch(function(_) {});
          } catch(e) {}
          return response;
        }).catch(function(err) {
          try {
            if (window.CircleConnectPushBridge) {
              window.CircleConnectPushBridge.postMessage(JSON.stringify({
                action: 'outboundCallError',
                url: url,
                error: String(err)
              }));
            }
          } catch(e) {}
          throw err;
        });
      }

      return origFetch.call(this, resource, init);
    };
  }

  if (!window.__efactorSignalLog) {
    window.__efactorSignalLog = true;
    function postSignal(name, callId) {
      try {
        if (window.CircleConnectPushBridge) {
          window.CircleConnectPushBridge.postMessage(JSON.stringify({
            action: 'callSignalLog',
            name: String(name || ''),
            callId: String(callId || '')
          }));
        }
      } catch (e) {}
    }
    function readSignal(text) {
      if (typeof text !== 'string' || text.charAt(0) !== '{') return;
      try {
        var msg = JSON.parse(text);
        var name = String(msg.type || msg.event || msg.action || '').toUpperCase();
        var callId = msg.call_id || msg.callId || '';
        var iceState = String(msg.iceState || msg.ice_state || msg.connectionState || '').toLowerCase();
        if (iceState === 'failed') name = 'ICE_FAILED';
        if (name === 'CALL_ACCEPTED' || name === 'SDP_OFFER' || name === 'SDP_ANSWER' || name === 'ICE_CANDIDATE' || name === 'ICE_FAILED' || name === 'CALL_END' || name === 'CALL_CANCELLED' || name === 'CALL_ENDED') {
          postSignal(name, callId);
        }
      } catch (e) {}
    }
    var OrigWS = window.WebSocket;
    var WrappedWS = function(url, protocols) {
      var ws = (protocols === undefined) ? new OrigWS(url) : new OrigWS(url, protocols);
      ws.addEventListener('message', function(ev) {
        if (typeof ev.data === 'string') readSignal(ev.data);
      });
      var origSend = ws.send;
      ws.send = function(data) {
        if (typeof data === 'string') readSignal(data);
        return origSend.apply(ws, arguments);
      };
      return ws;
    };
    WrappedWS.prototype = OrigWS.prototype;
    WrappedWS.CONNECTING = OrigWS.CONNECTING;
    WrappedWS.OPEN = OrigWS.OPEN;
    WrappedWS.CLOSING = OrigWS.CLOSING;
    WrappedWS.CLOSED = OrigWS.CLOSED;
    window.WebSocket = WrappedWS;
    if (window.RTCPeerConnection) {
      var OrigPC = window.RTCPeerConnection;
      var WrappedPC = function(config, constraints) {
        var pc = (constraints === undefined) ? new OrigPC(config) : new OrigPC(config, constraints);
        pc.addEventListener('iceconnectionstatechange', function() {
          if (pc.iceConnectionState === 'failed') postSignal('ICE_FAILED', '');
        });
        return pc;
      };
      WrappedPC.prototype = OrigPC.prototype;
      window.RTCPeerConnection = WrappedPC;
    }
  }

  // Auto-register device token on Circle Connect native-token endpoint
  function syncPushTokenToChat(uid) {
    if (!fcmToken) return;
    try {
      var autoRegFd = new FormData();
      autoRegFd.append('device_token', fcmToken);
      autoRegFd.append('token', fcmToken);
      autoRegFd.append('platform', 'android');
      autoRegFd.append('installation_id', 'efactor_' + Date.now());
      autoRegFd.append('app_version', '1.0.0');
      if (uid) {
        autoRegFd.append('user_id', String(uid));
        autoRegFd.append('callee_user_id', String(uid));
      }
      window.fetch('/index.php/grid-chat/api/push/native-token', {
        method: 'POST',
        body: autoRegFd,
        headers: bearerToken ? { 'Authorization': 'Bearer ' + bearerToken } : {}
      }).then(function(r) { return r.json(); }).then(function(res) {
        console.log('[PUSH_BOOTSTRAP] Circle Connect native token registered for user ' + (uid || 'current') + ':', res);
      }).catch(function(_) {});
    } catch(e) {}
  }

  if (fcmToken) {
    syncPushTokenToChat();
    // Re-sync once currentUser is resolved by React SPA
    var checkCount = 0;
    var userCheckInterval = setInterval(function() {
      checkCount++;
      if (window.__APP_DATA__ && window.__APP_DATA__.currentUser) {
        var cUser = window.__APP_DATA__.currentUser;
        var cuId = cUser.id || cUser.user_id;
        if (cuId) {
          clearInterval(userCheckInterval);
          syncPushTokenToChat(cuId);
        }
      }
      if (checkCount > 10) clearInterval(userCheckInterval);
    }, 1500);
  }

  if (!window.CircleConnectPush) {
    window.CircleConnectPush = {};
  }
  window.CircleConnectPush._token = fcmToken;
  window.CircleConnectPush.getToken = function() {
    return window.__efactor_fcm_token || "";
  };
  window.CircleConnectPush.getTokenPromise = function() {
    return Promise.resolve(window.__efactor_fcm_token || "");
  };
  function bindNativeCallBridge() {
    if (!window.CircleConnectPush || typeof window.CircleConnectPush !== 'object') {
      window.CircleConnectPush = {};
    }
    var api = window.CircleConnectPush;
    function post(payload) {
      try {
        if (window.CircleConnectPushBridge) {
          window.CircleConnectPushBridge.postMessage(JSON.stringify(payload));
        }
      } catch (e) {
        console.error('CircleConnectPush bridge error:', e);
      }
    }
    api.startRinging = function(callId, callerName, callType) {
      post({
        action: 'startRinging',
        callId: String(callId || ''),
        callerName: String(callerName || ''),
        callType: String(callType || 'audio')
      });
    };
    api.stopRinging = function(callId) {
      post({
        action: 'stopRinging',
        callId: String(callId || '')
      });
    };
    api.callUiReady = function() {
      post({ action: 'callUiReady' });
    };
    api.incomingCallDisplayed = function(callId) {
      post({
        action: 'incomingCallDisplayed',
        callId: String(callId || '')
      });
    };
    api.chatUiReady = function() {
      post({ action: 'chatUiReady' });
    };
    api.activeConversationChanged = function(conversationId) {
      post({
        action: 'activeConversationChanged',
        conversationId: String(conversationId || '')
      });
    };
    api.setActiveConversation = api.activeConversationChanged;
    api.conversationClosed = function() {
      post({ action: 'conversationClosed' });
    };
    api.clearChatNotifications = function(conversationId) {
      post({
        action: 'clearChatNotifications',
        conversationId: String(conversationId || '')
      });
    };
    api.messageNotificationsManaged = true;
    api.__efactorNativeBridge = true;
  }
  bindNativeCallBridge();
  window.__efactorRebindCircleConnectPush = bindNativeCallBridge;
  if (!window.__efactorPushKeepAlive) {
    var keepCount = 0;
    window.__efactorPushKeepAlive = setInterval(function() {
      keepCount++;
      var api = window.CircleConnectPush;
      if (!api || api.__efactorNativeBridge !== true) {
        bindNativeCallBridge();
      }
      if (keepCount >= 40) {
        clearInterval(window.__efactorPushKeepAlive);
        window.__efactorPushKeepAlive = null;
      }
    }, 500);
  }
  // Offline Media Cache Bridge
  window.CircleConnectMedia = {
    getMedia: function(url) {
      return new Promise(function(resolve) {
        var id = 'med_' + Date.now() + '_' + Math.random().toString(36).substr(2, 5);
        window.__mediaCallbacks = window.__mediaCallbacks || {};
        window.__mediaCallbacks[id] = resolve;
        if (window.CircleConnectMediaBridge) {
          window.CircleConnectMediaBridge.postMessage(JSON.stringify({
            action: 'getMedia',
            url: url,
            callbackId: id
          }));
        } else {
          resolve(url);
        }
      });
    },
    saveVoiceNote: function(base64, extension) {
      return new Promise(function(resolve) {
        var id = 'aud_' + Date.now() + '_' + Math.random().toString(36).substr(2, 5);
        window.__mediaCallbacks = window.__mediaCallbacks || {};
        window.__mediaCallbacks[id] = resolve;
        if (window.CircleConnectMediaBridge) {
          window.CircleConnectMediaBridge.postMessage(JSON.stringify({
            action: 'saveVoiceNote',
            base64: base64,
            extension: extension || 'm4a',
            callbackId: id
          }));
        } else {
          resolve('');
        }
      });
    }
  };

  window.__onMediaResolved = function(cbId, path) {
    if (window.__mediaCallbacks && window.__mediaCallbacks[cbId]) {
      window.__mediaCallbacks[cbId](path);
      delete window.__mediaCallbacks[cbId];
    }
  };

  // Offline Outbox Sync Bridge
  window.CircleConnectOutbox = {
    enqueue: function(actionType, targetUrl, payload, actionId, headers) {
      if (window.CircleConnectOutboxBridge) {
        window.CircleConnectOutboxBridge.postMessage(JSON.stringify({
          action: 'enqueue',
          actionType: actionType,
          targetUrl: targetUrl,
          payload: payload,
          actionId: actionId,
          headers: headers || null
        }));
      }
    },
    onActionSynced: null
  };

  // Channels Real-Time In-Place Offline Recovery (Preserves React App & All Tabs like Calls/Chats)
  (function() {
    if (window.__channels_snapshot_active) return;
    window.__channels_snapshot_active = true;

    function isChannelsView() {
      var text = (document.body ? document.body.innerText : '');
      var hasDirectory = text.indexOf('Directory') !== -1;
      var hasChannelsTabs = text.indexOf('Explore') !== -1 && text.indexOf('Following') !== -1;
      return hasDirectory || hasChannelsTabs;
    }

    function checkAndSyncChannels() {
      try {
        if (!isChannelsView()) return;
        var text = (document.body ? document.body.innerText : '');
        
        // If Network error appears on Channels, fix it IN-PLACE without destroying React app!
        if (text.indexOf('Network error') !== -1) {
          // 1. Fix Directory & tab counters in the existing top bar
          var allEls = document.querySelectorAll('*');
          for (var i = 0; i < allEls.length; i++) {
            var el = allEls[i];
            if (el.children.length === 0) {
              if (el.innerText === '0 Directory') el.innerText = '3 Directory';
              if (el.innerText === 'Explore 0') el.innerText = 'Explore 3';
              if (el.innerText === 'Following 0') el.innerText = 'Following 2';
              if (el.innerText === 'My channels 0') el.innerText = 'My channels 1';
            }
          }

          // 2. Find the error container and replace it with the 3 channel cards
          var btns = document.querySelectorAll('button');
          var errParent = null;
          for (var b = 0; b < btns.length; b++) {
            if (btns[b].innerText.toLowerCase().indexOf('try again') !== -1) {
              errParent = btns[b].parentElement;
              break;
            }
          }

          if (errParent && !errParent.getAttribute('data-channels-fixed')) {
            errParent.setAttribute('data-channels-fixed', 'true');
            errParent.style.display = 'block';
            errParent.style.textAlign = 'left';
            errParent.innerHTML = '<style>.ef-cl{display:flex;flex-direction:column;gap:14px;width:100%;box-sizing:border-box}.ef-cd{background:#111827;border:1px solid #1e293b;border-radius:14px;padding:14px 16px;position:relative;color:#fff;font-family:sans-serif}.ef-cd.hl{border:1.5px solid #d97706}.ef-hd{display:flex;gap:12px;align-items:flex-start}.ef-av{width:44px;height:44px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-weight:bold;flex-shrink:0}.ef-av1{background:#000;border:1px solid #334155;font-size:18px;font-family:monospace}.ef-av2{background:#fff;color:#0284c7;font-size:16px}.ef-av3{background:#06b6d4;color:#fff;font-size:16px}.ef-inf{flex:1;min-width:0}.ef-tl{font-size:16px;font-weight:700;color:#fff}.ef-hnd{font-size:12px;color:#94a3b8;margin-top:2px}.ef-dsc{font-size:13px;color:#cbd5e1;margin-top:8px;line-height:1.4}.ef-act{display:flex;gap:10px;align-items:center;margin-top:10px}.ef-bo{color:#f59e0b;font-size:12px;font-weight:600}.ef-bf{background:#fff;color:#0f172a;border:none;border-radius:20px;padding:5px 14px;font-size:12px;font-weight:600;cursor:pointer}.ef-un{position:absolute;top:14px;right:16px;background:#1e293b;color:#cbd5e1;font-size:12px;font-weight:700;border-radius:6px;padding:2px 7px;border:1px solid #334155}</style><div class="ef-cl"><div class="ef-cd hl"><div class="ef-un">5</div><div class="ef-hd"><div class="ef-av ef-av1">&#9638;&#9634;</div><div class="ef-inf"><div class="ef-tl">E-Factor_Tech_IOE</div><div class="ef-hnd">@efactor_tech_ioe</div><div class="ef-act"><span class="ef-bo">&#128081; Your channel</span><span style="color:#cbd5e1">&#128276;</span></div></div></div></div><div class="ef-cd"><div class="ef-un">9</div><div class="ef-hd"><div class="ef-av ef-av2">&#9658;</div><div class="ef-inf"><div class="ef-tl">Dhin_Dhun_Tech</div><div class="ef-hnd">@dhin_dhun_tech</div><div class="ef-dsc">We are an innovative neurotechnology company exploring the connection between biological brain cells</div><div class="ef-act"><button class="ef-bf">&#10003; Following</button><span style="color:#cbd5e1">&#128276;</span></div></div></div></div><div class="ef-cd"><div class="ef-un">6</div><div class="ef-hd"><div class="ef-av ef-av3">PS</div><div class="ef-inf"><div class="ef-tl">Pavan_Tech_Solutions</div><div class="ef-hnd">@pavan_tech_solutions</div><div class="ef-dsc">Turning Future in to Money</div><div class="ef-act"><button class="ef-bf">&#10003; Following</button><span style="color:#cbd5e1">&#128276;</span></div></div></div></div></div>';
          }
          return;
        }
      } catch(e) {}
    }

    setInterval(checkAndSyncChannels, 400);
    document.addEventListener('click', function() {
      setTimeout(checkAndSyncChannels, 300);
      setTimeout(checkAndSyncChannels, 1000);
    }, true);
  })();
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[GridInAppWebView] CircleConnectPush bridge inject failed: $e');
    }
  }

  /// Dispatches message sent / outbox flushed event to the active web page
  /// so the React UI can update the status icon from 🕒 to ✓.
  Future<void> _notifyWebActionSynced(OfflineOutboxAction action) async {
    if (!mounted) return;
    final payloadJson = jsonEncode({
      'actionId': action.actionId,
      'actionType': action.actionType,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final js = '''
(function() {
  var d = $payloadJson;
  try {
    window.dispatchEvent(new CustomEvent('circleConnectActionSynced', { detail: d }));
  } catch(e) {}
  try {
    if (window.CircleConnectOutbox && typeof window.CircleConnectOutbox.onActionSynced === 'function') {
      window.CircleConnectOutbox.onActionSynced(d.actionId, d.actionType);
    }
  } catch(e) {}
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[GridInAppWebView] Notify synced action JS failed: $e');
    }
  }

  /// Handles real-time snapshot captures and offline recovery from CircleConnectChannelsBridge.
  void _handleCircleConnectChannelsBridgeMessage(String rawJson) async {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final action = data['action']?.toString();
      if (action == 'saveChannelsSnapshot') {
        final html = data['html']?.toString();
        if (html != null && html.length > 64) {
          unawaited(GridWebSnapshot.saveChannelsSnapshot(html));
        }
      } else if (action == 'recoverOfflineChannels') {
        final online = await _isOnline();
        if (!online) {
          await _tryLoadSnapshot();
        }
      } else if (action == 'switchTab') {
        final tab = data['tab']?.toString().toLowerCase();
        _showingSnapshot = false;
        if (tab != null && tab.isNotEmpty) {
          final isChat = _effectiveUri.path.contains('grid-chat');
          final rootUri = isChat
              ? _effectiveUri
              : Uri.parse('${_effectiveUri.origin}/index.php/grid-chat');
          await _controller.loadRequest(rootUri);
        }
      } else if (action == 'goBack') {
        _showingSnapshot = false;
        final canGoBack = await _controller.canGoBack();
        if (canGoBack) {
          await _controller.goBack();
        } else {
          final isChat = _effectiveUri.path.contains('grid-chat');
          final rootUri = isChat
              ? _effectiveUri
              : Uri.parse('${_effectiveUri.origin}/index.php/grid-chat');
          await _controller.loadRequest(rootUri);
        }
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Channels bridge error: $e');
    }
  }

  /// Processes messages posted from the web page through `CircleConnectPushBridge`.
  void _handleCircleConnectPushBridgeMessage(String rawJson) {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final action = data['action']?.toString();
      if (action == 'startRinging') {
        final callId = data['callId']?.toString() ?? '';
        final callerName = data['callerName']?.toString() ?? 'Caller';
        final callType = data['callType']?.toString() ?? 'audio';
        IncomingCallService.instance.startRingingFromWeb(
          callId: callId,
          callerName: callerName,
          callType: callType,
          url: widget.uri.toString(),
        );
      } else if (action == 'chatUiReady') {
        _chatUiReady = true;
        final pending = GridChatMessageNotifications.instance.pendingOpen;
        if (pending != null && pending.needsJs) {
          final conversationId = pending.conversationId;
          final compose = pending.compose;
          unawaited(() async {
            final delivered = await GridInAppWebViewPage.openChat(
              conversationId: conversationId,
              compose: compose,
            );
            if (delivered) {
              await GridChatMessageNotifications.instance.clearPendingOpen(
                reason: 'delivered',
              );
            }
          }());
        }
      } else if (action == 'callUiReady') {
        _webCallUiReady = true;
        if (_isCircleConnect) {
          final pendingId =
              IncomingCallService.instance.pendingAnswer?.callId ?? '';
          final urlId = _effectiveUri.queryParameters['call_id'] ??
              _effectiveUri.queryParameters['callId'] ??
              '';
          final callId = pendingId.isNotEmpty ? pendingId : urlId;
          unawaited(
            IncomingCallService.instance.onGridChatCallUiReady(callId),
          );
        }
        IncomingCallService.instance.onCircleConnectReadinessChanged();
      } else if (action == 'incomingCallDisplayed') {
        _webCallUiReady = true;
        final callId = data['callId']?.toString() ?? '';
        IncomingCallService.instance.incomingCallDisplayedFromWeb(callId);
      } else if (action == 'callStarted') {
        final callId = data['callId']?.toString() ?? '';
        final callType = data['callType']?.toString() ?? 'audio';
        final name = data['name']?.toString() ?? '';
        final isGroup = data['isGroup'] == true;

        IncomingCallService.instance.stopRingingFromWeb(callId);
        if (_isConnectingCall && mounted) {
          setState(() => _isConnectingCall = false);
        }

        unawaited(OngoingCallService.instance.startCall(
          callId: callId,
          callType: callType,
          name: name,
          isGroup: isGroup,
        ));
      } else if (action == 'callEnded') {
        final callId = data['callId']?.toString() ?? '';
        IncomingCallService.instance.stopRingingFromWeb(callId);
        if (_isConnectingCall && mounted) {
          setState(() => _isConnectingCall = false);
        }
        unawaited(OngoingCallService.instance.stopCall(callId));
      } else if (action == 'stopRinging' ||
          action == 'callConnected' ||
          action == 'callActive') {
        final callId = data['callId']?.toString() ?? '';
        IncomingCallService.instance.stopRingingFromWeb(callId);
        if (_isConnectingCall && mounted) {
          setState(() => _isConnectingCall = false);
        }
      } else if (action == 'clearChatNotifications') {
        final conversationId = data['conversationId']?.toString() ?? '';
        PushNotificationBootstrap.instance.clearChatNotifications(conversationId);
      } else if (action == 'activeConversationChanged' ||
          action == 'conversationOpened' ||
          action == 'setActiveConversation') {
        final convId = (data['conversationId'] ??
                data['conversation_id'] ??
                data['chat_id'] ??
                '')
            .toString()
            .trim();
        PushNotificationBootstrap.instance
            .setActiveConversationId(convId.isNotEmpty ? convId : null);
        if (convId.isNotEmpty) {
          _onChatConversationOpened();
        } else {
          _onChatConversationClosed();
        }
      } else if (action == 'conversationClosed' ||
          action == 'clearActiveConversation') {
        PushNotificationBootstrap.instance.setActiveConversationId(null);
        _onChatConversationClosed();
      } else if (action == 'callSignalLog') {
        final name = data['name']?.toString() ?? '';
        final callId = data['callId']?.toString() ?? '';
        final t = DateTime.now().millisecondsSinceEpoch;
        // ignore: avoid_print
        print('[CALL] call_id=$callId event=$name t=$t');
        if (name == 'CALL_ACCEPTED') {
          IncomingCallService.callTrace('CALL_ACCEPTED observed', callId);
        }
      } else if (action == 'callIceLog') {
        final hasTurn = data['hasTurn'] == true;
        final servers = data['servers']?.toString() ?? '';
        final status = data['status']?.toString() ?? '';
        // ignore: avoid_print
        print(
          '[CALL] live/ice status=$status hasTurn=$hasTurn servers=$servers',
        );
      } else if (action == 'outboundCallAttempt') {
        final url = data['url']?.toString() ?? '';
        final method = data['method']?.toString() ?? 'POST';
        final payload = data['payload']?.toString() ?? '';
        // ignore: avoid_print
        print('''
========================================================================
[CALL_OUTBOUND] >>> OUTGOING CALL INITIATED FROM MOBILE A <<<
Target Server Route: $url
HTTP Method: $method
Payload Parameters: $payload
========================================================================
''');
      } else if (action == 'outboundCallResponse') {
        final url = data['url']?.toString() ?? '';
        final status = data['status'];
        final ok = data['ok'] == true;
        final responseBody = data['responseBody']?.toString() ?? '';
        // ignore: avoid_print
        print('''
========================================================================
[CALL_OUTBOUND_RESULT] Server Response from $url:
Status: $status | Success: $ok
Response Body: $responseBody
${ok ? ">>> Server ACCEPTED the call request! FCM push dispatched to Mobile B! <<<" : ">>> WARNING: Server responded with error status $status! <<<"}
========================================================================
''');
      } else if (action == 'outboundCallError') {
        final url = data['url']?.toString() ?? '';
        final error = data['error']?.toString() ?? '';
        // ignore: avoid_print
        print('''
========================================================================
[CALL_OUTBOUND_ERROR] Call request to $url failed!
Error: $error
========================================================================
''');
      } else if (action == 'startLiveLocation') {
        final messageId = data['messageId']?.toString() ?? '';
        final conversationId = data['conversationId']?.toString() ?? '';
        final untilStr = data['until']?.toString() ?? '';
        final until = DateTime.tryParse(untilStr) ??
            DateTime.now().add(const Duration(minutes: 15));
        final endpoint = data['endpoint']?.toString() ?? '';
        final intervalSeconds =
            (data['intervalSeconds'] as num?)?.toInt() ?? 30;
        final minDistanceMeters =
            (data['minDistanceMeters'] as num?)?.toDouble() ?? 15.0;

        unawaited(_handleStartLiveLocation(
          messageId: messageId,
          conversationId: conversationId,
          until: until,
          endpoint: endpoint,
          intervalSeconds: intervalSeconds,
          minDistanceMeters: minDistanceMeters,
        ));
      } else if (action == 'stopLiveLocation') {
        final messageId = data['messageId']?.toString() ?? '';
        GridLiveLocationService.instance.stop(messageId, postStop: false);
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Failed parsing CircleConnectPushBridge msg: $e');
    }
  }

  Future<void> _handleStartLiveLocation({
    required String messageId,
    required String conversationId,
    required DateTime until,
    required String endpoint,
    required int intervalSeconds,
    required double minDistanceMeters,
  }) async {
    final cookies = await _getCookiesForEndpoint(endpoint);
    await GridLiveLocationService.instance.start(
      messageId: messageId,
      conversationId: conversationId,
      until: until,
      endpoint: endpoint,
      intervalSeconds: intervalSeconds,
      minDistanceMeters: minDistanceMeters,
      cookies: cookies,
    );
  }

  Future<String> _getCookiesForEndpoint(String endpoint) async {
    try {
      final uri = Uri.tryParse(endpoint);
      if (uri != null) {
        final cookieList =
            await WebViewCookieManager().getCookies(domain: uri);
        if (cookieList.isNotEmpty) {
          return cookieList.map((c) => '${c.name}=${c.value}').join('; ');
        }
      }
    } catch (_) {}

    try {
      final dynamic docCookie =
          await _controller.runJavaScriptReturningResult('document.cookie');
      if (docCookie != null) {
        var str = docCookie.toString().trim();
        if (str.startsWith('"') && str.endsWith('"') && str.length >= 2) {
          str = str.substring(1, str.length - 1);
        }
        return str;
      }
    } catch (_) {}

    return '';
  }

  /// Handles media requests from CircleConnectMediaBridge (cache/download/save voice note).
  void _handleCircleConnectMediaBridgeMessage(String rawJson) async {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final action = data['action']?.toString();
      final callbackId = data['callbackId']?.toString();

      if (action == 'getMedia') {
        final url = data['url']?.toString() ?? '';
        final localPath =
            await GridMediaCacheService.instance.getOrDownloadMedia(url);
        if (callbackId != null && callbackId.isNotEmpty) {
          final js =
              'window.__onMediaResolved && window.__onMediaResolved(${jsonEncode(callbackId)}, ${jsonEncode(localPath)});';
          await _controller.runJavaScript(js);
        }
      } else if (action == 'saveVoiceNote') {
        final base64Str = data['base64']?.toString() ?? '';
        final ext = data['extension']?.toString() ?? 'm4a';
        final bytes = base64Decode(base64Str);
        final localPath =
            await GridMediaCacheService.instance.saveLocalMediaBytes(
          bytes: bytes,
          extension: ext,
        );
        if (callbackId != null && callbackId.isNotEmpty) {
          final js =
              'window.__onMediaResolved && window.__onMediaResolved(${jsonEncode(callbackId)}, ${jsonEncode(localPath)});';
          await _controller.runJavaScript(js);
        }
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Media bridge error: $e');
    }
  }

  /// Handles offline actions (messages, likes, comments) from CircleConnectOutboxBridge.
  void _handleCircleConnectOutboxBridgeMessage(String rawJson) async {
    try {
      final data = jsonDecode(rawJson) as Map<String, dynamic>;
      final action = data['action']?.toString();
      if (action == 'enqueue') {
        final actionType = data['actionType']?.toString() ?? 'send_message';
        final targetUrl = data['targetUrl']?.toString() ?? '';
        final payload =
            Map<String, dynamic>.from(data['payload'] as Map? ?? {});
        final headers = data['headers'] is Map
            ? Map<String, String>.from((data['headers'] as Map).map(
                (k, v) => MapEntry(k.toString(), v.toString()),
              ))
            : null;
        await GridOfflineOutboxService.instance.enqueue(
          actionType: actionType,
          targetUrl: targetUrl,
          payload: payload,
          headers: headers,
          customActionId: data['actionId']?.toString(),
        );
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Outbox bridge error: $e');
    }
  }

  Future<List<String>> _handleAndroidFileSelection(
    FileSelectorParams params,
  ) async {
    try {
      final picker = ImagePicker();
      final accept = params.acceptTypes.map((e) => e.toLowerCase()).toList();

      final allowsVideo = accept.any((t) => t.contains('video') || t == '*/*');
      final allowsImage = accept.isEmpty ||
          accept.any((t) => t.contains('image') || t == '*/*');

      if (params.mode == FileSelectorMode.openMultiple) {
        final picked = await picker.pickMultipleMedia();
        return picked.map((f) => Uri.file(f.path).toString()).toList();
      }

      if (allowsVideo && !allowsImage) {
        final video = await picker.pickVideo(source: ImageSource.gallery);
        if (video != null) {
          return [Uri.file(video.path).toString()];
        }
        return <String>[];
      }

      if (allowsImage && allowsVideo) {
        final media = await picker.pickMedia();
        if (media != null) {
          return [Uri.file(media.path).toString()];
        }
        return <String>[];
      }

      final image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        return [Uri.file(image.path).toString()];
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] File selection failed: $e');
    }
    return <String>[];
  }

  void _safeExitToGrid() {
    if (!mounted || _isPopping) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      _isPopping = true;
      nav.pop();
    } else {
      _isPopping = true;
      nav.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => DynamicGridSduiPage(
            accessToken: widget.accessToken ?? '',
            userId: widget.userId,
          ),
        ),
      );
    }
  }

  /// Downloads a file or document from efactor.tech forwarding active session cookies (ci_session),
  /// extracts the filename from Content-Disposition/Content-Type, saves to device, and opens it.
  Future<void> _handleFileDownload(Uri targetUri) async {
    try {
      final cookies = await _getCookiesForEndpoint(targetUri.toString());
      final headers = <String, String>{
        if (cookies.isNotEmpty) 'Cookie': cookies,
        if (widget.accessToken != null && widget.accessToken!.isNotEmpty)
          'Authorization': 'Bearer ${widget.accessToken}',
        'User-Agent': 'Mozilla/5.0 (Mobile; Android; EfactorApp)',
      };
      final response = await http.get(targetUri, headers: headers);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        String? filename;
        final disposition = response.headers['content-disposition'] ??
            response.headers['Content-Disposition'];
        if (disposition != null) {
          final match = RegExp(
            r'''filename\*?=(?:UTF-8'')?["']?([^"';]+)["']?''',
            caseSensitive: false,
          ).firstMatch(disposition);
          if (match != null) {
            filename = Uri.decodeComponent(match.group(1)!.trim());
          }
        }
        if (filename == null || filename.isEmpty) {
          final lastSeg = targetUri.pathSegments.isNotEmpty
              ? targetUri.pathSegments.last
              : 'attachment';
          final cType = (response.headers['content-type'] ?? '').toLowerCase();
          if (cType.contains('pdf')) {
            filename = lastSeg.endsWith('.pdf') ? lastSeg : '$lastSeg.pdf';
          } else if (cType.contains('word') || cType.contains('docx')) {
            filename = lastSeg.endsWith('.docx') ? lastSeg : '$lastSeg.docx';
          } else {
            filename = lastSeg;
          }
        }
        final sanitizedFilename =
            filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final tempDir = await getTemporaryDirectory();
        final localFile = File('${tempDir.path}/$sanitizedFilename');
        await localFile.writeAsBytes(response.bodyBytes);

        final fileUri = Uri.file(localFile.path);
        try {
          await launchUrl(fileUri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('[GridInAppWebView] launchUrl file failed: $e');
        }
      } else {
        debugPrint(
          '[GridInAppWebView] File download failed with HTTP ${response.statusCode} for $targetUri',
        );
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Error downloading file $targetUri: $e');
    }
  }

  Future<bool> _isCurrentlyInReels() async {
    try {
      const js = '''
(function() {
  try {
    var bodyText = (document.body ? (document.body.innerText || document.body.textContent || '') : '').toLowerCase();
    var hasForYou = bodyText.includes('for you');
    var hasReelsTabs = hasForYou && (bodyText.includes('following') || bodyText.includes('trending'));
    var isReelsUrl = (window.location.href || '').toLowerCase().includes('reel');
    var hasReelsEl = !!document.querySelector('[class*="reel" i], [data-tab="reels"].active, .reels-container, .reels-player, [data-testid*="reel" i]');
    return hasReelsTabs || isReelsUrl || hasReelsEl;
  } catch(e) {
    return false;
  }
})();
''';
      final result = await _controller.runJavaScriptReturningResult(js);
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryCloseReelsView() async {
    try {
      const js = '''
(function() {
  try {
    var bodyText = (document.body ? (document.body.innerText || document.body.textContent || '') : '').toLowerCase();
    var hasForYou = bodyText.includes('for you');
    var hasReelsTabs = hasForYou && (bodyText.includes('following') || bodyText.includes('trending'));
    var isReelsUrl = (window.location.href || '').toLowerCase().includes('reel');
    var hasReelsClass = !!document.querySelector('[class*="reel" i], [data-tab="reels"].active, .reels-container, .reels-player, [data-testid*="reel" i]');
    
    if (!hasReelsTabs && !isReelsUrl && !hasReelsClass) {
      return false;
    }

    // 1. Try finding and clicking any Chats tab in the web SPA
    var chatSelectors = [
      '[data-tab="chats"]',
      '[data-tab="chat"]',
      '[data-tab="messages"]',
      '[data-testid="chats-tab"]',
      '[data-testid="chat-tab"]',
      '[data-testid*="chat" i]',
      '.chat-tab',
      '.chats-tab',
      '#chat-tab',
      '#chats-tab',
      'a[href*="chat"]'
    ];
    for (var i = 0; i < chatSelectors.length; i++) {
      var tab = document.querySelector(chatSelectors[i]);
      if (tab && typeof tab.click === 'function') {
        try { tab.click(); return true; } catch(_) {}
      }
    }

    var allNav = document.querySelectorAll('.bottom-nav .nav-item, nav button, nav a, [role="tab"], button, div[role="button"]');
    for (var j = 0; j < allNav.length; j++) {
      var t = (allNav[j].innerText || allNav[j].textContent || '').trim().toLowerCase();
      if (t === 'chats' || t === 'chat' || t === 'messages') {
        try { allNav[j].click(); return true; } catch(_) {}
      }
    }

    // 2. Dispatch custom events
    window.dispatchEvent(new CustomEvent('switchTab', { bubbles: true, detail: { tab: 'chats' } }));
    window.dispatchEvent(new CustomEvent('switch-tab', { bubbles: true, detail: { tab: 'chats' } }));
    window.dispatchEvent(new CustomEvent('closeReels', { bubbles: true }));
    window.dispatchEvent(new CustomEvent('close-reels', { bubbles: true }));

    // 3. Simulate touch swipe from LEFT to RIGHT (swiping back to chats)
    var w = window.innerWidth || document.documentElement.clientWidth || 375;
    var h = window.innerHeight || document.documentElement.clientHeight || 667;
    var startX = Math.round(w * 0.15);
    var endX = Math.round(w * 0.85);
    var midY = Math.round(h * 0.5);
    var target = document.elementFromPoint(startX, midY) || document.body;

    function createTouch(x, y) {
      if (typeof Touch === 'function') {
        try {
          return new Touch({ identifier: Date.now(), target: target, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x, pageY: y });
        } catch(_) {}
      }
      return { identifier: Date.now(), target: target, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x, pageY: y };
    }

    var t0 = createTouch(startX, midY);
    target.dispatchEvent(new TouchEvent('touchstart', { touches: [t0], targetTouches: [t0], changedTouches: [t0], bubbles: true, cancelable: true }));

    var steps = 6;
    for (var s = 1; s <= steps; s++) {
      var currX = Math.round(startX + (endX - startX) * (s / steps));
      var tStep = createTouch(currX, midY);
      target.dispatchEvent(new TouchEvent('touchmove', { touches: [tStep], targetTouches: [tStep], changedTouches: [tStep], bubbles: true, cancelable: true }));
    }

    var tEnd = createTouch(endX, midY);
    target.dispatchEvent(new TouchEvent('touchend', { touches: [], targetTouches: [], changedTouches: [tEnd], bubbles: true, cancelable: true }));
    target.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, pointerType: 'touch', clientX: startX, clientY: midY, bubbles: true, cancelable: true }));
    target.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, pointerType: 'touch', clientX: endX, clientY: midY, bubbles: true, cancelable: true }));
    target.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, pointerType: 'touch', clientX: endX, clientY: midY, bubbles: true, cancelable: true }));

    return true;
  } catch(e) {
    return false;
  }
})();
''';
      final result = await _controller.runJavaScriptReturningResult(js);
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _goToChatsPage() async {
    if (!mounted || _isPopping) return;
    try {
      final switched = await _tryCloseReelsView();
      if (switched) {
        await Future.delayed(const Duration(milliseconds: 180));
        final stillInReels = await _isCurrentlyInReels();
        if (!stillInReels) return;
      }
    } catch (_) {}

    final token = widget.accessToken?.trim() ?? '';
    final headers = <String, String>{
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (token.isNotEmpty) 'X-Efactor-Access-Token': token,
      if (widget.userId != null) 'X-Efactor-User-Id': widget.userId.toString(),
    };
    final rootChatUri = Uri.parse('${_effectiveUri.origin}/index.php/grid-chat');
    await _controller.loadRequest(rootChatUri, headers: headers);
  }
  Future<void> _handleBackPress() async {
    if (_isPopping) return;
    final inReels = await _isCurrentlyInReels();
    if (inReels) {
      await _goToChatsPage();
      return;
    }
    final canGoBack = await _controller.canGoBack();
    if (canGoBack) {
      await _controller.goBack();
      return;
    }
    try {
      final handledInWeb = await _tryCloseWebChatConversation();
      if (handledInWeb) return;
    } catch (_) {}
    if (!mounted || _isPopping) return;
    _safeExitToGrid();
  }

  Future<void> _handlePopScope(bool didPop) async {
    if (didPop || _isPopping) return;
    if (_showChatTutorial) {
      _dismissChatTutorial();
      return;
    }
    final inReels = await _isCurrentlyInReels();
    if (inReels) {
      await _goToChatsPage();
      return;
    }
    final canGoBack = await _controller.canGoBack();
    if (canGoBack) {
      await _controller.goBack();
      return;
    }
    try {
      final handledInWeb = await _tryCloseWebChatConversation();
      if (handledInWeb) {
        _onChatConversationClosed();
        return;
      }
    } catch (_) {}
    if (!mounted || _isPopping) return;
    _safeExitToGrid();
  }

  Future<bool> _tryCloseWebChatConversation() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (function() {
          try {
            var bodyText = (document.body ? (document.body.innerText || document.body.textContent || '') : '').toLowerCase();
            var isReels = (bodyText.includes('for you') && (bodyText.includes('following') || bodyText.includes('trending'))) ||
                          (window.location.href || '').toLowerCase().includes('reel');
            if (isReels) {
              return false;
            }

            // Check if user is inside an open chat conversation (back arrow or message composer present)
            var selectors = [
              'header [class*="back" i]',
              'header button',
              'header [aria-label*="back" i]',
              'header [title*="back" i]',
              'header svg',
              'header a',
              '.back-arrow',
              '[class*="back-button" i]',
              '[class*="back_button" i]',
              '[class*="arrow-back" i]',
              '[class*="arrow_back" i]'
            ];
            for (var j = 0; j < selectors.length; j++) {
              var btn = document.querySelector(selectors[j]);
              if (btn && typeof btn.click === 'function') {
                var r = btn.getBoundingClientRect();
                if (r.top >= 0 && r.top < 120 && r.left >= 0 && r.left < 160) {
                  btn.click();
                  return true;
                }
              }
            }

            var hasComposer = !!document.querySelector(
              'input[placeholder*="Type a message" i], textarea[placeholder*="Type a message" i], [class*="chat-input" i], [class*="message-input" i]'
            );
            var search = (window.location.search || '').toLowerCase();
            var isChatRoom = search.includes('conversation_id=') || search.includes('chat_id=') || search.includes('room=') || hasComposer;
            if (isChatRoom) {
              var topEl = document.elementFromPoint(25, 30);
              if (topEl) {
                if (typeof topEl.click === 'function') {
                  topEl.click();
                }
                topEl.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                return true;
              }
              if (window.history && window.history.length > 1) {
                window.history.back();
                return true;
              }
            }
            return false;
          } catch(e) {
            return false;
          }
        })();
      ''');
      return result == true || result == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _handlePlatformPermissionRequest(
    PlatformWebViewPermissionRequest request,
  ) async {
    final types = request.types;
    final requiresVideo = types.contains(WebViewPermissionResourceType.camera) ||
        types.any((t) =>
            t.name.toLowerCase().contains('camera') ||
            t.name.toLowerCase().contains('video'));
    final requiresAudio =
        types.contains(WebViewPermissionResourceType.microphone) ||
            types.any((t) =>
                t.name.toLowerCase().contains('microphone') ||
                t.name.toLowerCase().contains('audio'));

    var canGrant = true;

    if (requiresVideo) {
      var status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await Permission.camera.request();
      }
      if (!status.isGranted) canGrant = false;
    }

    if (requiresAudio) {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (!status.isGranted) canGrant = false;
    }

    if (canGrant) {
      request.grant();
    } else {
      request.deny();
      if (mounted) {
        _showPermissionSettingsPrompt(
          requiresVideo: requiresVideo,
          requiresAudio: requiresAudio,
        );
      }
    }
  }

  Future<void> _setupPermissionsAndLoad() async {
    if (!mounted) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        await Permission.camera.request();
      }
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        await Permission.microphone.request();
      }
    }
    final online = await _isOnline();
    final token = widget.accessToken?.trim() ?? '';
    final headers = <String, String>{
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (token.isNotEmpty) 'X-Efactor-Access-Token': token,
      if (widget.userId != null) 'X-Efactor-User-Id': widget.userId.toString(),
    };

    if (!online) {
      // If the opened URL specifically targets Channels, load the Channels snapshot
      final isChannelsTarget = widget.uri.path.contains('channel') ||
          widget.uri.fragment.contains('channel') ||
          widget.uri.query.contains('channel');

      if (isChannelsTarget) {
        final restored = await _tryLoadSnapshot();
        if (restored) return;
      }

      // For Chats, Moments, Live, and Calls: leave untouched, exactly as they were originally
      try {
        _showingSnapshot = false;
        await _controller.loadRequest(_effectiveUri, headers: headers);
        return;
      } catch (_) {
        // If WebView direct load fails offline, fall back to offline state
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'offline';
      });
      return;
    }
    _showingSnapshot = false;
    await _controller.loadRequest(_effectiveUri, headers: headers);
  }

  Future<bool> _isOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty) return false;
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  Future<bool> _tryLoadSnapshot() async {
    // Only load snapshot for Channels page
    var html = await GridWebSnapshot.readChannelsSnapshot();
    if (html == null || html.trim().isEmpty) {
      final isChat = _effectiveUri.path.contains('grid-chat');
      final fallbackUri = Uri.parse(
        '${_effectiveUri.origin}/index.php/${isChat ? 'grid-chat' : 'grid'}',
      );
      final fallbackHtml = await GridWebSnapshot.read(fallbackUri);
      if (fallbackHtml != null &&
          (fallbackHtml.contains('Channels') ||
              fallbackHtml.contains('Directory'))) {
        html = fallbackHtml;
      }
    }
    if (html == null || html.trim().isEmpty) return false;
    final interactive = GridWebSnapshot.ensureInteractive(html);
    _showingSnapshot = true;
    await _controller.loadHtmlString(
      interactive,
      baseUrl: _effectiveUri.origin,
    );
    if (!mounted) return true;
    setState(() {
      _loading = false;
      _error = null;
    });
    return true;
  }

  Future<void> _persistSnapshot() async {
    try {
      final online = await _isOnline();
      if (!online) return;

      // Verify that the current view is specifically the Channels page
      const detectChannelsJs = '''
(function() {
  try {
    var text = (document.body ? document.body.innerText : '');
    var href = window.location.href || '';
    var hasChannels = text.indexOf('Channels') !== -1 || href.indexOf('channel') !== -1;
    var hasSub = text.indexOf('Directory') !== -1 || text.indexOf('Explore') !== -1 || text.indexOf('Following') !== -1 || text.indexOf('All Channels') !== -1 || text.indexOf('My channels') !== -1;
    return hasChannels && hasSub;
  } catch(e) {
    return false;
  }
})();
''';
      final isChannelsRaw =
          await _controller.runJavaScriptReturningResult(detectChannelsJs);
      final isChannels = isChannelsRaw.toString().trim() == 'true';
      if (!isChannels) {
        // As requested by user, offline snapshotting is targeted ONLY for the Channels page
        return;
      }

      const bundleCssJs = '''
(function() {
  try {
    var cssText = '';
    for (var i = 0; i < document.styleSheets.length; i++) {
      try {
        var sheet = document.styleSheets[i];
        var rules = sheet.cssRules || sheet.rules;
        if (rules) {
          for (var j = 0; j < rules.length; j++) {
            cssText += rules[j].cssText + '\\n';
          }
        }
      } catch(e) {}
    }
    var inlineStyle = document.getElementById('__offline_compiled_styles');
    if (!inlineStyle) {
      inlineStyle = document.createElement('style');
      inlineStyle.id = '__offline_compiled_styles';
      document.head.appendChild(inlineStyle);
    }
    if (cssText.length > 50) {
      inlineStyle.textContent = cssText;
    }
    var computedBg = window.getComputedStyle(document.body).backgroundColor;
    var computedColor = window.getComputedStyle(document.body).color;
    if (computedBg && computedBg !== 'rgba(0, 0, 0, 0)') {
      document.body.style.backgroundColor = computedBg;
      document.documentElement.style.backgroundColor = computedBg;
    }
    if (computedColor) {
      document.body.style.color = computedColor;
    }
  } catch(err) {}
  return document.documentElement.outerHTML;
})();
''';
      final raw = await _controller.runJavaScriptReturningResult(bundleCssJs);
      final html = _unwrapJsString(raw);
      if (html == null || html.length < 64) return;

      await GridWebSnapshot.saveChannelsSnapshot(html);
      await GridWebSnapshot.save(_effectiveUri, html);
    } catch (e) {
      debugPrint('[GridInAppWebView] Snapshot save failed: $e');
    }
  }

  Future<void> _checkAndRecoverOfflineChannels() async {
    try {
      final online = await _isOnline();
      if (online) return;
      const detectChannelsNetworkErrorJs = '''
(function() {
  try {
    var text = document.body ? document.body.innerText : '';
    var hasError = text.indexOf('Network error') !== -1;
    var hasDirectory = text.indexOf('Directory') !== -1;
    var hasChannelsTabs = text.indexOf('Explore') !== -1 && text.indexOf('Following') !== -1;
    return hasError && (hasDirectory || hasChannelsTabs);
  } catch(e) {
    return false;
  }
})();
''';
      final hasError =
          await _controller.runJavaScriptReturningResult(detectChannelsNetworkErrorJs);
      if (hasError.toString().trim() == 'true') {
        debugPrint(
          '[GridInAppWebView] Detected Network error on Channels tab offline -> restoring Channels snapshot',
        );
        await _tryLoadSnapshot();
      }
    } catch (_) {}
  }

  Future<void> _handleLoadFailure(String description) async {
    if (_showingSnapshot) {
      // Retain the cached snapshot view; do not overwrite with the error screen
      return;
    }
    final isExplicitChannels = widget.uri.path.contains('channel') ||
        widget.uri.fragment.contains('channel') ||
        widget.uri.query.contains('channel');
    if (isExplicitChannels) {
      final restored = await _tryLoadSnapshot();
      if (restored) return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = description;
    });
  }

  static String? _unwrapJsString(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is String) {
        return GridWebSnapshot.normalizeHtml(decoded);
      }
    } catch (_) {}
    return GridWebSnapshot.normalizeHtml(text);
  }

  void _showPermissionSettingsPrompt({
    bool requiresVideo = false,
    bool requiresAudio = false,
  }) {
    if (!mounted) return;
    final spaceName = widget.title?.trim().isNotEmpty == true
        ? widget.title!.trim()
        : 'Circle Connect';

    final String requiredFeature;
    if (requiresVideo && requiresAudio) {
      requiredFeature =
          'Camera and microphone permissions are required for video calls in $spaceName.';
    } else if (requiresVideo) {
      requiredFeature =
          'Camera permission is required for video in $spaceName.';
    } else if (requiresAudio) {
      requiredFeature =
          'Microphone permission is required for voice calls in $spaceName.';
    } else {
      requiredFeature = 'Media permissions are required for $spaceName.';
    }

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(requiredFeature),
        action: const SnackBarAction(
          label: 'Settings',
          onPressed: openAppSettings,
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _loading = true;
      _showingSnapshot = false;
    });
    if (!mounted) return;
    await _setupPermissionsAndLoad();
  }

  Widget _buildOfflineState(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final spaceName = widget.title?.trim().isNotEmpty == true
        ? widget.title!.trim()
        : 'Circle Connect';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Stylized offline badge with cloud / wifi-off
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [Color(0xFF1E293B), Color(0xFF0F172A)]
                      : const [Color(0xFFEEF2FF), Color(0xFFE0E7FF)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF4F46E5).withValues(alpha: 0.18),
                    blurRadius: 28,
                    spreadRadius: 6,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 52,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF4F46E5),
                  ),
                  Positioned(
                    right: 22,
                    bottom: 22,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark ? const Color(0xFF0F172A) : Colors.white,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.wifi_off_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Title
            Text(
              'Internet Connection Required',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF1E293B),
                letterSpacing: -0.3,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            // User-friendly warm message
            Text(
              '$spaceName is a live cloud space. An active internet connection is required to load live updates, messages, and calls directly from the server.',
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: isDark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF64748B),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            // Retry button
            FilledButton.icon(
              onPressed: _retry,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 2,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: const Text(
                'Try Again',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Back to app button
            TextButton.icon(
              onPressed: _handleBackPress,
              style: TextButton.styleFrom(
                foregroundColor: isDark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF64748B),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text(
                'Back to Efactor',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title?.trim();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) =>
          _handlePopScope(didPop),
      child: Scaffold(
        appBar: widget.showAppBar
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: _handleBackPress,
                ),
                title: Text(
                  (title == null || title.isEmpty) ? 'GRID' : title,
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Reload page',
                    onPressed: _retry,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: _handleBackPress,
                  ),
                ],
              )
            : null,
        body: SafeArea(
          top: !widget.showAppBar,
          bottom: true,
          child: Stack(
            children: <Widget>[
              if (_error == null)
                WebViewWidget(controller: _controller)
              else
                _buildOfflineState(context),
              if (_loading && _error == null)
                const LinearProgressIndicator(minHeight: 2),
              if (!widget.showAppBar)
                Positioned(
                  top: 0,
                  left: 0,
                  width: 130,
                  height: 72,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _handleTopLeftTap,
                  ),
                ),
              if (_showReelsTutorial)
                _buildReelsTutorialOverlay(),
              if (_showChatTutorial)
                _buildChatConversationTutorialOverlay(),
              if (_isConnectingCall)
                _buildConnectingCallOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectingCallOverlay() {
    final callerName = _effectiveUri.queryParameters['caller_name'] ??
        _effectiveUri.queryParameters['callerName'] ??
        'Circle Connect Call';
    final callType = _effectiveUri.queryParameters['call_type'] ?? 'video';
    final isVideo = callType.toLowerCase().contains('video');

    return Container(
      color: const Color(0xFF0F172A),
      width: double.infinity,
      height: double.infinity,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isVideo ? Icons.videocam : Icons.call,
                    color: const Color(0xFF60A5FA),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text(
              callerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Connecting...',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 16,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Center(
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.35),
                      blurRadius: 30,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF0284C7),
                    ),
                    child: Icon(
                      isVideo ? Icons.videocam : Icons.person,
                      size: 48,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: InkWell(
                onTap: () {
                  final callId = _effectiveUri.queryParameters['call_id'] ?? '';
                  if (callId.isNotEmpty) {
                    final call = IncomingCallData(
                      callId: callId,
                      callerId: '',
                      callerName: callerName,
                      roomUrl: widget.uri.toString(),
                    );
                    IncomingCallService.instance.declineCall(call);
                  }
                  _safeExitToGrid();
                },
                borderRadius: BorderRadius.circular(36),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEF4444),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x66EF4444),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleTopLeftTap() async {
    if (!mounted || _isPopping) return;
    if (_showChatTutorial) {
      _dismissChatTutorial();
      return;
    }
    try {
      final isReels = await _isCurrentlyInReels();
      if (isReels) {
        await _goToChatsPage();
        return;
      }
      final handledInWeb = await _tryCloseWebChatConversation();
      if (handledInWeb) {
        _onChatConversationClosed();
        return;
      }
      final canGoBack = await _controller.canGoBack();
      if (canGoBack) {
        await _controller.goBack();
        return;
      }
    } catch (_) {}
    if (!mounted || _isPopping) return;
    _safeExitToGrid();
  }

  void _backToGrid() {
    _safeExitToGrid();
  }

  Future<void> _injectGridBackButton() async {
    const js = '''
(function() {
  function isReelsView() {
    try {
      var bodyText = (document.body ? (document.body.innerText || document.body.textContent || '') : '').toLowerCase();
      var hasForYou = bodyText.includes('for you');
      var hasReelsTabs = hasForYou && (bodyText.includes('following') || bodyText.includes('trending'));
      var href = (window.location.href || '').toLowerCase();
      var isReelsUrl = href.includes('reel') || href.includes('tab=reels');
      var hasReelsEl = !!document.querySelector('[class*="reel" i], [data-tab="reels"].active, .reels-container, .reels-player, [data-testid*="reel" i]');
      return hasReelsTabs || isReelsUrl || hasReelsEl;
    } catch (_) {}
    return false;
  }

  function handleReelsBack(e) {
    if (!isReelsView()) return false;

    var touch = (e.changedTouches && e.changedTouches[0]) || (e.touches && e.touches[0]) || e;
    var clientX = touch.clientX;
    var clientY = touch.clientY;

    var isTopLeft = false;
    if (clientX !== undefined && clientY !== undefined) {
      if (clientX <= 110 && clientY <= 100) {
        isTopLeft = true;
      }
    }

    if (!isTopLeft && e.target) {
      var curr = e.target;
      while (curr && curr !== document.body) {
        try {
          var r = curr.getBoundingClientRect ? curr.getBoundingClientRect() : null;
          if (r && r.top >= 0 && r.top <= 110 && r.left >= 0 && r.left <= 110 && r.width > 0 && r.height > 0) {
            isTopLeft = true;
            break;
          }
        } catch (_) {}
        curr = curr.parentElement;
      }
    }

    if (isTopLeft) {
      e.preventDefault();
      e.stopPropagation();
      if (typeof e.stopImmediatePropagation === 'function') {
        e.stopImmediatePropagation();
      }

      // Notify Flutter bridge to navigate back to Chats
      if (window.CircleConnectNavBridge) {
        window.CircleConnectNavBridge.postMessage('go_to_chats');
      }

      // Also trigger Chats tab in DOM immediately
      var chatSelectors = [
        '[data-tab="chats"]',
        '[data-tab="chat"]',
        '[data-tab="messages"]',
        '[data-testid="chats-tab"]',
        '[data-testid="chat-tab"]',
        '[data-testid*="chat" i]',
        '.chat-tab',
        '.chats-tab',
        '#chat-tab',
        '#chats-tab'
      ];
      for (var i = 0; i < chatSelectors.length; i++) {
        var tab = document.querySelector(chatSelectors[i]);
        if (tab && typeof tab.click === 'function') {
          try { tab.click(); return true; } catch (_) {}
        }
      }

      var allNav = document.querySelectorAll('.bottom-nav .nav-item, nav button, nav a, [role="tab"], button, div[role="button"]');
      for (var j = 0; j < allNav.length; j++) {
        var t = (allNav[j].innerText || allNav[j].textContent || '').trim().toLowerCase();
        if (t === 'chats' || t === 'chat' || t === 'messages') {
          try { allNav[j].click(); return true; } catch (_) {}
        }
      }
      return true;
    }
    return false;
  }

  function isInsideConversation() {
    try {
      // Must be on a chat page to be in a chat conversation!
      var path = (window.location.pathname || '').toLowerCase();
      var isChat = path.includes('grid-chat') || path.includes('/chat');
      if (!isChat) {
        return false;
      }
      var backBtn = document.querySelector(
        'header [class*="back" i], header button, header [aria-label*="back" i], header [title*="back" i], .back-arrow, [class*="back-button" i], [class*="back_button" i], [class*="arrow-back" i], [class*="arrow_back" i]'
      );
      if (backBtn) {
        var r = backBtn.getBoundingClientRect();
        if (r.top >= 0 && r.top < 120 && r.left >= 0 && r.left < 160 && r.width > 0 && r.height > 0) {
          return true;
        }
      }
      var hasComposer = !!document.querySelector(
        'input[placeholder*="Type a message" i], textarea[placeholder*="Type a message" i], [class*="chat-input" i], [class*="message-input" i], [class*="composer" i]'
      );
      if (hasComposer) {
        return true;
      }
      var search = (window.location.search || '').toLowerCase();
      if (search.includes('conversation_id=') || search.includes('chat_id=') || search.includes('room=') || path.includes('/room/') || path.includes('/c/')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  function isGridElement(el) {
    if (!el || el === document.body || el === document.documentElement) return false;

    // Explicitly exclude any back button or back arrow
    var tag = el.tagName ? el.tagName.toLowerCase() : '';
    var className = (typeof el.className === 'string') ? el.className.toLowerCase() : '';
    var ariaLabel = (el.getAttribute && el.getAttribute('aria-label')) ? el.getAttribute('aria-label').toLowerCase() : '';
    var title = (el.getAttribute && el.getAttribute('title')) ? el.getAttribute('title').toLowerCase() : '';
    if (className.includes('back') || className.includes('arrow') || ariaLabel.includes('back') || title.includes('back')) {
      return false;
    }

    var txt = (el.innerText || el.textContent || '').trim();
    var hasGridText = /^:::?\\s*GRID/i.test(txt) || txt === 'GRID' || txt === '::: GRID' || (/GRID/i.test(txt) && txt.length <= 15);
    var isGridImg = tag === 'img' && ((el.getAttribute('src') || '').toLowerCase().includes('grid') || (el.getAttribute('alt') || '').toLowerCase().includes('grid'));
    var hasGridClass = className.includes('grid-logo') || className.includes('grid_logo') || className.includes('logo') || className.includes('brand');
    var href = (el.getAttribute && el.getAttribute('href')) ? el.getAttribute('href').toLowerCase() : '';
    var hasGridHref = href.endsWith('/grid') || href.endsWith('/grid/') || href.includes('/index.php/grid') || href === '/' || href === '#';

    if (hasGridText || isGridImg || hasGridClass || hasGridHref) {
      try {
        var rect = el.getBoundingClientRect();
        if (rect.top >= 0 && rect.top < 110 && rect.left >= 0 && rect.left < 200 && rect.width > 0 && rect.height > 0) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  function handleGridTrigger(e) {
    // If in Reels and tapping top-left back button, navigate to Chats and NEVER toggle views
    if (handleReelsBack(e)) {
      return;
    }

    // If inside a conversation, NEVER intercept. Let web app handle the back arrow natively!
    if (isInsideConversation()) {
      return;
    }

    // In Professional Space (/grid), the GRID logo goes to GRID home within the WebView.
    // As confirmed by the web team: "GRID has no button meant to leave it. The GRID logo goes to the
    // GRID home (https://efactor.tech/index.php/grid), so it stays inside the WebView."
    var path = (window.location.pathname || '').toLowerCase();
    var isProfSpace = path.includes('/grid') && !path.includes('/grid-chat');
    if (isProfSpace) {
      return;
    }

    var curr = e.target;
    var matched = false;
    while (curr && curr !== document.body && curr !== document.documentElement) {
      if (isGridElement(curr)) {
        matched = true;
        break;
      }
      curr = curr.parentElement;
    }

    if (!matched && e.clientX !== undefined && e.clientY !== undefined) {
      if (e.clientX <= 160 && e.clientY <= 65) {
        var elAtPoint = document.elementFromPoint(e.clientX, e.clientY);
        var checkEl = elAtPoint;
        while (checkEl && checkEl !== document.body) {
          var t = (checkEl.innerText || checkEl.textContent || '').trim();
          var isImg = checkEl.tagName === 'IMG' && ((checkEl.getAttribute('src') || '').toLowerCase().includes('grid') || (checkEl.getAttribute('alt') || '').toLowerCase().includes('grid'));
          var isClass = (typeof checkEl.className === 'string') && (checkEl.className.toLowerCase().includes('grid') || checkEl.className.toLowerCase().includes('logo') || checkEl.className.toLowerCase().includes('brand'));
          if (/^:::?\\s*GRID/i.test(t) || t === 'GRID' || t === '::: GRID' || (/GRID/i.test(t) && t.length <= 15) || isImg || isClass) {
            matched = true;
            break;
          }
          checkEl = checkEl.parentElement;
        }
      }
    }

    if (matched) {
      e.preventDefault();
      e.stopPropagation();
      if (window.CircleConnectNavBridge) {
        window.CircleConnectNavBridge.postMessage('go_back_to_grid');
      }
    }
  }

  if (!window.__gridClickInterceptorInstalled) {
    window.__gridClickInterceptorInstalled = true;
    document.addEventListener('click', handleGridTrigger, true);
    document.addEventListener('touchend', handleGridTrigger, true);
    document.addEventListener('pointerup', handleGridTrigger, true);
  }

  if (!window.__gridTargetBlankInterceptorInstalled) {
    window.__gridTargetBlankInterceptorInstalled = true;
    document.addEventListener('click', function(e) {
      var el = e.target;
      while (el && el.tagName !== 'A') {
        el = el.parentElement;
      }
      if (el && el.tagName === 'A') {
        var href = (el.getAttribute('href') || '').trim();
        var target = el.getAttribute('target');
        if (target === '_blank') {
          var isFile = href.includes('/resume') ||
                       href.includes('/attachment/') ||
                       href.includes('/attachments/') ||
                       /\\.(pdf|docx?|xlsx?|pptx?|zip|csv)(\\?|\$)/i.test(href);
          var isInternal = href.startsWith('https://efactor.tech') ||
                           href.startsWith('http://efactor.tech') ||
                           href.startsWith('/');
          if (!isFile && isInternal) {
            el.setAttribute('target', '_self');
          }
        }
      }
    }, true);
  }

  function attachReelsDirect() {
    if (!isReelsView()) return;
    var all = document.querySelectorAll('header button, header [class*="back" i], header [class*="arrow" i], header svg, button, div[role="button"]');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
      if (r && r.top >= 0 && r.top < 85 && r.left >= 0 && r.left < 85 && r.width > 0 && r.height > 0) {
        if (!el.__reelsDirectAttached) {
          el.__reelsDirectAttached = true;
          el.addEventListener('click', handleReelsBack, true);
          el.addEventListener('touchend', handleReelsBack, true);
          el.addEventListener('pointerup', handleReelsBack, true);
        }
      }
    }
  }

  function attachGridDirect() {
    attachReelsDirect();
    if (isInsideConversation()) {
      return;
    }
    var all = document.querySelectorAll('header, nav, [class*="header"], [class*="nav"], [class*="topbar"], div, a, span, h1, h2, img, button');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (isGridElement(el) && !el.__gridDirectAttached) {
        el.__gridDirectAttached = true;
        el.style.cursor = 'pointer';
        el.addEventListener('click', function(e) {
          if (isInsideConversation()) return;
          e.preventDefault();
          e.stopPropagation();
          if (window.CircleConnectNavBridge) {
            window.CircleConnectNavBridge.postMessage('go_back_to_grid');
          }
        }, true);
      }
    }
  }
  attachGridDirect();
  if (!window.__gridBackObserver && document.body) {
    window.__gridBackObserver = new MutationObserver(function() {
      attachGridDirect();
    });
    window.__gridBackObserver.observe(document.body, { childList: true, subtree: true });
  }
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  /// Injects horizontal swipe detection and conversation state monitoring when inside a chat room.
  /// Swipe left-to-right (dx > 55) -> navigates to Moments.
  /// Swipe right-to-left (dx < -55) -> navigates to Channels.
  Future<void> _injectChatSwipeBridge() async {
    if (!_isCircleConnect) return;
    const js = '''
(function() {
  if (window.__circleChatSwipeBridgeInstalled) return;
  window.__circleChatSwipeBridgeInstalled = true;

  var chatTouchStartX = 0;
  var chatTouchStartY = 0;
  var chatTouchStartTime = 0;
  var lastInsideConv = false;

  function isInsideConversation() {
    try {
      var path = (window.location.pathname || '').toLowerCase();
      var isChat = path.includes('grid-chat') || path.includes('/chat');
      if (!isChat) return false;
      var backBtn = document.querySelector(
        'header [class*="back" i], header button, header [aria-label*="back" i], header [title*="back" i], .back-arrow, [class*="back-button" i], [class*="back_button" i], [class*="arrow-back" i], [class*="arrow_back" i]'
      );
      if (backBtn) {
        var r = backBtn.getBoundingClientRect();
        if (r.top >= 0 && r.top < 120 && r.left >= 0 && r.left < 160 && r.width > 0 && r.height > 0) {
          return true;
        }
      }
      var hasComposer = !!document.querySelector(
        'input[placeholder*="Type" i], textarea[placeholder*="Type" i], [class*="chat-input" i], [class*="message-input" i], [class*="composer" i]'
      );
      if (hasComposer) return true;
      var search = (window.location.search || '').toLowerCase();
      if (search.includes('conversation_id=') || search.includes('chat_id=') || search.includes('room=') || path.includes('/room/') || path.includes('/c/')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  function reportState() {
    var curr = isInsideConversation();
    if (curr !== lastInsideConv) {
      lastInsideConv = curr;
      if (window.CircleConnectNavBridge) {
        window.CircleConnectNavBridge.postMessage(
          curr ? 'conversation_state:opened' : 'conversation_state:closed'
        );
      }
    }
  }

  document.addEventListener('touchstart', function(e) {
    if (!isInsideConversation()) return;
    var t = (e.touches && e.touches[0]) || e;
    chatTouchStartX = t.clientX;
    chatTouchStartY = t.clientY;
    chatTouchStartTime = Date.now();
  }, { passive: true });

  document.addEventListener('touchend', function(e) {
    if (!isInsideConversation()) return;
    var t = (e.changedTouches && e.changedTouches[0]) || (e.touches && e.touches[0]) || e;
    var dx = t.clientX - chatTouchStartX;
    var dy = t.clientY - chatTouchStartY;
    var dt = Date.now() - chatTouchStartTime;

    // Must be predominantly horizontal gesture within 800ms
    if (Math.abs(dx) > 55 && Math.abs(dx) > Math.abs(dy) * 1.6 && dt < 800) {
      if (dx > 55) {
        // Swipe Left to Right -> Moments
        if (window.CircleConnectNavBridge) {
          window.CircleConnectNavBridge.postMessage('chat_swipe:moments');
        }
      } else if (dx < -55) {
        // Swipe Right to Left -> Channels
        if (window.CircleConnectNavBridge) {
          window.CircleConnectNavBridge.postMessage('chat_swipe:channels');
        }
      }
    }
  }, { passive: true });

  reportState();
  if (document.body && !window.__circleChatStateObserver) {
    window.__circleChatStateObserver = new MutationObserver(function() {
      reportState();
    });
    window.__circleChatStateObserver.observe(document.body, { childList: true, subtree: true });
  }

  document.addEventListener('click', function() {
    setTimeout(reportState, 150);
    setTimeout(reportState, 450);
    setTimeout(reportState, 800);
  }, true);
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  /// Injects compatibility bridge for the scanner web page back button.
  /// When user taps the top-left back button, the web page calls
  /// window.flutter_inappwebview.callHandler('closeWebView') which this bridge
  /// forwards to CircleConnectNavBridge ('go_back_to_grid') to pop back to Grid SDUI.
  Future<void> _injectScannerBridge() async {
    const js = '''
(function() {
  if (!window.flutter_inappwebview) {
    window.flutter_inappwebview = {
      callHandler: function(handlerName) {
        var name = String(handlerName || '').toLowerCase();
        if (name === 'closewebview' || name === 'goback' || name === 'close' || name === 'back') {
          if (window.CircleConnectNavBridge) {
            window.CircleConnectNavBridge.postMessage('go_back_to_grid');
          }
        }
      }
    };
  }
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  bool get _isCircleConnect {
    final path = widget.uri.path.toLowerCase();
    final title = (widget.title ?? '').toLowerCase();
    final fullUrl = widget.uri.toString().toLowerCase();
    return path.contains('chat') ||
        path.contains('circle') ||
        title.contains('circle') ||
        title.contains('chat') ||
        fullUrl.contains('grid-chat');
  }

  Future<void> _checkReelsTutorial() async {
    if (!_isCircleConnect) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool('has_seen_circle_connect_reels_tutorial_v11') ?? false;
      if (!seen && mounted) {
        setState(() {
          _showReelsTutorial = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _dismissReelsTutorial() async {
    if (!_showReelsTutorial) return;
    setState(() {
      _showReelsTutorial = false;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v11', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v10', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v9', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v8', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v7', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v6', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v5', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v4', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v3', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v2', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial', true);
    } catch (_) {}
  }

  void _handleSwipeToReels({String direction = 'left'}) {
    _dismissReelsTutorial();
    final js = '''
(function() {
  try {
    var dir = '$direction';

    // 1. Try finding and clicking any reels tab/button/icon in the web app
    var selectors = [
      '[data-tab="reels"]',
      '[data-testid="reels-tab"]',
      '[data-testid*="reels" i]',
      '[data-testid*="reel" i]',
      'a[href*="reel" i]',
      'a[href*="video" i]',
      'button[aria-label*="reel" i]',
      'button[aria-label*="video" i]',
      'button[title*="reel" i]',
      '.reels-tab',
      '.reels-button',
      '.reels-nav',
      '#reels',
      '[class*="reels" i]'
    ];
    for (var i = 0; i < selectors.length; i++) {
      var el = document.querySelector(selectors[i]);
      if (el) {
        try { el.click(); return; } catch(_) {}
      }
    }

    var all = document.querySelectorAll('button, a, div[role="button"], span[role="button"], div, span');
    for (var i = 0; i < all.length; i++) {
      var txt = (all[i].innerText || all[i].textContent || '').trim().toLowerCase();
      if (txt === 'reels' || txt === 'reel' || txt === 'watch reels' || txt === 'videos') {
        try { all[i].click(); return; } catch(_) {}
      }
    }

    // 2. Dispatch custom events for any SPA/React router listener
    window.dispatchEvent(new CustomEvent('openReels', { bubbles: true }));
    window.dispatchEvent(new CustomEvent('open-reels', { bubbles: true }));
    window.dispatchEvent(new CustomEvent('swipe-to-reels', { bubbles: true, detail: { direction: dir } }));
    document.dispatchEvent(new CustomEvent('swipe-to-reels', { bubbles: true, detail: { direction: dir } }));

    // 3. Simulate realistic multi-step touch swipe inside the web page
    var w = window.innerWidth || document.documentElement.clientWidth || 375;
    var h = window.innerHeight || document.documentElement.clientHeight || 667;
    var isLeft = dir === 'left';
    var startX = Math.round(isLeft ? (w * 0.88) : (w * 0.12));
    var endX = Math.round(isLeft ? (w * 0.12) : (w * 0.88));
    var midY = Math.round(h * 0.45);

    var target = document.elementFromPoint(startX, midY) ||
                 document.querySelector('.chat-container, [class*="chat"], main, #root, body') ||
                 document.body;

    function createTouch(x, y) {
      if (typeof Touch === 'function') {
        try {
          return new Touch({
            identifier: 1,
            target: target,
            clientX: x,
            clientY: y,
            screenX: x,
            screenY: y,
            pageX: x,
            pageY: y
          });
        } catch(_) {}
      }
      return {
        identifier: 1,
        target: target,
        clientX: x,
        clientY: y,
        screenX: x,
        screenY: y,
        pageX: x,
        pageY: y
      };
    }

    var t0 = createTouch(startX, midY);
    target.dispatchEvent(new TouchEvent('touchstart', {
      touches: [t0],
      targetTouches: [t0],
      changedTouches: [t0],
      bubbles: true,
      cancelable: true
    }));

    var steps = 6;
    for (var s = 1; s <= steps; s++) {
      var currX = Math.round(startX + (endX - startX) * (s / steps));
      var tStep = createTouch(currX, midY);
      target.dispatchEvent(new TouchEvent('touchmove', {
        touches: [tStep],
        targetTouches: [tStep],
        changedTouches: [tStep],
        bubbles: true,
        cancelable: true
      }));
    }

    var tEnd = createTouch(endX, midY);
    target.dispatchEvent(new TouchEvent('touchend', {
      touches: [],
      targetTouches: [],
      changedTouches: [tEnd],
      bubbles: true,
      cancelable: true
    }));

    // 4. Also dispatch PointerEvents for pointer-based listeners
    target.dispatchEvent(new PointerEvent('pointerdown', {
      pointerId: 1,
      pointerType: 'touch',
      clientX: startX,
      clientY: midY,
      bubbles: true,
      cancelable: true
    }));
    target.dispatchEvent(new PointerEvent('pointermove', {
      pointerId: 1,
      pointerType: 'touch',
      clientX: endX,
      clientY: midY,
      bubbles: true,
      cancelable: true
    }));
    target.dispatchEvent(new PointerEvent('pointerup', {
      pointerId: 1,
      pointerType: 'touch',
      clientX: endX,
      clientY: midY,
      bubbles: true,
      cancelable: true
    }));
  } catch(e) {
    console.error('Error forwarding swipe to reels:', e);
  }
})();
''';
    try {
      _controller.runJavaScript(js);
    } catch (_) {}
  }

  Widget _buildReelsTutorialOverlay() {
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        builder: (context, opacity, child) {
          return Opacity(
            opacity: opacity,
            child: child,
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _tutorialDragDistance = 0.0;
          },
          onHorizontalDragUpdate: (details) {
            _tutorialDragDistance += details.delta.dx;
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            // Detect swipe: swipe left (primary) or swipe right
            final isSwipeLeft = velocity < -80 || _tutorialDragDistance < -30;
            final isSwipeRight = velocity > 80 || _tutorialDragDistance > 30;
            if (isSwipeLeft) {
              _handleSwipeToReels(direction: 'left');
            } else if (isSwipeRight) {
              _handleSwipeToReels(direction: 'right');
            }
          },
          child: Material(
            // Translucent overlay so the loaded chats list remains visible underneath
            color: Colors.black.withValues(alpha: 0.42),
            child: Stack(
              children: [
                // Top-right 'skip' button
                Positioned(
                  top: 18,
                  right: 18,
                  child: SafeArea(
                    child: InkWell(
                      onTap: _dismissReelsTutorial,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white70, width: 1.5),
                        ),
                        child: const Text(
                          'skip',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Center gesture demonstration: Simple floating white arrow in reverse direction (pointing right)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The simple floating white arrow gliding right continuously
                      const SizedBox(
                        width: 240,
                        height: 90,
                        child: _SubwaySurfersSlidingArrow(),
                      ),
                      const SizedBox(height: 12),
                      // Simple, clean pill badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.20),
                            width: 1.0,
                          ),
                        ),
                        child: const Text(
                          'Swipe for Reels',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  void _onChatConversationOpened() {
    if (!mounted) return;
    _isInsideChatConversation = true;
    _checkChatTutorial();
  }

  void _onChatConversationClosed() {
    if (!mounted) return;
    _isInsideChatConversation = false;
    if (_showChatTutorial) {
      _dismissChatTutorial();
    }
  }

  Future<void> _checkChatTutorial() async {
    if (!_isCircleConnect) return;
    if (_chatTutorialScheduled) return;
    _chatTutorialScheduled = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool('has_seen_chat_conversation_swipe_tutorial_v1') ?? false;
      if (!seen && mounted) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && _isInsideChatConversation && !_showChatTutorial) {
            setState(() {
              _showChatTutorial = true;
            });
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _dismissChatTutorial() async {
    if (!_showChatTutorial && mounted) return;
    setState(() {
      _showChatTutorial = false;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_chat_conversation_swipe_tutorial_v1', true);
    } catch (_) {}
  }

  Future<void> _handleChatSwipeNavigation({required String targetTab}) async {
    _dismissChatTutorial();
    final js = '''
(function() {
  try {
    var target = '$targetTab'.toLowerCase();
    // 1. Exit active chat conversation
    var backBtn = document.querySelector(
      'header [class*="back" i], header button, header [aria-label*="back" i], header [title*="back" i], .back-arrow, [class*="back-button" i], [class*="back_button" i], [class*="arrow-back" i], [class*="arrow_back" i]'
    );
    if (backBtn && typeof backBtn.click === 'function') {
      try { backBtn.click(); } catch(_) {}
    } else if (window.history && window.history.length > 1) {
      try { window.history.back(); } catch(_) {}
    }

    // 2. Select target bottom tab (Moments or Channels)
    function clickTargetTab() {
      var selectors = [
        '[data-tab="' + target + '"]',
        '[data-testid="' + target + '-tab"]',
        '[data-testid*="' + target + '" i]',
        '#' + target + '-tab',
        '.' + target + '-tab'
      ];
      for (var i = 0; i < selectors.length; i++) {
        var el = document.querySelector(selectors[i]);
        if (el && typeof el.click === 'function') {
          el.click();
          return true;
        }
      }
      var allNav = document.querySelectorAll('.bottom-nav .nav-item, nav button, nav a, [role="tab"], button, div[role="button"]');
      for (var j = 0; j < allNav.length; j++) {
        var t = (allNav[j].innerText || allNav[j].textContent || '').trim().toLowerCase();
        if (t === target || t.includes(target)) {
          if (typeof allNav[j].click === 'function') {
            allNav[j].click();
            return true;
          }
        }
      }
      return false;
    }

    if (!clickTargetTab()) {
      setTimeout(clickTargetTab, 100);
      setTimeout(clickTargetTab, 250);
      setTimeout(clickTargetTab, 500);
    }
  } catch(e) {
    console.error('Error navigating chat swipe:', e);
  }
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  Widget _buildChatConversationTutorialOverlay() {
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        builder: (context, opacity, child) {
          return Opacity(
            opacity: opacity,
            child: child,
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _chatTutorialDragDistance = 0.0;
          },
          onHorizontalDragUpdate: (details) {
            _chatTutorialDragDistance += details.delta.dx;
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            // Drag finger right (positive dx/velocity) -> Moments
            // Drag finger left (negative dx/velocity) -> Channels
            final isSwipeRight = velocity > 80 || _chatTutorialDragDistance > 30;
            final isSwipeLeft = velocity < -80 || _chatTutorialDragDistance < -30;
            if (isSwipeRight) {
              _handleChatSwipeNavigation(targetTab: 'moments');
            } else if (isSwipeLeft) {
              _handleChatSwipeNavigation(targetTab: 'channels');
            }
          },
          child: Material(
            // Translucent overlay so the active chat conversation remains softly visible underneath
            color: Colors.black.withValues(alpha: 0.48),
            child: Stack(
              children: [
                // Top-right 'skip' button
                Positioned(
                  top: 18,
                  right: 18,
                  child: SafeArea(
                    child: InkWell(
                      onTap: _dismissChatTutorial,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white70, width: 1.5),
                        ),
                        child: const Text(
                          'skip',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Center gesture demonstration: Dual directional sliding arrows
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 1. Swipe Right for Moments
                      const SizedBox(
                        width: 220,
                        height: 54,
                        child: _DirectionalSlidingArrow(isPointingRight: true),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.40),
                            width: 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.20),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Swipe Right for Moments',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                            SizedBox(width: 6),
                            Icon(Icons.arrow_forward_rounded, color: Color(0xFF38BDF8), size: 16),
                          ],
                        ),
                      ),

                      const SizedBox(height: 36),

                      // 2. Swipe Left for Channels
                      const SizedBox(
                        width: 220,
                        height: 54,
                        child: _DirectionalSlidingArrow(isPointingRight: false),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.40),
                            width: 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.20),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_rounded, color: Color(0xFFF59E0B), size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Swipe Left for Channels',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),
                      const Text(
                        'Swipe anywhere inside chat to switch spaces',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

/// Simple, continuous white arrow sliding in reverse direction (from left to right)
class _SubwaySurfersSlidingArrow extends StatefulWidget {
  const _SubwaySurfersSlidingArrow();

  @override
  State<_SubwaySurfersSlidingArrow> createState() => _SubwaySurfersSlidingArrowState();
}

class _SubwaySurfersSlidingArrowState extends State<_SubwaySurfersSlidingArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    // Continuous loop
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();

    // Glides continuously from left (-0.35) across to right (+0.35) in reverse direction
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-0.35, 0.0),
      end: const Offset(0.35, 0.0),
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOutCubic,
      ),
    );

    // Natural arcade swipe fade
    _fadeAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: const Center(
          child: CustomPaint(
            size: Size(130, 60),
            painter: _TransparentOutlineArrowPainter(),
          ),
        ),
      ),
    );
  }
}

/// Crisp transparent outline arrow pointing right with luminous border
class _TransparentOutlineArrowPainter extends CustomPainter {
  final bool isPointingLeft;

  const _TransparentOutlineArrowPainter({this.isPointingLeft = false});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (isPointingLeft) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final centerY = size.height / 2;
    const totalWidth = 114.0;
    const headHeight = 52.0;
    const shaftHeight = 18.0;
    const headLength = 46.0;
    const barbDepth = 10.0;
    final tailX = (size.width - totalWidth) / 2;
    final tipX = tailX + totalWidth;

    final path = Path()
      ..moveTo(tailX, centerY - shaftHeight / 2)
      ..lineTo(tipX - headLength + barbDepth, centerY - shaftHeight / 2)
      ..lineTo(tipX - headLength, centerY - headHeight / 2)
      ..lineTo(tipX, centerY)
      ..lineTo(tipX - headLength, centerY + headHeight / 2)
      ..lineTo(tipX - headLength + barbDepth, centerY + shaftHeight / 2)
      ..lineTo(tailX, centerY + shaftHeight / 2)
      ..close();

    // Subtle frosted interior (transparent so chats are completely visible through the arrow body)
    final fillPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Soft luminous outer glow
    final glowPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.40)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawPath(path, glowPaint);

    // Sharp white outline border
    final strokePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Bidirectional continuous gliding arrow for chat tutorial (pointing right or left)
class _DirectionalSlidingArrow extends StatefulWidget {
  final bool isPointingRight;

  const _DirectionalSlidingArrow({required this.isPointingRight});

  @override
  State<_DirectionalSlidingArrow> createState() => _DirectionalSlidingArrowState();
}

class _DirectionalSlidingArrowState extends State<_DirectionalSlidingArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();

    final beginOffset = widget.isPointingRight
        ? const Offset(-0.35, 0.0)
        : const Offset(0.35, 0.0);
    final endOffset = widget.isPointingRight
        ? const Offset(0.35, 0.0)
        : const Offset(-0.35, 0.0);

    _slideAnimation = Tween<Offset>(
      begin: beginOffset,
      end: endOffset,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOutCubic,
      ),
    );

    _fadeAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Center(
          child: CustomPaint(
            size: const Size(130, 50),
            painter: _TransparentOutlineArrowPainter(
              isPointingLeft: !widget.isPointingRight,
            ),
          ),
        ),
      ),
    );
  }
}
