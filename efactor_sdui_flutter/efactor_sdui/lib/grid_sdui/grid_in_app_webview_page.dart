import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../services/incoming_call_service.dart';
import '../services/push_notification_bootstrap.dart';
import 'grid_media_cache_service.dart';
import 'grid_offline_outbox_service.dart';
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
    final initialRedirect = initialUri.queryParameters['redirect_url'];
    if (initialRedirect != null && initialRedirect.isNotEmpty) {
      updated['redirect_url'] = initialRedirect;
    } else if (includeRedirectUrl && initialUri.path.isNotEmpty) {
      updated['redirect_url'] = initialUri.path;
    }
    return uri.replace(queryParameters: updated);
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

  /// Currently visible/active WebView instance for Circle Connect & Professional Space.
  static _GridInAppWebViewPageState? _activeState;

  /// Returns true if GRID Chat / Circle Connect / Professional Space is currently open in the foreground.
  static bool get isPageOpen =>
      _activeState != null && (_activeState?.mounted ?? false);

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

  /// Dispatches open chat event to active web page via both:
  /// 1. CustomEvent 'circleConnectOpenChat' with { conversationId }
  /// 2. window.gridChatOpenChat({ conversation_id })
  static Future<void> openChat({required String conversationId}) async {
    if (!isPageOpen) return;
    final js = '''
(function() {
  try {
    window.dispatchEvent(new CustomEvent('circleConnectOpenChat', {
      detail: {
        conversationId: '$conversationId',
        conversation_id: '$conversationId'
      }
    }));
  } catch(e) {}
  if (typeof window.gridChatOpenChat === 'function') {
    try {
      window.gridChatOpenChat(${jsonEncode({'conversation_id': conversationId})});
    } catch(e) {}
  }
})();
''';
    try {
      await _activeState?._controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[GridInAppWebView] openChat JS failed: $e');
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

class _GridInAppWebViewPageState extends State<GridInAppWebViewPage> {
  late final WebViewController _controller;
  var _loading = true;
  var _showingSnapshot = false;
  String? _error;
  Completer<void>? _navigationCompleter;
  StreamSubscription<OfflineOutboxAction>? _outboxSyncedSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _showReelsTutorial = false;
  double _tutorialDragDistance = 0.0;

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
      final upperAction = callAction.toUpperCase();
      final lowerAction = callAction.toLowerCase();
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
    GridInAppWebViewPage._activeState = this;
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
    _checkReelsTutorial();
  }

  @override
  void dispose() {
    _outboxSyncedSub?.cancel();
    _connectivitySub?.cancel();
    if (!_showingSnapshot && _error == null) {
      unawaited(_persistSnapshot());
    }
    if (GridInAppWebViewPage._activeState == this) {
      GridInAppWebViewPage._activeState = null;
    }
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
          if (msg.message == 'go_back_to_grid') {
            _backToGrid();
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
            final initialIsChat = initialPath.contains('/grid-chat') || initialPath.contains('chat');
            final initialIsGrid = !initialIsChat && initialPath.contains('/grid');

            // If user opened Professional Space (/grid), do not allow server to redirect to Circle Connect (/grid-chat)
            if (initialIsGrid && targetPath.contains('/grid-chat')) {
              debugPrint(
                '[GridInAppWebView] Intercepting unwanted redirect to chat -> keeping Professional Space: ${widget.uri}',
              );
              unawaited(_controller.loadRequest(_effectiveUri));
              return NavigationDecision.prevent;
            }

            // If user opened Circle Connect (/grid-chat), do not allow server to redirect to base Grid (/grid)
            if (initialIsChat && (targetPath.endsWith('/grid') || targetPath.endsWith('/grid/'))) {
              debugPrint(
                '[GridInAppWebView] Intercepting unwanted redirect to grid -> keeping Circle Connect: ${widget.uri}',
              );
              unawaited(_controller.loadRequest(_effectiveUri));
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
            setState(() {
              _loading = true;
              _error = null;
            });
            unawaited(_injectCircleConnectPushBridge());
            unawaited(_injectGridBackButton());
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = null;
            });
            _completeNavigation();
            unawaited(_injectCircleConnectPushBridge());
            unawaited(_injectGridBackButton());
            _dispatchPendingCallActionIfPresent();
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted) unawaited(_injectGridBackButton());
            });
            if (!_showingSnapshot) {
              unawaited(_persistSnapshot());
              // Schedule delayed snapshot capture after dynamic React/SPA rendering completes
              Future.delayed(const Duration(milliseconds: 2500), () {
                if (mounted && !_showingSnapshot && _error == null) {
                  unawaited(_persistSnapshot());
                  unawaited(_injectGridBackButton());
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
  window.CircleConnectPush.startRinging = function(callId, callerName, callType) {
    try {
      if (window.CircleConnectPushBridge) {
        window.CircleConnectPushBridge.postMessage(JSON.stringify({
          action: 'startRinging',
          callId: String(callId || ''),
          callerName: String(callerName || ''),
          callType: String(callType || 'audio')
        }));
      }
    } catch (e) {
      console.error('startRinging error:', e);
    }
  };
  window.CircleConnectPush.stopRinging = function(callId) {
    try {
      if (window.CircleConnectPushBridge) {
        window.CircleConnectPushBridge.postMessage(JSON.stringify({
          action: 'stopRinging',
          callId: String(callId || '')
        }));
      }
    } catch (e) {
      console.error('stopRinging error:', e);
    }
  };
  window.CircleConnectPush.clearChatNotifications = function(conversationId) {
    try {
      if (window.CircleConnectPushBridge) {
        window.CircleConnectPushBridge.postMessage(JSON.stringify({
          action: 'clearChatNotifications',
          conversationId: String(conversationId || '')
        }));
      }
    } catch (e) {
      console.error('clearChatNotifications error:', e);
    }
  };

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
      } else if (action == 'stopRinging') {
        final callId = data['callId']?.toString() ?? '';
        IncomingCallService.instance.stopRingingFromWeb(callId);
      } else if (action == 'clearChatNotifications') {
        final conversationId = data['conversationId']?.toString() ?? '';
        PushNotificationBootstrap.instance.clearChatNotifications(conversationId);
      }
    } catch (e) {
      debugPrint('[GridInAppWebView] Failed parsing CircleConnectPushBridge msg: $e');
    }
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

  Future<void> _handleBackPress() async {
    final canGoBack = await _controller.canGoBack();
    if (canGoBack) {
      await _controller.goBack();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _handlePopScope(bool didPop) async {
    if (didPop) return;
    final canGoBack = await _controller.canGoBack();
    if (canGoBack) {
      await _controller.goBack();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
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
                  width: 120,
                  height: 52,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _backToGrid,
                  ),
                ),
              if (_showReelsTutorial)
                _buildReelsTutorialOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  void _backToGrid() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _injectGridBackButton() async {
    const js = '''
(function() {
  function attachGridBack() {
    var all = document.querySelectorAll('header, nav, [class*="header"], [class*="nav"], [class*="topbar"], div, a, span, h1, h2');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var txt = (el.innerText || el.textContent || '').trim();
      if (txt === 'GRID' || txt === '::: GRID' || txt.indexOf('GRID') === 0) {
        var rect = el.getBoundingClientRect();
        if (rect.top >= 0 && rect.top < 80 && rect.left >= 0 && rect.left < 140) {
          el.style.cursor = 'pointer';
          el.style.display = 'inline-flex';
          el.style.alignItems = 'center';
          el.style.gap = '6px';
          if (!el.querySelector('.grid-back-arrow')) {
            var arrow = document.createElement('span');
            arrow.className = 'grid-back-arrow';
            arrow.innerHTML = '&#8592;';
            arrow.style.fontSize = '20px';
            arrow.style.fontWeight = '700';
            arrow.style.color = 'currentColor';
            arrow.style.marginRight = '4px';
            arrow.style.display = 'inline-block';
            arrow.style.verticalAlign = 'middle';
            el.insertBefore(arrow, el.firstChild);
          }
          el.onclick = function(e) {
            e.preventDefault();
            e.stopPropagation();
            if (window.CircleConnectNavBridge) {
              window.CircleConnectNavBridge.postMessage('go_back_to_grid');
            }
          };
          break;
        }
      }
    }
  }
  attachGridBack();
  if (!window.__gridBackObserver && document.body) {
    window.__gridBackObserver = new MutationObserver(function() {
      attachGridBack();
    });
    window.__gridBackObserver.observe(document.body, { childList: true, subtree: true });
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
      final seen = prefs.getBool('has_seen_circle_connect_reels_tutorial_v6') ?? false;
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
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v6', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v5', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v4', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v3', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial_v2', true);
      await prefs.setBool('has_seen_circle_connect_reels_tutorial', true);
    } catch (_) {}
  }

  void _handleSwipeToReels() {
    _dismissReelsTutorial();
    try {
      _controller.runJavaScript('''
        (function() {
          var evt = new CustomEvent('swipe-to-reels', { bubbles: true });
          window.dispatchEvent(evt);
          document.dispatchEvent(evt);
        })();
      ''');
    } catch (_) {}
  }

  Widget _buildReelsTutorialOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _tutorialDragDistance = 0.0;
        },
        onHorizontalDragUpdate: (details) {
          _tutorialDragDistance += details.delta.dx;
        },
        onHorizontalDragEnd: (details) {
          // Detect swipe from left to right (either by velocity or drag displacement)
          if ((details.primaryVelocity ?? 0) > 100 || _tutorialDragDistance > 50) {
            _handleSwipeToReels();
          }
        },
        child: Material(
          color: Colors.black.withValues(alpha: 0.82),
          child: Stack(
            children: [
              // Top-right 'skip' button (PLAYit style)
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

              // Center gesture demonstration
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Glowing circular badge with animated swipe-right hand gesture
                      Container(
                        width: 108,
                        height: 108,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.10),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.18),
                              blurRadius: 28,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: const Center(
                          child: _AnimatedSwipeRightHand(),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Swipe Right',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'to watch Reels & Videos',
                        style: TextStyle(
                          color: Color(0xFF86EFAC),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Swipe your finger from left to right across the screen',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.70),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Looping swipe-from-left-to-right animated hand gesture
class _AnimatedSwipeRightHand extends StatefulWidget {
  const _AnimatedSwipeRightHand();

  @override
  State<_AnimatedSwipeRightHand> createState() => _AnimatedSwipeRightHandState();
}

class _AnimatedSwipeRightHandState extends State<_AnimatedSwipeRightHand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    // Horizontal sliding motion: from left (-0.35) across to right (+0.35)
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-0.35, 0.0),
      end: const Offset(0.35, 0.0),
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOutCubic,
      ),
    );

    // Natural gesture fade:
    // 0% -> 20%: touch down & fade in
    // 20% -> 75%: visible while moving left-to-right
    // 75% -> 100%: fade out & lift finger before looping
    _fadeAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 55,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
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
        child: const Icon(
          Icons.swipe_right_rounded,
          size: 60,
          color: Colors.white,
        ),
      ),
    );
  }
}




