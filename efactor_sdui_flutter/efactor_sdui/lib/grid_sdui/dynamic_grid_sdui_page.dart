import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sdui/scanner_page.dart';
import '../sdui/schema_guard.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../sdui/sdui_network_image_cache.dart';
import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_incremental_sync.dart';
import '../services/schema_invalidation_event.dart';
import '../services/push_diagnostic_sheet.dart';
import '../services/schema_prefetch.dart';
import 'grid_in_app_webview_page.dart';
import 'grid_schema_repository.dart';
import 'grid_sdui_renderer.dart';
import 'grid_sdui_state.dart';
import 'grid_shell_pool.dart';
import '../core/theme_controller.dart';

class DynamicGridSduiPage extends StatefulWidget {
  const DynamicGridSduiPage({
    super.key,
    required this.accessToken,
    this.userId,
    this.embedInHostShell = false,
    this.includeTopSafeArea = false,
    this.isActive = true,
    this.schemaRefreshEpoch = 0,
    this.repository,
    this.enableAutoRefresh = true,
    this.onFullscreenChanged,
  });

  /// Notifies the host shell when the kept-alive Professional Space host is
  /// revealed (true) or hidden (false), so the shell can hide/show its app bar
  /// and bottom navigation for a fullscreen Professional Space. Null when the
  /// page is not embedded in a shell.
  final ValueChanged<bool>? onFullscreenChanged;

  final String accessToken;
  final int? userId;

  /// When true, Home keeps its app shell (including the schema bottom bar)
  /// and this page fills only the shell body.
  final bool embedInHostShell;

  /// When embedded inside a host shell that already removed outer top padding,
  /// apply SafeArea top inset internally so Grid's dark/light background paints
  /// edge-to-edge behind the status bar.
  final bool includeTopSafeArea;

  /// When embedded in a host shell, indicates whether this tab is active.
  final bool isActive;

  /// Bumped by the Home host when this tab is shown again so the live schema
  /// is refetched instead of the IndexedStack keeping a stale first paint.
  final int schemaRefreshEpoch;

  /// Optional repository instance (useful for test injection and isolation).
  final GridSchemaRepository? repository;

  /// Controls the 10-second background polling timer (disabled in widget tests).
  final bool enableAutoRefresh;

  @override
  State<DynamicGridSduiPage> createState() => _DynamicGridSduiPageState();
}

