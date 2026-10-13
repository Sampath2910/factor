import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../grid_sdui/dynamic_grid_sdui_page.dart';
import '../iot_sdui/dynamic_iot_sdui_page.dart';
import '../iot_sdui/iot_schema_repository.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_prefetch.dart';
import 'home_schema_repository.dart';
import 'home_sdui_renderer.dart';
import 'home_sdui_state.dart';

class DynamicHomeSduiPage extends StatefulWidget {
  const DynamicHomeSduiPage({
    super.key,
    required this.accessToken,
    this.refreshToken,
    this.userId,
    this.email,
    this.username,
    this.roles,
    this.onLogout,
    this.onOpenIot,
    this.onOpenGrid,
    this.onOpenDevice,
  });

  final String accessToken;
  final String? refreshToken;
  final int? userId;
  final String? email;
  final String? username;
  final List<String>? roles;
  final Future<void> Function()? onLogout;

  /// Existing authenticated host callback supplied by lib/main.dart.
  ///
  /// Home SDUI does not create its own IoT token/session/navigation path.
  /// The schema host-action `open-iot` delegates to this callback so the
  /// authoritative app host can open IoT with the current AuthState token.
  final Future<void> Function()? onOpenIot;

  /// Opens the live Grid SDUI document. Home does not render Grid itself.
  final Future<void> Function()? onOpenGrid;

  /// Host bridge for a schema-selected device. The schema must supply the
  /// selected live item's node/model values; Flutter never invents them.
  final Future<void> Function({
    required String modelId,
    required String nodeId,
    bool? online,
  })? onOpenDevice;

  @override
  State<DynamicHomeSduiPage> createState() => _DynamicHomeSduiPageState();
}

