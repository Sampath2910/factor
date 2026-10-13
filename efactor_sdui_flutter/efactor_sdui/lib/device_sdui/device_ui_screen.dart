import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/schema_repository.dart';
import '../iot_sdui/iot_schema_repository.dart';
import '../sdui/efactor_device_loader.dart';
import '../sdui/info_action.dart';
import '../sdui/renderer.dart';
import '../sdui/scanner_action.dart';
import '../sdui/schema_guard.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../sdui/schema_runtime.dart';
import '../sdui/style.dart';
import '../sdui/wifi_provisioning_action.dart';
import '../services/device_info_cache_manager.dart';
import '../services/device_live_connectivity.dart';
import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_offline.dart';
import '../services/schema_sync_manager.dart';
import '../state/app_state.dart';

class DeviceUiScreen extends StatefulWidget {
  const DeviceUiScreen({
    super.key,
    required this.modelId,
    required this.nodeId,
    required this.accessToken,
    required this.onAuthenticationFailure,
    required this.onDisconnect,
    this.initialOnline,
  });

  final String modelId;
  final String nodeId;
  final String accessToken;
  final Future<void> Function() onAuthenticationFailure;
  final VoidCallback onDisconnect;
  final bool? initialOnline;

  @override
  State<DeviceUiScreen> createState() => _DeviceUiScreenState();
}

class _DeviceUiScreenState extends State<DeviceUiScreen> {
  final SchemaRepository _repository = SchemaRepository();

  Map<String, dynamic>? _schema;
  final Map<int, Map<String, dynamic>> _pageSchemas = {};
  int currentPageNo = 1;
  int totalPageCount = 1;
  int _pageRequest = 0;

  String get modelNo => widget.modelId;
  String get nodeId => widget.nodeId;
  Map<String, dynamic>? get currentSchema => _schema;
  String? _errorMessage;
  bool _isLoading = true;
  bool _openingSavedSchema = false;
  bool _requestInProgress = false;
  int _loadGeneration = 0;
  int _schemaEpoch = 0;
  static const Duration _schemaEventDebounce = Duration(milliseconds: 250);

  StreamSubscription<SchemaInvalidationEvent>? _schemaInvalidationSubscription;
  StreamSubscription<SchemaUpdateNotification>? _schemaSyncSubscription;
  Timer? _schemaEventDebounceTimer;
  @override
  void initState() {
    super.initState();
    final remembered = _repository.peekMemory(
      modelId: widget.modelId,
      nodeId: widget.nodeId,
    );
    if (remembered != null) {
      _schema = remembered;
      _pageSchemas[currentPageNo] = remembered;
      totalPageCount = SchemaRepository.publishedPageCount(remembered);
      _isLoading = false;
    }
    _subscribeToSchemaInvalidations();
    _schemaSyncSubscription ??= SchemaSyncManager.instance.updates.listen(_onSchemaSyncUpdate);
    _initialize();
  }

  void _subscribeToSchemaInvalidations() {
    _schemaInvalidationSubscription ??= EfactorCloudService
        .instance.schemaInvalidations
        .listen(_onSchemaInvalidation);
  }

  void _onSchemaSyncUpdate(SchemaUpdateNotification notification) {
    if (!mounted) return;
    if (notification.schemaKey != 'device:${widget.modelId}:${widget.nodeId}') return;
    // A background refresh must not replace the open page with another
    // page's document. That document's later slides are empty.
    if (!SchemaRepository.pageSlotReady(notification.schema, currentPageNo)) {
      return;
    }

    debugPrint(
      '[DeviceUiScreen] HOT UPDATE APPLIED: '
      'usedDelta=${notification.usedDelta} '
      'structural=${notification.structural} '
      'nodes=${notification.changedNodeIds.length}',
    );

    final current = _schema;
    final merged = current != null
        ? SchemaRepository.mergeDevicePageSchema(current, notification.schema)
        : notification.schema;
    _pageSchemas[currentPageNo] = notification.schema;
    setState(() {
      _schema = merged;
      totalPageCount = math.max(
        totalPageCount,
        SchemaRepository.publishedPageCount(merged),
      );
      _schemaEpoch++;
    });
  }

