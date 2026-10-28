import 'dart:async';

import 'package:flutter/material.dart';

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

class DynamicGridSduiPage extends StatefulWidget {
  const DynamicGridSduiPage({
    super.key,
    required this.accessToken,
    this.userId,
    this.embedInHostShell = false,
    this.schemaRefreshEpoch = 0,
    this.repository,
    this.enableAutoRefresh = true,
  });

  final String accessToken;
  final int? userId;

  /// When true, Home keeps its app shell (including the schema bottom bar)
  /// and this page fills only the shell body.
  final bool embedInHostShell;

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
  GridSduiRenderer? _renderer;
  bool _loading = true;
  String? _error;
  String? _activeSchemaFingerprint;
  bool _revalidateInProgress = false;

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
    _repository = widget.repository ??
        GridSchemaRepository(
          accessToken: widget.accessToken,
          userId: widget.userId,
        );
    _subscribeToSchemaInvalidations();
    if (widget.enableAutoRefresh) {
      _startAutoRefreshTimer();
    }
    // Cache-first: show disk/memory immediately, then revalidate in background.
    _load(forceRefresh: false);
  }

  void _startAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted || _state == null) return;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _schemaIsStaleForResume) {
      _revalidateInBackground(forceFull: false);
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
      _load(forceRefresh: false);
    } else if (oldWidget.schemaRefreshEpoch != widget.schemaRefreshEpoch) {
      _revalidateInBackground(forceFull: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _schemaInvalidationSubscription?.cancel();
    _cloudConnectionSubscription?.cancel();
    _schemaEventDebounceTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _state?.dispose();
    if (widget.repository == null) {
      _repository.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false, bool showFeedback = false}) async {
    final generationOk = mounted;
    Map<String, dynamic>? schema;
    if (!forceRefresh) {
      schema = _repository.peekMemory() ?? await _repository.readFromCache();
    }

    setState(() {
      // Only show a full-page spinner when there is nothing cached to paint.
      if (_state == null && schema == null) _loading = true;
      _error = null;
    });

    final previousFingerprint = _activeSchemaFingerprint;

    try {
      schema ??= widget.repository != null
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

      if (!forceRefresh) {
        // Eager revalidation: whenever the page is loaded (even from cache),
        // immediately fetch the live schema from the server in the background
        // so any schema update on the server is displayed without requiring a manual pull-to-refresh.
        unawaited(_revalidateInBackground(forceFull: true));
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
    if (!forceRebuild &&
        _state != null &&
        fingerprint == _activeSchemaFingerprint) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    _activeSchemaFingerprint = fingerprint;
    final next = GridSduiState(schema);
    next.inAppWebViewOpener = _openInAppWebView;
    _state?.dispose();
    setState(() {
      _state = next;
      _renderer = GridSduiRenderer(next);
      _loading = false;
      _error = null;
    });
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  Future<bool> _openInAppWebView(Uri uri, {String? title}) async {
    if (!mounted) return false;
    final authenticatedUri = await _repository.resolveAuthenticatedUri(
      uri,
      activeSchema: _state?.schema,
    );
    if (!mounted) return false;
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

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final renderer = _renderer;
    final background = state?.tokenColor('colors.pageBackground');
    final foreground = state?.tokenColor('colors.textPrimary');
    final body = _buildBody(context, state, renderer);

    if (state != null && (background == null || foreground == null)) {
      return const SchemaIssueWidget(
        title: 'Schema color missing',
        details: [
          'Provide designTokens.colors.pageBackground and designTokens.colors.textPrimary',
        ],
      );
    }

    if (widget.embedInHostShell) {
      if (background == null) {
        return body;
      }
      return ColoredBox(color: background, child: body);
    }

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: foreground,
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
    );
  }

  Widget _buildBody(
    BuildContext context,
    GridSduiState? state,
    GridSduiRenderer? renderer,
  ) {
    if (_loading && state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && state == null) {
      return SchemaPullToRefresh(
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
                Text(_error!, textAlign: TextAlign.center),
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