class _DynamicGridSduiPageState extends State<DynamicGridSduiPage>
    with WidgetsBindingObserver {
  late final GridSchemaRepository _repository;
  GridSduiState? _state;
  GridSduiState? _loadingThemeState;
  GridSduiRenderer? _renderer;
  bool _loading = true;
  String? _error;
  String? _activeSchemaFingerprint;
  String? _activeSchemaRev;
  bool _revalidateInProgress = false;

  // --- Professional Space keep-alive host (lazy-mounted, kept alive) ---
  // The PS WebView is created on first open and then kept mounted (offstage when
  // hidden) so every subsequent open is instant. Gated by
  // GridInAppWebViewPage.professionalSpaceKeepAlive; when off, PS uses the normal
  // route-push path (unchanged).
  Widget? _professionalSpaceShell;
  bool _professionalSpaceRevealed = false;
  final ValueNotifier<bool> _professionalSpaceReveal = ValueNotifier<bool>(false);

  static const Duration _resumeRefreshAfter = Duration(seconds: 30);
  static const Duration _schemaEventDebounce = Duration(milliseconds: 250);
  static const Duration _autoRefreshInterval = Duration(seconds: 10);

  DateTime? _lastSchemaLoadAt;
  StreamSubscription<SchemaInvalidationEvent>? _schemaInvalidationSubscription;
  StreamSubscription<bool>? _cloudConnectionSubscription;
  Timer? _schemaEventDebounceTimer;
  Timer? _autoRefreshTimer;
  bool _cloudDisconnectedAfterConnect = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild when the app-wide Appearance switch (Profile → Appearance)
    // changes so Grid follows light/dark/system like every other screen.
    ThemeController.instance.addListener(_onAppearanceChanged);
    _repository = widget.repository ??
        GridSchemaRepository(
          accessToken: widget.accessToken,
          userId: widget.userId,
        );
    final peeked = _repository.peekMemory();
    if (peeked != null) {
      _loadingThemeState = GridSduiState(
        peeked,
        platformBrightness:
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
      );
    }
    _subscribeToSchemaInvalidations();
    if (widget.enableAutoRefresh) {
      _startAutoRefreshTimer();
    }
    // Network-first on open: fetch live get_grid so layout, theme, avatar,
    // QR, and Updates are fresh, with disk/asset used only for offline fallback.
    _load(forceRefresh: true, fromInitState: true);
  }

  void _startAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    if (widget.embedInHostShell && !widget.isActive) return;
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted || _state == null) return;
      if (widget.embedInHostShell && !widget.isActive) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      _revalidateInBackground(forceFull: false);
    });
  }

  void _subscribeToSchemaInvalidations() {
    _schemaInvalidationSubscription ??= EfactorCloudService
        .instance.schemaInvalidations
        .listen(_onSchemaInvalidation);
    _cloudConnectionSubscription ??= EfactorCloudService
        .instance.connectionChanges
        .listen(_onCloudConnectionChanged);
  }

  void _onSchemaInvalidation(SchemaInvalidationEvent event) {
    if (!mounted || _state == null) return;

    final currentSchemaId = _schemaId(_state!.schema);
    final matches =
        event.matchesScope('grid') || event.matchesScope('circle') || event.matchesSchemaId(currentSchemaId);
    if (!matches) return;

    final currentRevision = _schemaRevision(_state!.schema);
    if (event.revision != null &&
        currentRevision != null &&
        event.revision! <= currentRevision) {
      return;
    }

    _schemaEventDebounceTimer?.cancel();
    _schemaEventDebounceTimer = Timer(_schemaEventDebounce, () {
      if (mounted) {
        logDebug(
          '[GRID_SDUI][SCHEMA_CHANGED] '
          'revision=${event.revision ?? '-'} -> HTTPS revalidate',
        );
        _revalidateInBackground(forceFull: true);
      }
    });
  }

  void _onCloudConnectionChanged(bool connected) {
    if (!connected) {
      if (EfactorCloudService.instance.libraryInitialized) {
        _cloudDisconnectedAfterConnect = true;
      }
      return;
    }

    if (_cloudDisconnectedAfterConnect && mounted && _state != null) {
      _cloudDisconnectedAfterConnect = false;
      _revalidateInBackground(forceFull: true);
    }
  }

  String? _schemaId(Map<String, dynamic> schema) {
    for (final value in <dynamic>[
      schema['schemaId'],
      schema['schema_id'],
      schema['id'],
    ]) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  int? _schemaRevision(Map<String, dynamic> schema) {
    final value = schema['revision'] ??
        schema['schemaRevision'] ??
        schema['schema_version'] ??
        schema['schemaVersion'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    final str = value?.toString().trim() ?? '';
    final parsed = int.tryParse(str);
    if (parsed != null) return parsed;
    final firstNum = RegExp(r'^\d+').firstMatch(str)?.group(0);
    return firstNum != null ? int.tryParse(firstNum) : null;
  }

  @override
  void didChangePlatformBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _state?.updatePlatformBrightness(brightness);
    _loadingThemeState?.updatePlatformBrightness(brightness);
    if (mounted) {
      setState(() {});
    }
  }

  /// The Profile → Appearance switch changed. Grid resolves its mode from
  /// [ThemeController], so a rebuild is enough to repaint in the new mode.
  void _onAppearanceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      _state?.updatePlatformBrightness(brightness);
      _loadingThemeState?.updatePlatformBrightness(brightness);
      if (_schemaIsStaleForResume) {
        _revalidateInBackground(forceFull: true);
      }
    }
  }

  bool get _schemaIsStaleForResume {
    final last = _lastSchemaLoadAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= _resumeRefreshAfter;
  }

  @override
  void didUpdateWidget(covariant DynamicGridSduiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessToken != widget.accessToken ||
        oldWidget.userId != widget.userId) {
      _load(forceRefresh: true);
    } else if (oldWidget.schemaRefreshEpoch != widget.schemaRefreshEpoch) {
      _revalidateInBackground(forceFull: true);
    }

    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        if (widget.enableAutoRefresh) _startAutoRefreshTimer();
        _revalidateInBackground(forceFull: false);
      } else {
        _autoRefreshTimer?.cancel();
        _autoRefreshTimer = null;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ThemeController.instance.removeListener(_onAppearanceChanged);
    _schemaInvalidationSubscription?.cancel();
    _cloudConnectionSubscription?.cancel();
    _schemaEventDebounceTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _state?.dispose();
    _loadingThemeState?.dispose();
    _professionalSpaceReveal.dispose();
    if (widget.repository == null) {
      _repository.dispose();
    }
    super.dispose();
  }

  Future<void> _load({
    bool forceRefresh = true,
    bool showFeedback = false,
    bool fromInitState = false,
  }) async {
    final generationOk = mounted;

    if (_state == null && _loadingThemeState == null) {
      unawaited(
        _repository.readFromCache().then((cached) {
          if (!mounted || _state != null || cached == null) return;
          final brightness =
              WidgetsBinding.instance.platformDispatcher.platformBrightness;
          setState(() {
            _loadingThemeState?.dispose();
            _loadingThemeState = GridSduiState(
              cached,
              platformBrightness: brightness,
            );
          });
        }),
      );
    }

    if (fromInitState) {
      if (_state == null) _loading = true;
      _error = null;
    } else {
      setState(() {
        if (_state == null) _loading = true;
        _error = null;
      });
    }

    final previousFingerprint = _activeSchemaFingerprint;

    try {
      final schema = widget.repository != null
          ? await _repository.load(forceRefresh: forceRefresh)
          : await SchemaLoadQueue.instance.loadGrid(
              accessToken: widget.accessToken,
              userId: widget.userId,
              forceRefresh: forceRefresh,
            );
      if (!mounted || !generationOk) return;
      _lastSchemaLoadAt = DateTime.now();

      final isOfflineFallback =
          schema['_clientGridSchemaOfflineFallback'] == true;
      final newFingerprint = schemaFingerprint(schema);
      final hasChanged = previousFingerprint == null ||
          newFingerprint != previousFingerprint;

      _applySchema(schema, forceRebuild: forceRefresh);

      if (showFeedback && mounted) {
        final String message;
        if (isOfflineFallback) {
          message = 'Could not reach server. Showing cached Grid.';
        } else if (hasChanged) {
          message = 'Grid live schema updated successfully.';
        } else {
          message = 'Grid schema is already up to date.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error, stack) {
      logDebug('[GRID_SDUI][LOAD_ERROR] $error');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });

      if (showFeedback && mounted) {
        final is500 = error.toString().contains('500');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              is500
                  ? 'Server Error (HTTP 500) on grid_api_creation.php. Backend fix required.'
                  : 'Grid live refresh failed: $error',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _revalidateInBackground({bool forceFull = false}) async {
    if (!mounted || _revalidateInProgress) return;
    if (widget.embedInHostShell && !widget.isActive) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _revalidateInProgress = true;
    try {
      final SchemaSyncResult result = await _repository.revalidate(
        forceFull: forceFull,
      );
      if (!mounted) return;
      _lastSchemaLoadAt = DateTime.now();
      if (!result.changed) return;
      _applySchema(result.schema);
      logDebug(
        '[GRID_SDUI][AUTO_REFRESH] applied '
        'delta=${result.usedDelta} source=${result.source}',
      );
    } catch (error, stack) {
      logDebug('[GRID_SDUI][AUTO_REFRESH_ERROR] $error');
      debugPrintStack(stackTrace: stack);
    } finally {
      _revalidateInProgress = false;
    }
  }

  void _applySchema(Map<String, dynamic> schema, {bool forceRebuild = false}) {
    final fingerprint = schemaFingerprint(schema);
    final nextRev = GridSchemaRepository.extractSchemaRev(schema);
    final revChanged = nextRev != null && nextRev != _activeSchemaRev;
    final platformBrightness = mounted
        ? (MediaQuery.maybePlatformBrightnessOf(context) ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness)
        : WidgetsBinding.instance.platformDispatcher.platformBrightness;

    if (!forceRebuild &&
        !revChanged &&
        _state != null &&
        fingerprint == _activeSchemaFingerprint) {
      _state!.updatePlatformBrightness(platformBrightness, notify: false);
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    _activeSchemaFingerprint = fingerprint;
    _activeSchemaRev = nextRev;
    final next = GridSduiState(
      schema,
      platformBrightness: platformBrightness,
    );
    next.inAppWebViewOpener = _openInAppWebView;
    next.nativeScannerOpener = _openNativeScanner;
    next.refreshHandler = () => _load(forceRefresh: true);
    _state?.dispose();
    _loadingThemeState?.dispose();
    _loadingThemeState = null;
    setState(() {
      _state = next;
      _renderer = GridSduiRenderer(next);
      _loading = false;
      _error = null;
    });
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  Future<bool> _openNativeScanner() async {
    if (!mounted) return false;
    final scan = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => const ScannerPage(
          camera: 'back',
          qrOnly: true,
        ),
      ),
    );

    if (!mounted) return false;
    if (scan == null) {
      // User closed or cancelled the scanner — completed interaction, not a fatal failure.
      return true;
    }
    final rawValue =
        (scan['value'] ?? scan['displayValue'])?.toString().trim() ?? '';
    if (rawValue.isEmpty) return true;

    // If scanned value is an HTTP/HTTPS URL, open it authenticated in WebView
    final uri = Uri.tryParse(rawValue);
    if (uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      await _openInAppWebView(uri, title: 'Connect');
      return true;
    }

    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(
            Icons.qr_code_scanner,
            size: 36,
            color: Color(0xFF7C3AED),
          ),
          title: const Text('QR Code Scanned'),
          content: SelectableText(rawValue),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return true;
  }

  Future<bool> _openInAppWebView(Uri uri, {String? title}) async {
    if (!mounted) return false;
    final authenticatedUri = await _repository.resolveAuthenticatedUri(
      uri,
      activeSchema: _state?.schema,
    );
    if (!mounted) return false;

    // Professional Space: reveal the kept-alive host instead of pushing a new
    // route (created lazily on first open, then mounted/alive for instant
    // re-open). Everything else keeps the normal route-push path unchanged.
    if (GridInAppWebViewPage.professionalSpaceKeepAlive &&
        GridShellPool.instance.isProfessionalSpaceUri(authenticatedUri)) {
      _revealProfessionalSpace(authenticatedUri, title: title);
      return true;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GridShellPool.instance.getOrCreateWarmShell(
          uri: authenticatedUri,
          userId: widget.userId,
          shellBuilder: () => GridInAppWebViewPage(
            uri: authenticatedUri,
            title: title,
            accessToken: widget.accessToken,
            userId: widget.userId,
          ),
        ),
      ),
    );
    return true;
  }

  /// Creates the Professional Space shell on first open, then reveals it. On
  /// later opens the already-mounted shell is revealed instantly and told to
  /// refresh silently (via its revealSignal) — no reload, no new route.
  void _revealProfessionalSpace(Uri uri, {String? title}) {
    _professionalSpaceShell ??= GridInAppWebViewPage(
      key: const ValueKey('professional_space_keepalive'),
      uri: uri,
      title: title,
      accessToken: widget.accessToken,
      userId: widget.userId,
      onRequestHide: _hideProfessionalSpace,
      revealSignal: _professionalSpaceReveal,
    );
    setState(() => _professionalSpaceRevealed = true);
    _professionalSpaceReveal.value = true;
    widget.onFullscreenChanged?.call(true); // host hides app bar + bottom nav
  }

  /// Hides the Professional Space host (keeps it mounted/alive). Called by the
  /// page's back/exit path via onRequestHide.
  void _hideProfessionalSpace() {
    if (!mounted) return;
    setState(() => _professionalSpaceRevealed = false);
    _professionalSpaceReveal.value = false;
    widget.onFullscreenChanged?.call(false); // host restores app bar + bottom nav
  }

  @override
  Widget build(BuildContext context) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final state = _state;
    final renderer = _renderer;
    state?.updatePlatformBrightness(platformBrightness, notify: false);
    _loadingThemeState?.updatePlatformBrightness(
      platformBrightness,
      notify: false,
    );

    final activeThemeState = state ?? _loadingThemeState;
    final background = activeThemeState?.tokenColor('colors.pageBackground');
    final foreground = activeThemeState?.tokenColor('colors.textPrimary');
    final isDark = activeThemeState?.isDarkMode ??
        (platformBrightness == Brightness.dark);

    if (state != null && (background == null || foreground == null)) {
      return const SchemaIssueWidget(
        title: 'Schema color missing',
        details: [
          'Provide designTokens.colors.pageBackground and designTokens.colors.textPrimary',
        ],
      );
    }

    final themedData = _gridThemeData(
      context,
      state: activeThemeState,
      isDark: isDark,
      background: background,
      foreground: foreground,
    );

    final body = _buildBody(
      context,
      state,
      renderer,
      isDark: isDark,
    );

    final overlayStyle = widget.embedInHostShell
        ? SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness:
                isDark ? Brightness.dark : Brightness.light,
          )
        : SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness:
                isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: background,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          );

    if (widget.embedInHostShell) {
      Widget embedded = SafeArea(
        top: widget.includeTopSafeArea,
        bottom: false,
        child: body,
      );
      if (background != null) {
        embedded = ColoredBox(color: background, child: embedded);
      }
      return _withProfessionalSpaceHost(
        AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayStyle,
          sized: false,
          child: Theme(data: themedData, child: embedded),
        ),
      );
    }

    return _withProfessionalSpaceHost(
      Theme(
        data: themedData,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayStyle,
          sized: false,
          child: Scaffold(
            backgroundColor: background,
            appBar: AppBar(
              backgroundColor: background,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              foregroundColor: foreground,
              systemOverlayStyle: overlayStyle,
              actions: [
                IconButton(
                  icon: const Icon(Icons.troubleshoot, size: 20),
                  tooltip: 'Push Notification & Call Diagnostics',
                  onPressed: () {
                    PushDiagnosticSheet.show(
                      context,
                      userId: widget.userId?.toString(),
                      accessToken: widget.accessToken,
                    );
                  },
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  /// Overlays the kept-alive Professional Space shell above the hub. The shell
  /// stays mounted (so re-open is instant) and is simply hidden via [Offstage]
  /// when not revealed. Returns the hub unchanged when keep-alive is off or the
  /// shell has not been created yet (lazy — first open creates it).
  Widget _withProfessionalSpaceHost(Widget hub) {
    final shell = _professionalSpaceShell;
    if (!GridInAppWebViewPage.professionalSpaceKeepAlive || shell == null) {
      return hub;
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(child: hub),
        Positioned.fill(
          child: Offstage(
            offstage: !_professionalSpaceRevealed,
            child: TickerMode(
              enabled: _professionalSpaceRevealed,
              child: shell,
            ),
          ),
        ),
      ],
    );
  }

  ThemeData _gridThemeData(
    BuildContext context, {
    required GridSduiState? state,
    required bool isDark,
    required Color? background,
    required Color? foreground,
  }) {
    final base = Theme.of(context);
    final surface = state?.tokenColor('colors.surface') ?? background;
    final accent = state?.tokenColor('colors.accent');
    final onAccent = state?.tokenColor('colors.onAccent');
    final onSurface = state?.tokenColor('colors.onSurface') ?? foreground;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent ?? base.colorScheme.primary,
      brightness: isDark ? Brightness.dark : Brightness.light,
    ).copyWith(
      primary: accent,
      onPrimary: onAccent,
      surface: surface,
      onSurface: onSurface,
    );
    return base.copyWith(
      brightness: isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: background ?? scheme.surface,
    );
  }

  Widget _buildBody(
    BuildContext context,
    GridSduiState? state,
    GridSduiRenderer? renderer, {
    required bool isDark,
  }) {
    if (_loading && state == null) {
      final skeletonState = _loadingThemeState;
      final skeletonComp = skeletonState?.component('grid-loading');
      if (skeletonState != null && skeletonComp != null) {
        return GridSduiRenderer(skeletonState).buildNode(context, skeletonComp);
      }
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && state == null) {
      final fallbackState = _loadingThemeState;
      final errorComp = fallbackState?.component('grid-error');
      final errorAppearance = (fallbackState != null && errorComp != null)
          ? fallbackState.resolvedAppearance(errorComp)
          : const <String, dynamic>{};
      final errorBg =
          fallbackState?.parseColor(errorAppearance['backgroundColor']) ??
              fallbackState?.tokenColor('colors.pageBackground');
      final errorTextColor =
          fallbackState?.parseColor(errorAppearance['titleColor']) ??
              fallbackState?.tokenColor('colors.textPrimary');

      Widget errorBody = SchemaPullToRefresh(
        fillViewport: true,
        onRefresh: () async {
          setState(() => _loading = true);
          await _load(forceRefresh: true);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (errorComp != null &&
                    (errorComp['title']?.toString().trim().isNotEmpty ?? false))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      errorComp['title'].toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: errorTextColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: errorTextColor == null
                      ? null
                      : TextStyle(color: errorTextColor.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _load(forceRefresh: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
      if (errorBg != null) {
        errorBody = ColoredBox(color: errorBg, child: errorBody);
      }
      return errorBody;
    }

    if (state == null || renderer == null) {
      return const SizedBox.shrink();
    }

    final errorBg = Theme.of(context).colorScheme.errorContainer;
    final errorFg = Theme.of(context).colorScheme.onErrorContainer;
    final successBg = state.tokenColor('colors.successSurface') ??
        state.tokenColor('colors.surface');
    final successFg = state.tokenColor('colors.success') ??
        state.tokenColor('colors.textPrimary');

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        state.updatePlatformBrightness(
          MediaQuery.platformBrightnessOf(context),
          notify: false,
        );
        return Column(
          children: <Widget>[
            if (state.lastError != null)
              Material(
                color: errorBg,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    state.lastError!,
                    style: TextStyle(color: errorFg),
                  ),
                ),
              ),
            if (state.schema['_clientShareCopied'] == true &&
                successBg != null &&
                successFg != null)
              Material(
                color: successBg,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    'Profile link copied.',
                    style: TextStyle(color: successFg),
                  ),
                ),
              ),
            Expanded(
              child: SchemaPullToRefresh(
                onRefresh: () => _load(forceRefresh: true, showFeedback: true),
                child: renderer.buildRoot(context),
              ),
            ),
          ],
        );
      },
    );
  }
}