class _DynamicHomeSduiPageState extends State<DynamicHomeSduiPage>
    with WidgetsBindingObserver {
  final HomeSchemaRepository _repository = HomeSchemaRepository();

  static const Duration _resumeRefreshAfter = Duration(minutes: 2);
  static const Duration _schemaEventDebounce = Duration(milliseconds: 250);

  DateTime? _lastSchemaLoadAt;
  bool _schemaRefreshInProgress = false;
  String? _activeSchemaFingerprint;
  StreamSubscription<SchemaInvalidationEvent>? _schemaInvalidationSubscription;
  StreamSubscription<bool>? _cloudConnectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _nodeStatusSubscription;
  Timer? _schemaEventDebounceTimer;
  bool _cloudDisconnectedAfterConnect = false;
  int _loadGeneration = 0;

  HomeSduiState? _state;
  HomeSduiRenderer? _renderer;
  String? _error;
  bool _loading = true;
  bool _routeGuardScheduled = false;
  bool _isHandlingBack = false;
  bool _iotSurfaceOpened = false;
  bool _gridSurfaceOpened = false;
  bool _iotWasEmbedded = false;
  bool _gridWasEmbedded = false;
  int _iotRefreshEpoch = 0;
  int _gridRefreshEpoch = 0;

  bool get _hostAuthenticated => widget.accessToken.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeToSchemaInvalidations();
    _load(forceRefresh: false);
  }

  void _subscribeToSchemaInvalidations() {
    _schemaInvalidationSubscription ??= EfactorCloudService
        .instance.schemaInvalidations
        .listen(_onSchemaInvalidation);
    _cloudConnectionSubscription ??= EfactorCloudService
        .instance.connectionChanges
        .listen(_onCloudConnectionChanged);
    _nodeStatusSubscription ??= EfactorCloudService.instance.nodeStatusUpdates
        .listen((_) {
      if (mounted && _state != null) {
        _state!.applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
      }
    });
  }

  void _onSchemaInvalidation(SchemaInvalidationEvent event) {
    if (!mounted || !_hostAuthenticated || _state == null) return;

    final currentSchemaId = _schemaId(_state!.schema);
    final matches =
        event.matchesScope('home') || event.matchesSchemaId(currentSchemaId);
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
          '[HOME_SDUI][SCHEMA_CHANGED] '
          'revision=${event.revision ?? '-'} -> HTTPS revalidate',
        );
        _refreshLiveSchema();
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
      // Recovery for a schema_changed event that may have been missed while
      // the authenticated Cloud socket was disconnected. The current backend
      // schemas do not yet expose one cross-schema manifest in Flutter, so the
      // active Home scope performs one authoritative HTTPS revalidation.
      _refreshLiveSchema();
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
    final value = schema['revision'] ?? schema['schemaRevision'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _schemaIsStaleForResume) {
      // Foreground recovery is intentionally low-frequency. Normal live schema
      // invalidation is driven by the existing Efactor Cloud WebSocket.
      _refreshLiveSchema();
    }
  }

  bool get _schemaIsStaleForResume {
    final last = _lastSchemaLoadAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= _resumeRefreshAfter;
  }

  @override
  void didUpdateWidget(covariant DynamicHomeSduiPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final sessionChanged = oldWidget.accessToken != widget.accessToken ||
        oldWidget.refreshToken != widget.refreshToken ||
        oldWidget.userId != widget.userId ||
        oldWidget.email != widget.email ||
        !listEquals(oldWidget.roles, widget.roles);

    if (sessionChanged) {
      _load(forceRefresh: false);
    }
  }

  String _schemaFingerprint(Map<String, dynamic> schema) {
    return schemaFingerprint(schema);
  }

  Future<void> _refreshLiveSchema({
    bool showFeedback = false,
    bool forceFull = false,
  }) async {
    if (!mounted ||
        _schemaRefreshInProgress ||
        _state == null ||
        !_hostAuthenticated) {
      return;
    }

    _schemaRefreshInProgress = true;

    try {
      final result = await _repository.revalidate(
        accessToken: widget.accessToken,
        userId: widget.userId,
        forceFull: forceFull,
      );
      if (!mounted || _state == null) return;

      _lastSchemaLoadAt = DateTime.now();
      if (!result.changed) {
        logDebug(
          '[HOME_SDUI][AUTO_REFRESH] schema unchanged '
          'source=${result.source}',
        );
        return;
      }

      final incoming = result.schema;
      final fingerprint = _schemaFingerprint(incoming);

      if (fingerprint == _activeSchemaFingerprint) {
        logDebug('[HOME_SDUI][AUTO_REFRESH] schema unchanged');
        return;
      }

      logDebug(
        '[HOME_SDUI][AUTO_REFRESH] schema changed '
        'delta=${result.usedDelta} source=${result.source}',
      );
      _activeSchemaFingerprint = fingerprint;

      final patch = await _state!.replaceSchema(incoming);
      if (!mounted) return;

      if (patch.structural) {
        _renderer = HomeSduiRenderer(_state!);
      }

      setState(() {
        _error = null;
      });
    } catch (error, stackTrace) {
      logDebug('[HOME_SDUI][AUTO_REFRESH_ERROR] $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);

      if (showFeedback && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Home refresh failed: $error')));
      }
    } finally {
      _schemaRefreshInProgress = false;
    }
  }

  Future<void> _load({required bool forceRefresh}) async {
    final generation = ++_loadGeneration;
    try {
      Map<String, dynamic>? schema;
      if (!forceRefresh) {
        schema = HomeSchemaRepository.peekMemory(userId: widget.userId) ??
            await _repository.readFromCache(userId: widget.userId);
      }
      schema ??= await SchemaLoadQueue.instance.loadHome(
        forceRefresh: forceRefresh,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
      if (!mounted || generation != _loadGeneration) return;

      _lastSchemaLoadAt = DateTime.now();
      final fingerprint = _schemaFingerprint(schema);
      if (_state != null &&
          fingerprint == _activeSchemaFingerprint &&
          !forceRefresh) {
        setState(() {
          _loading = false;
          _error = null;
        });
        return;
      }

      _activeSchemaFingerprint = fingerprint;

      if (_state != null) {
        final patch = await _state!.replaceSchema(schema);
        if (!mounted || generation != _loadGeneration) return;
        if (patch.structural) {
          _renderer = HomeSduiRenderer(_state!);
        }
        setState(() {
          _error = null;
          _loading = false;
        });
      } else {
        final next = HomeSduiState(
          schema: schema,
          accessToken: widget.accessToken,
          refreshToken: widget.refreshToken,
          userId: widget.userId,
          email: widget.email,
          username: widget.username,
          roles: widget.roles,
        );

        if (_hostAuthenticated) {
          next.writeSecureState(
            'session.accessToken',
            widget.accessToken,
            notify: false,
          );
          next.writeSecureState(
            'session.iotAccessToken',
            widget.accessToken,
            notify: false,
          );
          next.writeState('session.authenticated', true, notify: false);
        }

        next.presentationHandler = _present;
        next.hostActionHandler = _handleHostAction;

        final renderer = HomeSduiRenderer(next);

        if (!mounted || generation != _loadGeneration) {
          next.dispose();
          return;
        }

        setState(() {
          _state = next;
          _renderer = renderer;
          _error = null;
          _loading = false;
        });

        await _guardAuthenticatedRoute(next);
        await next.loadRouteData();
      }

      if (schema['_clientHomeSchemaCacheHit'] == true && mounted) {
        _refreshLiveSchema();
      }
    } catch (error, stackTrace) {
      logDebug('[HOME_SDUI][LOAD_ERROR] $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _handleHostAction(
    String actionId,
    Map<String, dynamic> action,
  ) async {
    switch (actionId) {
      case 'open-iot':
        final state = _state;
        if (state != null && !state.replaceOnNestedSchema) {
          final routeId = state.routeIdForHostAction('open-iot');
          if (routeId != null && routeId.isNotEmpty) {
            await state.navigate(routeId);
            return;
          }
        }
        final handler = widget.onOpenIot;
        if (handler == null) {
          throw StateError(
            'Home schema requested open-iot but the authenticated host '
            'did not provide onOpenIot.',
          );
        }
        await handler();
        return;

      case 'open-grid':
      case 'open-grid-module':
        final gridState = _state;
        if (gridState != null && !gridState.replaceOnNestedSchema) {
          final routeId = gridState.routeIdForHostAction('open-grid') ??
              (action['routeId']?.toString().trim().isNotEmpty == true
                  ? action['routeId'].toString()
                  : 'grid');
          await gridState.navigate(routeId);
          return;
        }
        final gridHandler = widget.onOpenGrid;
        if (gridHandler == null) {
          throw StateError(
            'Home schema requested open-grid but the authenticated host '
            'did not provide onOpenGrid.',
          );
        }
        await gridHandler();
        return;

      case 'open-device':
      case 'open-device-sdui':
        final parameters = action['parameters'];
        final params = parameters is Map
            ? Map<String, dynamic>.from(parameters.cast<dynamic, dynamic>())
            : const <String, dynamic>{};
        String first(List<String> keys) {
          for (final key in keys) {
            final value = params[key]?.toString().trim() ?? '';
            if (value.isNotEmpty) return value;
          }
          return '';
        }

        final nodeId = first(<String>['nodeId', 'node_id', 'controlId']);
        final modelId = first(<String>[
          'modelNo',
          'model_no',
          'modelNumber',
          'model_number',
          'modelId',
        ]);
        if (nodeId.isEmpty || modelId.isEmpty) {
          throw StateError(
            'Home schema open-device action must provide selected device '
            'nodeId/node_id and modelNo/model_no/modelNumber.',
          );
        }
        final handler = widget.onOpenDevice;
        if (handler == null) {
          throw StateError('No Home Device SDUI host callback is registered.');
        }
        await handler(
          modelId: modelId,
          nodeId: nodeId,
          online: _asBool(params['online'] ?? params['isOnline']),
        );
        return;

      case 'external-navigate':
        final rawUrl = action['url']?.toString().trim() ?? '';
        final uri = Uri.tryParse(rawUrl);
        if (uri == null || !uri.hasScheme) {
          throw StateError('Home schema external URL is invalid.');
        }
        final opened = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (!opened) {
          throw StateError('Unable to open the schema-declared external URL.');
        }
        return;

      case 'logout':
        final handler = widget.onLogout;
        if (handler == null) {
          throw StateError(
            'Home schema requested logout but the authenticated host '
            'did not provide onLogout.',
          );
        }
        await handler();
        return;

      case 'apply-theme-preset':
        // The schema's preceding set-state actions already updated
        // global.themeMode/global.themePreset. The renderer observes state and
        // resolves themes.presets dynamically. No theme value is hardcoded.
        return;
      default:
        throw StateError('Unsupported Home host action "$actionId".');
    }
  }

  /// Prevents a server Home schema from displaying a second login screen after
  /// AuthUiGate has already authenticated the user.
  ///
  /// This is capability-driven:
  /// - no route name such as "login" is hardcoded;
  /// - if the active route is public while the host has a valid token, the
  ///   schema's own initial/default protected route is restored.
  Future<void> _guardAuthenticatedRoute(HomeSduiState state) async {
    if (!_hostAuthenticated) return;

    state.writeSecureState(
      'session.accessToken',
      widget.accessToken,
      notify: false,
    );
    state.writeSecureState(
      'session.iotAccessToken',
      widget.accessToken,
      notify: false,
    );
    state.writeState('session.authenticated', true, notify: false);

    final active = state.route(state.activeRouteId);
    if (active == null) return;

    final activeIsPublic = active['public'] == true;
    if (!activeIsPublic) return;

    final preferred = _preferredAuthenticatedRoute(state);
    if (preferred == null || preferred == state.activeRouteId) return;

    logDebug(
      '[HOME_SDUI][AUTH_GUARD] '
      'host session is authenticated; restoring protected route "$preferred".',
    );

    await state.navigate(preferred);
  }

  String? _preferredAuthenticatedRoute(HomeSduiState state) {
    final candidates = <dynamic>[
      state.schema['navigation']?['initialRouteId'],
      state.schema['meta']?['defaultRouteId'],
      state.readState('navigation.activeRouteId'),
    ];

    for (final raw in candidates) {
      final id = raw?.toString().trim() ?? '';
      if (id.isEmpty) continue;

      final definition = state.route(id);
      if (definition != null && definition['public'] != true) {
        return id;
      }
    }

    final routes = state.schema['routes'];
    if (routes is Map) {
      for (final entry in routes.entries) {
        final definition = entry.value;
        if (definition is Map && definition['public'] != true) {
          return entry.key.toString();
        }
      }
    }

    return null;
  }

  void _scheduleRouteGuard(HomeSduiState state) {
    if (!_hostAuthenticated || _routeGuardScheduled) return;

    final active = state.route(state.activeRouteId);
    if (active == null || active['public'] != true) return;

    _routeGuardScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _guardAuthenticatedRoute(state);
      } finally {
        _routeGuardScheduled = false;
      }
    });
  }

  Future<void> _present(
    Map<String, dynamic> action, {
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
  }) async {
    if (!mounted) return;

    final type = action['type']?.toString();

    if (type == 'show-snackbar') {
      final message = _state
              ?.resolve(action['message'], event: event, item: item)
              ?.toString() ??
          '';

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (type == 'show-dialog') {
      final title = _state
              ?.resolve(action['title'], event: event, item: item)
              ?.toString() ??
          '';

      final message = _state
              ?.resolve(action['message'], event: event, item: item)
              ?.toString() ??
          '';

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    if (type == 'show-bottom-sheet') {
      final id = action['componentId']?.toString();
      if (id == null || _renderer == null) return;

      Map<String, dynamic>? effectiveItem = item;

      if (effectiveItem == null && event?['componentId'] != null) {
        final sourceId = event!['componentId'].toString();
        final source = _state?.component(sourceId);
        if (source != null) {
          effectiveItem = <String, dynamic>{
            'id': sourceId,
            'faces': source['faces'],
          };
        }
      }

      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _renderer!.buildComponent(
              sheetContext,
              id,
              item: effectiveItem,
              event: event,
            ),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _schemaEventDebounceTimer?.cancel();
    _schemaInvalidationSubscription?.cancel();
    _cloudConnectionSubscription?.cancel();
    _nodeStatusSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _state?.dispose();
    _repository.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _state == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null && _state == null) {
      return Scaffold(
        body: SafeArea(
          child: SchemaPullToRefresh(
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
                    const Icon(Icons.schema_outlined, size: 44),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() => _loading = true);
                        _load(forceRefresh: true);
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final state = _state!;
    final renderer = _renderer!;

    if (_hostAuthenticated) {
      state.writeSecureState(
        'session.accessToken',
        widget.accessToken,
        notify: false,
      );
      state.writeSecureState(
        'session.iotAccessToken',
        widget.accessToken,
        notify: false,
      );
      state.writeState('session.authenticated', true, notify: false);
      _scheduleRouteGuard(state);
    }

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final activeRoute = state.route(state.activeRouteId);

        if (_hostAuthenticated && activeRoute?['public'] == true) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final page = state.pageForRoute(state.activeRouteId);

        if (page == null) {
          return const Scaffold(
            body: Center(child: Text('Active route has no page.')),
          );
        }

        final rootId = page['rootComponentId']?.toString();

        if (rootId == null || rootId.trim().isEmpty) {
          return const Scaffold(
            body: Center(child: Text('Page rootComponentId is missing.')),
          );
        }

        final shell = state.schema['appShell'];

        final bottomId = state.shouldShowBottomNavigation()
            ? (page['bottomNavigationComponentId']?.toString() ??
                  (shell is Map
                      ? shell['bottomNavigationComponentId']?.toString()
                      : null))
            : null;

        final fabId = shell is Map
            ? shell['floatingActionComponentId']?.toString()
            : null;

        final background = renderer.tokenColor('colors.pageBackground');
        final textScale = renderer.schemaTextScaleRange();

        Widget homeShell = PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop || _isHandlingBack) return;
            _isHandlingBack = true;
            try {
              final handled = await state.back();
              if (!handled && context.mounted) {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                } else {
                  await SystemNavigator.pop();
                }
              }
            } finally {
              if (mounted) {
                _isHandlingBack = false;
              }
            }
          },
          child: Scaffold(
            backgroundColor: background,
            body: SafeArea(
              bottom: false,
              child: _buildShellBody(
                context,
                state: state,
                renderer: renderer,
                rootId: rootId,
              ),
            ),
            bottomNavigationBar: bottomId == null
                ? null
                : renderer.buildComponent(context, bottomId),
            floatingActionButton:
                fabId == null ? null : renderer.buildComponent(context, fabId),
          ),
        );

        if (textScale != null) {
          final media = MediaQuery.of(context);
          homeShell = MediaQuery(
            data: media.copyWith(
              textScaler: media.textScaler.clamp(
                minScaleFactor: textScale.$1,
                maxScaleFactor: textScale.$2,
              ),
            ),
            child: homeShell,
          );
        }

        return homeShell;
      },
    );
  }

  Widget _buildShellBody(
    BuildContext context, {
    required HomeSduiState state,
    required HomeSduiRenderer renderer,
    required String rootId,
  }) {
    final embedIot = state.shouldEmbedLiveIot();
    final embedGrid = state.shouldEmbedLiveGrid();
    final returningToIot =
        embedIot && !_iotWasEmbedded && _iotSurfaceOpened;
    final returningToGrid =
        embedGrid && !_gridWasEmbedded && _gridSurfaceOpened;
    if (embedIot) _iotSurfaceOpened = true;
    if (embedGrid) _gridSurfaceOpened = true;
    if (returningToIot) _iotRefreshEpoch++;
    if (returningToGrid) _gridRefreshEpoch++;
    _iotWasEmbedded = embedIot;
    _gridWasEmbedded = embedGrid;

    final homeBody = SchemaPullToRefresh(
      // Pull-to-refresh reloads the LIVE Home schema itself,
      // not only the current route's data source.
      onRefresh: () => _refreshLiveSchema(
        showFeedback: false,
        forceFull: true,
      ),
      child: renderer.buildComponent(context, rootId),
    );

    if (!_iotSurfaceOpened && !_gridSurfaceOpened) {
      return homeBody;
    }

    return IndexedStack(
      index: embedIot
          ? 1
          : embedGrid
          ? 2
          : 0,
      sizing: StackFit.expand,
      children: <Widget>[
        homeBody,
        _iotSurfaceOpened
            ? DynamicIotSduiPage(
                key: const ValueKey<String>('home-host-iot'),
                accessToken: widget.accessToken,
                source: IotSchemaSource.fromEnvironment(),
                embedInHostShell: true,
                schemaRefreshEpoch: _iotRefreshEpoch,
                onOpenDevice: ({
                  required String modelId,
                  required String nodeId,
                  bool? online,
                }) async {
                  final handler = widget.onOpenDevice;
                  if (handler == null) {
                    throw StateError(
                      'No Home Device SDUI host callback is registered.',
                    );
                  }
                  await handler(
                    modelId: modelId,
                    nodeId: nodeId,
                    online: online,
                  );
                },
              )
            : const SizedBox.shrink(),
        _gridSurfaceOpened
            ? DynamicGridSduiPage(
                key: const ValueKey<String>('home-host-grid'),
                accessToken: widget.accessToken,
                userId: widget.userId,
                embedInHostShell: true,
                schemaRefreshEpoch: _gridRefreshEpoch,
              )
            : const SizedBox.shrink(),
      ],
    );
  }

  bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'online' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'offline' || text == 'off') {
      return false;
    }
    return null;
  }
}
