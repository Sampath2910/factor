import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
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
    _initController();
    _setupPermissionsAndLoad();
  }

  @override
  void dispose() {
    _outboxSyncedSub?.cancel();
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

            // Defensively intercept redirects to generic dashboard/home when the user
            // opened a specific module (Circle Connect /grid-chat or Professional Space /grid).
            final targetPath = targetUri.path.toLowerCase();
            final initialPath = widget.uri.path.toLowerCase();
            final isChatOrGrid = initialPath.contains('/grid-chat') ||
                initialPath.contains('/grid');
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
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = null;
            });
            _completeNavigation();
            unawaited(_injectCircleConnectPushBridge());
            _dispatchPendingCallActionIfPresent();
            if (!_showingSnapshot) {
              unawaited(_persistSnapshot());
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
    final token = IncomingCallService.instance.deviceToken ?? '';
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
    }
    final online = await _isOnline();
    if (!online) {
      final restored = await _tryLoadSnapshot();
      if (restored) return;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'offline';
      });
      return;
    }
    _showingSnapshot = false;
    final token = widget.accessToken?.trim() ?? '';
    final headers = <String, String>{
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (token.isNotEmpty) 'X-Efactor-Access-Token': token,
      if (widget.userId != null) 'X-Efactor-User-Id': widget.userId.toString(),
    };
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
    final html = await GridWebSnapshot.read(_effectiveUri);
    if (html == null || html.trim().isEmpty) return false;
    _showingSnapshot = true;
    await _controller.loadHtmlString(
      html,
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
      final raw = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      final html = _unwrapJsString(raw);
      if (html == null || html.length < 64) return;
      await GridWebSnapshot.save(_effectiveUri, html);
    } catch (e) {
      debugPrint('[GridInAppWebView] Snapshot save failed: $e');
    }
  }

  Future<void> _handleLoadFailure(String description) async {
    if (_showingSnapshot) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = description;
      });
      return;
    }
    final restored = await _tryLoadSnapshot();
    if (restored) return;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = description;
    });
  }

  static String? _unwrapJsString(Object? raw) {
    if (raw == null) return null;
    var text = raw.toString().trim();
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1);
      text = text
          .replaceAll(r'\"', '"')
          .replaceAll(r"\'", "'")
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\\', r'\');
    }
    return text;
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
                if (_showingSnapshot && _error == null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: Material(
                      color: const Color(0xCC1E293B),
                      borderRadius: BorderRadius.circular(10),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          'Showing last saved view (offline). Calls and live chat need internet.',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                if (_loading && _error == null)
                  const LinearProgressIndicator(minHeight: 2),
              ],
            ),
          ),
        ),
      );
    }
  }

