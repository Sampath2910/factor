import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Full-screen in-app WebView for Grid schema `openIn: inAppWebView`.
///
/// Always fetches live from the server without local caching. When internet
/// is unavailable, renders a user-friendly offline illustration and message.
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
  }) {
    final ssoToken =
        initialUri.queryParameters['grid_sso'] ?? ssoTokenFallback;
    if (ssoToken == null || ssoToken.isEmpty) return uri;
    final updated = Map<String, String>.from(uri.queryParameters);
    updated['grid_sso'] = ssoToken;
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

  @override
  State<GridInAppWebViewPage> createState() => _GridInAppWebViewPageState();
}

class _GridInAppWebViewPageState extends State<GridInAppWebViewPage> {
  late final WebViewController _controller;
  var _loading = true;
  var _hasInjectedSso = false;
  String? _error;

  Uri get _effectiveUri => GridInAppWebViewPage.normalizeUri(widget.uri);

  @override
  void initState() {
    super.initState();
    _initController();
    _setupPermissionsAndLoad();
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
            if (!_hasInjectedSso &&
                GridInAppWebViewPage.shouldInjectSso(targetUri, initialUri: widget.uri)) {
              _hasInjectedSso = true;
              final redirected = GridInAppWebViewPage.injectSso(
                targetUri,
                initialUri: widget.uri,
              );
              unawaited(_controller.loadRequest(redirected));
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
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = null;
            });
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
            setState(() {
              _loading = false;
              _error = error.description;
            });
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
    await _controller.loadRequest(_effectiveUri);
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
    });
    if (!mounted) return;
    _hasInjectedSso = false;
    await _controller.loadRequest(_effectiveUri);
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
            ],
          ),
        ),
      ),
    );
  }
}