  void _onSchemaInvalidation(SchemaInvalidationEvent event) {
    if (!mounted || _schema == null) return;

    final currentSchemaId = _schemaId(_schema!);
    final matches = event.matchesSchemaId(currentSchemaId) ||
        (event.matchesScope('device') &&
            event.matchesDevice(
              modelNo: widget.modelId,
              nodeId: widget.nodeId,
            ));
    if (!matches) return;

    final currentRevision = _schemaRevision(_schema!);
    if (event.revision != null &&
        currentRevision != null &&
        event.revision! <= currentRevision) {
      return;
    }

    _schemaEventDebounceTimer?.cancel();
    _schemaEventDebounceTimer = Timer(_schemaEventDebounce, () {
      if (mounted) {
        debugPrint(
          '[DEVICE_SDUI][SCHEMA_CHANGED] '
          'revision=${event.revision ?? '-'} -> background sync',
        );
        _syncDeviceSchemaBackground(_schema!);
      }
    });
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

  Future<void> _initialize() async {
    if (!SchemaRepository.storeDevicePagesLocally) {
      await _loadSchema(showLoading: true, forceRefresh: true);
      return;
    }

    // Already painted from in-memory cache in initState — refresh pages
    // in the background without showing a loading screen again.
    if (_schema != null) {
      _pageSchemas[1] ??= _schema!;
      if (mounted) {
        setState(() {
          _isLoading = false;
          _openingSavedSchema = false;
          _errorMessage = null;
        });
      }
      unawaited(_cacheRemainingPages());
      return;
    }

    final savedOnDisk = await _repository.cachedPageExists(
      modelId: widget.modelId,
      nodeId: widget.nodeId,
    );
    if (savedOnDisk && mounted) {
      setState(() => _openingSavedSchema = true);
    }

    // Local-first: paint all saved pages immediately when present.
    final cached = await _repository.readFromCache(
      modelId: widget.modelId,
      nodeId: widget.nodeId,
    );

    if (cached != null && mounted) {
      setState(() {
        _schema = cached;
        _pageSchemas[1] = cached;
        currentPageNo = 1;
        totalPageCount = math.max(
          totalPageCount,
          SchemaRepository.publishedPageCount(cached),
        );
        _schemaEpoch++;
        _isLoading = false;
        _openingSavedSchema = false;
        _errorMessage = null;
      });

      unawaited(() async {
        final merged = await _repository.loadMergedDeviceSchema(
          modelId: widget.modelId,
          nodeId: widget.nodeId,
          forceRefresh: false,
        );
        if (!mounted) return;
        final current = _schema;
        final unified = current != null
            ? SchemaRepository.mergeDevicePageSchema(current, merged)
            : merged;
        setState(() {
          _schema = unified;
          totalPageCount = math.max(
            totalPageCount,
            SchemaRepository.publishedPageCount(unified),
          );
          _schemaEpoch++;
        });
        unawaited(_cacheRemainingPages());
      }());
      return;
    }

    // First visit for this model/node: download once, then keep on disk.
    await _loadSchema(showLoading: true, forceRefresh: false);
  }

  Future<void> _syncDeviceSchemaBackground(Map<String, dynamic> current) async {
    await SchemaSyncManager.instance.syncDeviceSchemaInBackground(
      modelId: widget.modelId,
      nodeId: widget.nodeId,
      currentSchema: current,
      accessToken: widget.accessToken,
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _schemaEventDebounceTimer?.cancel();
    _schemaInvalidationSubscription?.cancel();
    _schemaSyncSubscription?.cancel();
    _repository.dispose();
    super.dispose();
  }

  /// Stores every page of this model sequentially, then refreshes the open page
  /// in the background when its server document changed without disturbing the user.
  Future<void> _cacheRemainingPages() async {
    if (!SchemaRepository.storeDevicePagesLocally) return;
    final model = widget.modelId.trim();
    final node = widget.nodeId.trim();
    if (model.isEmpty || node.isEmpty) return;

    if (_schema != null) {
      _pageSchemas[1] ??= _schema!;
    }

    try {
      await ModelSchemaCache.instance.syncModel(
        modelId: model,
        nodeId: node,
        activePageNo: currentPageNo,
        onPageUpdated: (pageNo, updatedSchema) {
          if (!mounted) return;
          _pageSchemas[pageNo] = updatedSchema;
          final current = _schema;
          if (current == null) {
            setState(() {
              _schema = updatedSchema;
              totalPageCount = math.max(
                totalPageCount,
                SchemaRepository.publishedPageCount(updatedSchema),
              );
              _schemaEpoch++;
              _isLoading = false;
              _errorMessage = null;
            });
            return;
          }
          final unified = SchemaRepository.mergeDevicePageSchema(
            current,
            updatedSchema,
          );
          final currentControlsCount = (current['controls'] as List?)?.length ?? 0;
          final unifiedControlsCount = (unified['controls'] as List?)?.length ?? 0;
          if (current['_clientSchemaHash'] != unified['_clientSchemaHash'] ||
              currentControlsCount != unifiedControlsCount) {
            debugPrint('[DeviceUiScreen] SILENT UPDATE APPLIED for page $pageNo');
            setState(() {
              _schema = unified;
              totalPageCount = math.max(
                totalPageCount,
                SchemaRepository.publishedPageCount(unified),
              );
              _schemaEpoch++;
              _isLoading = false;
              _errorMessage = null;
            });
          }
        },
      );
    } catch (error, stackTrace) {
      debugPrint('[DeviceUiScreen] background page sync error: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Loads `page_no` for the pager slot the user opened and stores it in
  /// `_pageSchemas` so each page displays according to its own server schema.
  Future<bool> _loadSchemaPage(
    int pageNo, {
    required bool forceRefresh,
  }) async {
    if (pageNo < 1 || pageNo > totalPageCount) return false;
    final cached = _pageSchemas[pageNo];
    if (!forceRefresh) {
      if (cached != null) {
        final current = _schema;
        final merged = current != null
            ? SchemaRepository.mergeDevicePageSchema(current, cached)
            : cached;
        if (currentPageNo != pageNo && mounted) {
          setState(() {
            currentPageNo = pageNo;
            _schema = merged;
            totalPageCount = math.max(
              totalPageCount,
              SchemaRepository.publishedPageCount(merged),
            );
            _schemaEpoch++;
            _isLoading = false;
            _errorMessage = null;
          });
        } else {
          currentPageNo = pageNo;
          _schema = merged;
        }
        return false;
      }

      final current = _schema;
      if (current != null && SchemaRepository.pageSlotReady(current, pageNo)) {
        _pageSchemas[pageNo] ??= current;
        if (currentPageNo != pageNo && mounted) {
          setState(() {
            currentPageNo = pageNo;
          });
        } else {
          currentPageNo = pageNo;
        }
        return false;
      }
    }

    final request = ++_pageRequest;
    try {
      final schema = await _repository.loadSchemaPage(
        modelId: modelNo,
        nodeId: nodeId,
        pageNo: pageNo,
        forceRefresh: forceRefresh,
      );
      if (!mounted || request != _pageRequest) return false;
      _pageSchemas[pageNo] = schema;
      setState(() {
        final current = _schema;
        final merged = current != null
            ? SchemaRepository.mergeDevicePageSchema(current, schema)
            : schema;
        _schema = merged;
        currentPageNo = pageNo;
        totalPageCount = math.max(
          totalPageCount,
          SchemaRepository.publishedPageCount(merged),
        );
        _schemaEpoch++;
        _isLoading = false;
        _errorMessage = null;
      });
      return true;
    } catch (error, stackTrace) {
      debugPrint('[DeviceUiScreen] page_no=$pageNo failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _loadSchema({
    required bool showLoading,
    required bool forceRefresh,
  }) async {
    if (_requestInProgress) return false;
    final generation = ++_loadGeneration;

    _requestInProgress = true;

    if (showLoading && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      if (!forceRefresh) {
        final opening = await _repository.loadMergedDeviceSchema(
          modelId: widget.modelId,
          nodeId: widget.nodeId,
        );
        if (!mounted || generation != _loadGeneration) return false;
        _pageSchemas[1] = opening;
        setState(() {
          _schema = opening;
          currentPageNo = 1;
          totalPageCount = math.max(
            totalPageCount,
            SchemaRepository.publishedPageCount(opening),
          );
          _schemaEpoch++;
          _isLoading = false;
          _errorMessage = null;
        });
        unawaited(_cacheRemainingPages());
        return true;
      }

      final incoming = await _repository.loadSchemaPage(
        modelId: modelNo,
        nodeId: nodeId,
        pageNo: currentPageNo,
        forceRefresh: true,
      );

      if (!mounted || generation != _loadGeneration) return false;

      final current = _schema;
      if (current != null &&
          schemaFingerprint(current) == schemaFingerprint(incoming)) {
        if (_isLoading || _errorMessage != null) {
          setState(() {
            _isLoading = false;
            _errorMessage = null;
          });
        }
        return false;
      }

      _pageSchemas[currentPageNo] = incoming;
      final merged = current != null
          ? SchemaRepository.mergeDevicePageSchema(current, incoming)
          : incoming;
      setState(() {
        _schema = merged;
        totalPageCount = math.max(
          totalPageCount,
          SchemaRepository.publishedPageCount(merged),
        );
        _schemaEpoch++;
        _isLoading = false;
        _errorMessage = null;
      });
      unawaited(_cacheRemainingPages());
      return true;
    } catch (error, stackTrace) {
      debugPrint('[DeviceUiScreen] LIVE SCHEMA LOAD FAILED: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return false;

      if (_schema == null && isTransientNetworkFailure(error)) {
        final saved = await _repository.readFromCache(
          modelId: widget.modelId,
          nodeId: widget.nodeId,
          allowStale: true,
        );
        if (saved != null && mounted && generation == _loadGeneration) {
          setState(() {
            _schema = saved;
            _pageSchemas[1] ??= saved;
            totalPageCount = math.max(
              totalPageCount,
              SchemaRepository.publishedPageCount(saved),
            );
            _schemaEpoch++;
            _isLoading = false;
            _errorMessage = null;
          });
          return true;
        }
      }

      if (!mounted) return false;

      setState(() {
        _isLoading = false;

        if (_schema == null) {
          _errorMessage = 'MODEL_ID: ${widget.modelId}\n'
              'NODE_ID: ${widget.nodeId}\n\n'
              '$error';
        } else {
          _errorMessage = null;
        }
      });
      return false;
    } finally {
      _requestInProgress = false;
    }
  }

  Widget _wrapAppOrPage({
    required BuildContext context,
    required Widget child,
    ThemeData? theme,
    String? title,
  }) {
    final media = MediaQuery.maybeOf(context);
    final clampedChild = media == null
        ? child
        : MediaQuery(
            data: media.copyWith(
              textScaler: media.textScaler.clamp(
                minScaleFactor: 0.85,
                maxScaleFactor: 1.15,
              ),
            ),
            child: child,
          );

    if (Navigator.maybeOf(context) != null) {
      if (theme != null) {
        return Theme(data: theme, child: clampedChild);
      }
      return clampedChild;
    }
    return MaterialApp(
      title: title ?? '',
      debugShowCheckedModeBanner: false,
      theme: theme ?? ThemeData(useMaterial3: true),
      home: clampedChild,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _schema == null) {
      return EfactorDeviceLoadingScreen(
        modelId: widget.modelId,
        nodeId: widget.nodeId,
        statusText: _openingSavedSchema
            ? 'Opening saved schema...'
            : 'Loading live schema...',
        onBack: widget.onDisconnect,
      );
    }

    if (_errorMessage != null && _schema == null) {
      return _wrapAppOrPage(
        context: context,
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: InkRipple.splashFactory,
          textTheme: GoogleFonts.poppinsTextTheme(),
        ),
        child: Scaffold(
          body: SchemaPullToRefresh(
            fillViewport: true,
            onRefresh: () =>
                _loadSchema(showLoading: false, forceRefresh: true).then((_) {}),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SchemaIssueWidget(
                      title: 'Live schema could not be loaded',
                      details: [_errorMessage!],
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: () =>
                          _loadSchema(showLoading: true, forceRefresh: true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: widget.onDisconnect,
                      icon: const Icon(Icons.edit),
                      label: const Text('Change MODEL_ID / NODE_ID'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final schema = _schema!;
    final colors = Map<String, dynamic>.from(
      schema['theme']?['colors'] as Map? ?? const {},
    );

    final schemaFont =
        schema['theme']?['typography']?['fontFamily']?.toString() ??
            schema['extensions']?['serverDrivenUi']?['theme']?['fontFamilies']
                    ?['body']?['family']
                ?.toString();

    final backgroundColor = SduiStyle.color(colors['background']);
    final primaryColor = SduiStyle.color(colors['primary']);

    if (schemaFont == null || schemaFont.trim().isEmpty) {
      return _wrapAppOrPage(
        context: context,
        child: const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SchemaIssueWidget(
                title: 'Schema typography missing',
                details: [
                  'Provide theme.typography.fontFamily '
                      '(or extensions.serverDrivenUi.theme.fontFamilies.body.family).',
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (backgroundColor == null || primaryColor == null) {
      return _wrapAppOrPage(
        context: context,
        child: const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SchemaIssueWidget(
                title: 'Schema color missing',
                details: [
                  'Provide theme.colors.background and theme.colors.primary '
                      'as valid colors.',
                ],
              ),
            ),
          ),
        ),
      );
    }

    TextTheme textTheme;
    try {
      textTheme = GoogleFonts.getTextTheme(schemaFont);
    } catch (error) {
      return _wrapAppOrPage(
        context: context,
        child: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SchemaIssueWidget(
                title: 'Schema typography unsupported',
                details: [
                  'theme.typography.fontFamily "$schemaFont" is not supported.',
                  '$error',
                ],
              ),
            ),
          ),
        ),
      );
    }

    final appTitle = schema['meta']?['app']?['name']?.toString();
    if (appTitle == null || appTitle.trim().isEmpty) {
      return _wrapAppOrPage(
        context: context,
        child: const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SchemaIssueWidget(
                title: 'Schema meta missing',
                details: ['Provide meta.app.name.'],
              ),
            ),
          ),
        ),
      );
    }

    final themeData = ThemeData(
      useMaterial3: true,
      splashFactory: InkRipple.splashFactory,
      scaffoldBackgroundColor: backgroundColor,
      colorScheme: ColorScheme.fromSeed(seedColor: primaryColor),
      textTheme: textTheme,
    );

    final content = _DeviceContentScreen(
      schema: schema,
      schemaEpoch: _schemaEpoch,
      accessToken: widget.accessToken,
      modelId: widget.modelId,
      nodeId: widget.nodeId,
      initialOnline: widget.initialOnline,
      onAuthenticationFailure: widget.onAuthenticationFailure,
      visiblePageIndex: currentPageNo - 1,
      onActivePageChanged: (pageIndex) {
        final pageNo = pageIndex + 1;
        if (currentPageNo == pageNo) return true;
        currentPageNo = pageNo;
        final current = _schema;
        if (current != null &&
            SchemaRepository.pageSlotReady(current, pageNo)) {
          _pageSchemas[pageNo] ??= current;
          return true;
        }
        final cached = _pageSchemas[pageNo];
        if (cached != null) {
          if (mounted) {
            setState(() {
              final merged = current != null
                  ? SchemaRepository.mergeDevicePageSchema(current, cached)
                  : cached;
              _schema = merged;
              totalPageCount = math.max(
                totalPageCount,
                SchemaRepository.publishedPageCount(merged),
              );
              _schemaEpoch++;
            });
          }
          return true;
        }
        final peek = _repository.peekMemory(
          modelId: widget.modelId,
          nodeId: widget.nodeId,
          pageNo: pageNo,
        );
        if (peek != null) {
          _pageSchemas[pageNo] = peek;
          if (mounted) {
            setState(() {
              final merged = current != null
                  ? SchemaRepository.mergeDevicePageSchema(current, peek)
                  : peek;
              _schema = merged;
              totalPageCount = math.max(
                totalPageCount,
                SchemaRepository.publishedPageCount(merged),
              );
              _schemaEpoch++;
            });
          }
          return true;
        }
        unawaited(_loadSchemaPage(pageNo, forceRefresh: false));
        return true;
      },
      onRefresh: () async {
        // Pull-to-refresh reloads the page that is open.
        return _loadSchemaPage(currentPageNo, forceRefresh: true);
      },
      onDisconnect: widget.onDisconnect,
    );

    return _wrapAppOrPage(
      context: context,
      title: appTitle,
      theme: themeData,
      child: content,
    );
  }
}

class _DeviceContentScreen extends StatefulWidget {
  const _DeviceContentScreen({
    required this.schema,
    required this.schemaEpoch,
    required this.accessToken,
    required this.modelId,
    required this.nodeId,
    required this.onAuthenticationFailure,
    required this.visiblePageIndex,
    required this.onActivePageChanged,
    required this.onRefresh,
    required this.onDisconnect,
    this.initialOnline,
  });

  final Map<String, dynamic> schema;
  final int schemaEpoch;
  final int visiblePageIndex;
  final bool Function(int pageIndex) onActivePageChanged;
  final String accessToken;
  final String modelId;
  final String nodeId;
  final bool? initialOnline;
  final Future<void> Function() onAuthenticationFailure;
  final Future<bool> Function() onRefresh;
  final VoidCallback onDisconnect;

  @override
  State<_DeviceContentScreen> createState() => _DeviceContentScreenState();
}

class _DeviceContentScreenState extends State<_DeviceContentScreen>
    with WidgetsBindingObserver {
  late final AppState _state;
  late SduiRenderer _renderer;

  bool _preserveValuesOnNextSchema = true;
  bool _isDisconnecting = false;
  String? _lastScreenMetricsSignature;

  /// The cloud socket answers state queries; it does not volunteer the current
  /// value of every parameter. Without an explicit request, a change made on
  /// the physical remote is never reported to this screen.
  static const Duration _liveStatePollInterval = Duration(seconds: 10);
  Timer? _liveStateTimer;
  StreamSubscription<bool>? _cloudConnectionSubscription;

  void _logScreenMetricsIfChanged(
    DeviceScreenMetrics metrics,
    SchemaResponsiveLayout? layout,
  ) {
    final signature = <Object?>[
      metrics.logicalWidth.toStringAsFixed(1),
      metrics.logicalHeight.toStringAsFixed(1),
      metrics.devicePixelRatio.toStringAsFixed(2),
      metrics.orientation,
      layout?.name,
      layout?.maxContentWidth,
    ].join('|');

    if (_lastScreenMetricsSignature == signature) return;
    _lastScreenMetricsSignature = signature;

    debugPrint(
      '[SDUI][SCREEN] '
      'logical=${metrics.logicalWidth.toStringAsFixed(1)}x'
      '${metrics.logicalHeight.toStringAsFixed(1)} '
      'physical=${metrics.physicalWidth.toStringAsFixed(0)}x'
      '${metrics.physicalHeight.toStringAsFixed(0)} '
      'dpr=${metrics.devicePixelRatio.toStringAsFixed(2)} '
      'orientation=${metrics.orientation} '
      'safe=${metrics.safeWidth.toStringAsFixed(1)}x'
      '${metrics.safeHeight.toStringAsFixed(1)} '
      'layout=${layout?.name ?? 'none'} '
      'maxContentWidth=${layout?.maxContentWidth ?? 'none'}',
    );
  }

  @override
  void initState() {
    super.initState();
    _state = AppState(
      widget.schema,
      accessToken: widget.accessToken,
      onAuthenticationFailure: widget.onAuthenticationFailure,
      onOpenScanner: handleOpenScanner,
      onOpenWifiConfig: handleOpenWifiConfig,
      onOpenInfo: handleOpenInfo,
      onPostProvisionRefresh: _refreshAfterProvisioning,
      onDeviceRemoved: () async {
        if (mounted) {
          widget.onDisconnect();
        }
      },
      onActivePageChanged: widget.onActivePageChanged,
    );
    _state.revealPageIndex(widget.visiblePageIndex);
    _state.attachParameterStore(
      modelId: widget.modelId,
      nodeId: widget.nodeId,
    );
    if (widget.initialOnline != null) {
      _state.applyLiveOnline(widget.initialOnline!);
    }
    _renderer = SduiRenderer(_state);
    WidgetsBinding.instance.addObserver(this);
    _cloudMessageSubscription = EfactorCloudService.instance.cloudMessages
        .listen(_onIncomingCloudMessage);
    _cloudConnectionSubscription =
        EfactorCloudService.instance.connectionChanges.listen((connected) {
      if (connected) unawaited(_requestLiveDeviceState());
    });
    unawaited(_hydrateCachedParameters());
    unawaited(_syncLiveOnline());
    _startLiveStatePolling();
    unawaited(
      DeviceInfoCacheManager.instance.preloadInfoData(
        state: _state,
        schema: widget.schema,
      ),
    );
  }

  Future<void> _hydrateCachedParameters() async {
    final applied = await _state.hydrateParametersFromCache();
    if (!mounted) return;
    if (applied > 0) {
      debugPrint(
        '[DEVICE_SDUI][CACHE] restored $applied live parameter(s) from disk',
      );
    }
  }

  StreamSubscription<Map<String, dynamic>>? _cloudMessageSubscription;

  void _startLiveStatePolling() {
    _liveStateTimer?.cancel();
    unawaited(_requestLiveDeviceState());
    _liveStateTimer = Timer.periodic(
      _liveStatePollInterval,
      (_) => unawaited(_requestLiveDeviceState()),
    );
  }

  /// Asks the cloud socket for this node's current state.
  ///
  /// Live telemetry arrives as `auto_get_nodes_params` (HTTP poll and/or
  /// WebSocket push). `getAllNodes` refreshes connectivity and the device
  /// power flag. The full schema document is not downloaded here:
  /// `meta.links.parameters` is the same multi-megabyte `api_schema.php`
  /// document already stored on disk.
  Future<void> _requestLiveDeviceState() async {
    if (!mounted) return;

    final cloud = EfactorCloudService.instance;
    final token = widget.accessToken.trim();
    if (token.isEmpty) return;

    if (!cloud.cloudConnected) {
      // Prefer the socket for getAllNodes, but never block the HTTP
      // auto_get_nodes_params poll — that is how tuning / remote pairing
      // readings refresh on both Android and iOS when the socket is down.
      try {
        await cloud.reconnect();
      } catch (error) {
        debugPrint('[DEVICE_SDUI][LIVE_STATE] reconnect failed: $error');
      }
    }

    if (cloud.cloudConnected) {
      try {
        await cloud.getAllNodes(apiKey: token, nodeId: widget.nodeId);
      } catch (error) {
        debugPrint('[DEVICE_SDUI][LIVE_STATE] getAllNodes failed: $error');
      }
    }

    if (!mounted) return;
    try {
      final updated = await _state.refreshLiveNodeParams();
      if (updated > 0) {
        debugPrint(
          '[DEVICE_SDUI][LIVE_STATE] updated $updated live parameter(s)',
        );
      }
    } catch (error) {
      debugPrint('[DEVICE_SDUI][LIVE_STATE] auto_get_nodes_params failed: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startLiveStatePolling();
      unawaited(_syncLiveOnline());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _liveStateTimer?.cancel();
      _liveStateTimer = null;
    }
  }

  void _onIncomingCloudMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    String normalizeNode(String? val) => (val ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\.+$'), '');

    final targetNode = normalizeNode(widget.nodeId);
    final directNode = normalizeNode(
      (message['node_id'] ??
              message['nodeId'] ??
              message['device_id'] ??
              message['deviceId'] ??
              message['id'])
          ?.toString(),
    );

    // If message explicitly specifies a different node ID, ignore it.
    if (directNode.isNotEmpty &&
        targetNode.isNotEmpty &&
        directNode != targetNode) {
      return;
    }

    // ignore: avoid_print
    print('[DEVICE_SDUI][REMOTE_RAW] matched node=$targetNode msg=$message');
    _state.ingestCloudPayload(message, nodeId: widget.nodeId);
  }

  Future<void> _syncLiveOnline() async {
    final online = await DeviceLiveConnectivity.resolve(
      accessToken: widget.accessToken,
      nodeId: widget.nodeId,
    );
    if (!mounted || online == null) return;
    _state.applyLiveOnline(online);
  }

  Future<void> _refreshAfterProvisioning() async {
    // The Wi-Fi schema requested a deviceState refresh. The next server schema
    // replacement must be allowed to provide fresh parameter values instead
    // of preserving stale pre-provision values.
    _preserveValuesOnNextSchema = false;
    try {
      final changed = await widget.onRefresh();
      if (!changed) {
        _preserveValuesOnNextSchema = true;
      }
    } catch (_) {
      _preserveValuesOnNextSchema = true;
      rethrow;
    }
  }

  @override
  void didUpdateWidget(covariant _DeviceContentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.accessToken != oldWidget.accessToken) {
      _state.setAccessToken(widget.accessToken);
    }

    if (widget.schemaEpoch != oldWidget.schemaEpoch) {
      final preserveValues = _preserveValuesOnNextSchema;
      _preserveValuesOnNextSchema = true;

      final patch = _state.replaceSchema(
        widget.schema,
        preserveValues: preserveValues,
        preservePage: true,
      );
      _state.revealPageIndex(widget.visiblePageIndex);
      if (patch.structural) {
        _renderer = SduiRenderer(_state);
      }
      // Schema placeholders must not erase the last known live values.
      unawaited(_hydrateCachedParameters());
      unawaited(_syncLiveOnline());
    } else if (widget.visiblePageIndex != oldWidget.visiblePageIndex) {
      _state.revealPageIndex(widget.visiblePageIndex);
    }
  }

  @override
  void dispose() {
    _liveStateTimer?.cancel();
    _cloudConnectionSubscription?.cancel();
    _cloudMessageSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _resolveRootTree(Map<String, dynamic> schema) {
    Map<String, dynamic>? asWidgetTree(dynamic value) {
      if (value is! Map) return null;

      final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());

      final type = map['type']?.toString().trim();
      return type == null || type.isEmpty ? null : map;
    }

    dynamic valueAtDeclaredPath(String rawPath) {
      final path = rawPath.trim();
      if (path.isEmpty) return null;

      dynamic current = schema;

      for (final rawPart in path.split('.')) {
        if (current is! Map) return null;

        final part = rawPart.trim();
        if (part.isEmpty) return null;

        dynamic matchingKey;

        for (final key in current.keys) {
          if (key.toString().toLowerCase() == part.toLowerCase()) {
            matchingKey = key;
            break;
          }
        }

        if (matchingKey == null) return null;
        current = current[matchingKey];
      }

      return current;
    }

    Map<String, dynamic>? treeAtDeclaredPath(String path) {
      return asWidgetTree(valueAtDeclaredPath(path));
    }

    final flutterEntry =
        schema['meta']?['flutterEntry']?.toString().trim() ?? '';

    final renderingLayout =
        schema['rendering']?['layout']?.toString().trim() ?? '';

    // rendering.layout is the concrete executable renderer contract.
    // meta.flutterEntry may name a server document that has not been generated
    // yet, so prefer the concrete layout when both are declared.
    final declaredEntries = <String>[
      if (renderingLayout.isNotEmpty) renderingLayout,
      if (flutterEntry.isNotEmpty &&
          flutterEntry.toLowerCase() != renderingLayout.toLowerCase())
        flutterEntry,
    ];

    for (final entry in declaredEntries) {
      final resolved = treeAtDeclaredPath(entry);

      if (resolved != null) {
        debugPrint(
          '[SDUI][ROOT] resolved declared entry="$entry" '
          'type=${resolved['type']}',
        );
        return resolved;
      }

      debugPrint(
        '[SDUI][ROOT] declared entry="$entry" is not a renderable widget tree',
      );
    }

    debugPrint(
      '[SDUI][ROOT][ERROR] no renderable schema-declared entry. '
      'flutterEntry="$flutterEntry" rendering.layout="$renderingLayout"',
    );

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final clampedMedia = media.copyWith(
      textScaler: media.textScaler.clamp(
        minScaleFactor: 0.85,
        maxScaleFactor: 1.15,
      ),
    );

    return MediaQuery(
      data: clampedMedia,
      child: Builder(
        builder: (clampedContext) {
          final screenMetrics = DeviceScreenMetrics.fromContext(clampedContext);
          final rootTree = _resolveRootTree(widget.schema);

          final background =
              SduiStyle.color(widget.schema['theme']?['colors']?['background']);
          if (background == null) {
            return const Scaffold(
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: SchemaIssueWidget(
                    title: 'Schema color missing',
                    details: ['Provide theme.colors.background as a valid color.'],
                  ),
                ),
              ),
            );
          }

          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop || _isDisconnecting) return;
              _isDisconnecting = true;
              widget.onDisconnect();
            },
            child: Scaffold(
              backgroundColor: background,
              body: SafeArea(
                bottom: true,
                child: SchemaPullToRefresh(
            fillViewport: true,
            onRefresh: () async {
              await widget.onRefresh();
            },
            child: AnimatedBuilder(
              animation: _state,
              builder: (context, _) {
                if (rootTree == null) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: SchemaIssueWidget(
                        title: 'Schema entry missing',
                        details: [
                          'None of the server-declared render entry points '
                              'resolved to a widget tree.',
                          'Check meta.flutterEntry and rendering.layout.',
                        ],
                      ),
                    ),
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final runtime = SchemaRuntime(widget.schema);
                    final responsiveLayout = runtime.resolveResponsiveLayout(
                      constraints.maxWidth,
                      logicalHeight: constraints.maxHeight,
                      orientation: screenMetrics.orientation,
                    );

                    _logScreenMetricsIfChanged(screenMetrics, responsiveLayout);

                    // Use the schema-selected maximum width when it exists.
                    // If the schema has no responsive contract, use the actual
                    // available Flutter width instead of inventing a device
                    // width or a component-specific fallback.
                    final schemaMaxWidth = responsiveLayout?.maxContentWidth;
                    final effectiveMaxWidth = schemaMaxWidth == null
                        ? constraints.maxWidth
                        : schemaMaxWidth
                            .clamp(0.0, constraints.maxWidth)
                            .toDouble();

                    // Host pull-to-refresh uses a viewport-sized ListView so
                    // nested page-mode ListViews still receive a bounded height.
                    return Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: effectiveMaxWidth,
                          maxHeight: constraints.maxHeight,
                        ),
                        child: _renderer.build(context, rootTree),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
        },
      ),
    );
  }
}
