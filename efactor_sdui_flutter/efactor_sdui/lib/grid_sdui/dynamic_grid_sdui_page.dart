import 'dart:async';

import 'package:flutter/material.dart';

import '../sdui/schema_guard.dart';
import '../sdui/sdui_network_image_cache.dart';
import '../services/json_http.dart';
import '../services/schema_incremental_sync.dart';
import '../services/schema_prefetch.dart';
import 'grid_in_app_webview_page.dart';
import 'grid_schema_repository.dart';
import 'grid_sdui_renderer.dart';
import 'grid_sdui_state.dart';

class DynamicGridSduiPage extends StatefulWidget {
  const DynamicGridSduiPage({
    super.key,
    required this.accessToken,
    this.userId,
    this.embedInHostShell = false,
    this.schemaRefreshEpoch = 0,
  });

  final String accessToken;
  final int? userId;

  /// When true, Home keeps its app shell (including the schema bottom bar)
  /// and this page fills only the shell body.
  final bool embedInHostShell;

  /// Bumped by the Home host when this tab is shown again so the live schema
  /// is refetched instead of the IndexedStack keeping a stale first paint.
  final int schemaRefreshEpoch;

  @override
  State<DynamicGridSduiPage> createState() => _DynamicGridSduiPageState();
}

class _DynamicGridSduiPageState extends State<DynamicGridSduiPage> {
  late final GridSchemaRepository _repository;
  GridSduiState? _state;
  GridSduiRenderer? _renderer;
  bool _loading = true;
  String? _error;
  String? _activeSchemaFingerprint;
  bool _revalidateInProgress = false;

  @override
  void initState() {
    super.initState();
    _repository = GridSchemaRepository(
      accessToken: widget.accessToken,
      userId: widget.userId,
    );
    // Cache-first: show disk/memory immediately, then revalidate in background.
    _load(forceRefresh: false);
  }

  @override
  void didUpdateWidget(covariant DynamicGridSduiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessToken != widget.accessToken ||
        oldWidget.userId != widget.userId) {
      _load(forceRefresh: false);
    } else if (oldWidget.schemaRefreshEpoch != widget.schemaRefreshEpoch) {
      _revalidateInBackground();
    }
  }

  @override
  void dispose() {
    _state?.dispose();
    _repository.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
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

    try {
      schema ??= await SchemaLoadQueue.instance.loadGrid(
        accessToken: widget.accessToken,
        userId: widget.userId,
        forceRefresh: forceRefresh,
      );
      if (!mounted || !generationOk) return;
      _applySchema(schema);

      if (!forceRefresh && schema['_clientGridSchemaCacheHit'] == true) {
        final isAsset = schema['_clientGridSchemaSource']?.toString().startsWith('asset://') ?? false;
        unawaited(_revalidateInBackground(forceFull: isAsset));
      }
    } catch (error, stack) {
      logDebug('[GRID_SDUI][LOAD_ERROR] $error');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _revalidateInBackground({bool forceFull = false}) async {
    if (!mounted || _revalidateInProgress) return;
    _revalidateInProgress = true;
    try {
      final SchemaSyncResult result = await _repository.revalidate(
        forceFull: forceFull,
      );
      if (!mounted || !result.changed) return;
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

  void _applySchema(Map<String, dynamic> schema) {
    final fingerprint = schemaFingerprint(schema);
    if (_state != null && fingerprint == _activeSchemaFingerprint) {
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
        builder: (_) => GridInAppWebViewPage(
          uri: authenticatedUri,
          title: title,
          accessToken: widget.accessToken,
          userId: widget.userId,
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
      return Center(
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
              child: renderer.buildRoot(context),
            ),
          ],
        );
      },
    );
  }
}
