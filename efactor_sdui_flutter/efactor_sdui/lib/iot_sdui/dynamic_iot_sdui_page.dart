import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_prefetch.dart';
import '../sdui/efactor_device_loader.dart';
import '../sdui/scanner_page.dart';
import '../sdui/schema_pull_to_refresh.dart';
import 'iot_schema_repository.dart';
import 'iot_schema_icon.dart';
import 'iot_sdui_renderer.dart';
import 'iot_sdui_state.dart';

class DynamicIotSduiPage extends StatefulWidget {
  const DynamicIotSduiPage({
    super.key,
    required this.accessToken,
    required this.source,
    this.onOpenDevice,
    this.embedInHostShell = false,
    this.schemaRefreshEpoch = 0,
  });

  /// Current authenticated token from the existing AuthState.
  ///
  /// It is used for the live server schema request and for schema-declared
  /// IoT datasources. No IoT schema asset path exists in this runtime.
  final String accessToken;
  final IotSchemaSource source;

  /// Opens the already-existing Device SDUI using the selected live device
  /// identity. The values are resolved from the tapped device record; no
  /// model number or node id is hardcoded here.
  final Future<void> Function({
    required String modelId,
    required String nodeId,
    bool? online,
  })?
  onOpenDevice;

  /// When true, Home keeps its app shell (including the schema bottom bar)
  /// and this page fills only the shell body.
  final bool embedInHostShell;

  /// Bumped by the Home host when this tab is shown again so the live schema
  /// is refetched instead of the IndexedStack keeping a stale first paint.
  final int schemaRefreshEpoch;

  @override
  State<DynamicIotSduiPage> createState() => _DynamicIotSduiPageState();
}

class _DynamicIotSduiPageState extends State<DynamicIotSduiPage>
    with WidgetsBindingObserver {
  static const Duration _resumeRefreshAfter = Duration(minutes: 2);
  static const Duration _schemaEventDebounce = Duration(milliseconds: 250);
  DateTime? _lastSchemaLoadAt;
  bool _schemaRefreshInProgress = false;
  int _loadGeneration = 0;
  String? _activeSchemaFingerprint;
  StreamSubscription<SchemaInvalidationEvent>? _schemaInvalidationSubscription;
  StreamSubscription<bool>? _cloudConnectionSubscription;
  Timer? _schemaEventDebounceTimer;
  bool _cloudDisconnectedAfterConnect = false;

  /// The device tiles show live power/online state, which can be changed from
  /// the physical remote. The schema does not change when that happens, so the
  /// grid datasources have to be re-read on their own cadence.
  static const Duration _deviceStateRefreshInterval = Duration(seconds: 15);
  Timer? _deviceStateTimer;
  StreamSubscription<Map<String, dynamic>>? _nodeStatusSubscription;
  bool _deviceStateRefreshInProgress = false;

  late IotSchemaRepository _repository;
  IotSduiState? _state;
  IotSduiRenderer? _renderer;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _repository = _createRepository();
    unawaited(ModelSchemaCache.instance.open());
    _subscribeToSchemaInvalidations();
    _load(forceRefresh: false);
    _startDeviceStatePolling();

    WidgetsBinding.instance.addObserver(this);
  }

  void _startDeviceStatePolling() {
    _nodeStatusSubscription ??= EfactorCloudService.instance.nodeStatusUpdates
        .listen((_) => unawaited(_refreshDeviceState()));

    _deviceStateTimer?.cancel();
    _deviceStateTimer = Timer.periodic(
      _deviceStateRefreshInterval,
      (_) => unawaited(_refreshDeviceState()),
    );
  }

  Future<void> _refreshDeviceState() async {
    final state = _state;
    if (!mounted || state == null || _deviceStateRefreshInProgress) return;

    _deviceStateRefreshInProgress = true;
    try {
      if (EfactorCloudService.instance.liveNodes.value.isNotEmpty) {
        state.applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
      }
      await state.refreshDeviceGrid();
    } catch (error) {
      logDebug('[IOT_SDUI][LIVE_STATE] device grid refresh failed: $error');
    } finally {
      _deviceStateRefreshInProgress = false;
    }
  }

  void _subscribeToSchemaInvalidations() {
    _schemaInvalidationSubscription ??= EfactorCloudService
        .instance
        .schemaInvalidations
        .listen(_onSchemaInvalidation);
    _cloudConnectionSubscription ??= EfactorCloudService
        .instance
        .connectionChanges
        .listen(_onCloudConnectionChanged);
  }

  void _onSchemaInvalidation(SchemaInvalidationEvent event) {
    if (!mounted || _state == null) return;

    final currentSchemaId = _schemaId(_state!.schema);
    final matches =
        event.matchesScope('iot') || event.matchesSchemaId(currentSchemaId);
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
          '[IOT_SDUI][SCHEMA_CHANGED] '
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

  IotSchemaRepository _createRepository() {
    return IotSchemaRepository(
      source: widget.source,
      accessToken: widget.accessToken,
    );
  }

  @override
  void didUpdateWidget(covariant DynamicIotSduiPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final sourceChanged =
        oldWidget.source.url != widget.source.url ||
        oldWidget.source.apiBaseUrl != widget.source.apiBaseUrl;

    final tokenChanged = oldWidget.accessToken != widget.accessToken;

    if (sourceChanged || tokenChanged) {
      final oldRepository = _repository;
      _repository = _createRepository();
      oldRepository.dispose();
      _load(forceRefresh: false);
    } else if (oldWidget.schemaRefreshEpoch != widget.schemaRefreshEpoch) {
      _refreshLiveSchema();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_schemaIsStaleForResume) {
        _refreshLiveSchema();
      }
      _startDeviceStatePolling();
      unawaited(_refreshDeviceState());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _deviceStateTimer?.cancel();
      _deviceStateTimer = null;
    }
  }

  bool get _schemaIsStaleForResume {
    final last = _lastSchemaLoadAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= _resumeRefreshAfter;
  }

  String _schemaFingerprint(Map<String, dynamic> schema) {
    return schemaFingerprint(schema);
  }

  Future<void> _refreshLiveSchema({bool forceFull = false}) async {
    if (!mounted || _schemaRefreshInProgress || _state == null) {
      return;
    }

    _schemaRefreshInProgress = true;
    try {
      final result = await _repository.revalidate(forceFull: forceFull);
      if (!mounted) return;

      _lastSchemaLoadAt = DateTime.now();
      if (!result.changed) {
        logDebug(
          '[IOT_SDUI][AUTO_REFRESH] schema unchanged source=${result.source}',
        );
        return;
      }

      final incoming = result.schema;
      final fingerprint = _schemaFingerprint(incoming);
      if (fingerprint == _activeSchemaFingerprint) return;

      logDebug(
        '[IOT_SDUI][AUTO_REFRESH] schema changed '
        'delta=${result.usedDelta} source=${result.source}',
      );
      _activeSchemaFingerprint = fingerprint;
      final patch = await _state!.replaceSchema(incoming);
      if (!mounted) return;
      if (patch.structural) {
        setState(() {
          _renderer = IotSduiRenderer(_state!);
        });
      }
    } catch (error, stackTrace) {
      logDebug('[IOT_SDUI][AUTO_REFRESH_ERROR] $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    } finally {
      _schemaRefreshInProgress = false;
    }
  }

  Future<void> _load({required bool forceRefresh}) async {
    final generation = ++_loadGeneration;

    // Prefer a local schema so returning users never wait on a spinner.
    Map<String, dynamic>? schema;
    if (!forceRefresh) {
      schema = _repository.peekMemory() ??
          await _repository.readFromCache(allowStale: true);
    }

    if (schema == null && mounted && _state == null) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }

    try {
      schema ??= await SchemaLoadQueue.instance.loadIot(
        accessToken: widget.accessToken,
        forceRefresh: forceRefresh,
      );
      if (!mounted || generation != _loadGeneration) return;

      _lastSchemaLoadAt = DateTime.now();
      final fingerprint = _schemaFingerprint(schema);

      if (_state != null) {
        if (fingerprint == _activeSchemaFingerprint && !forceRefresh) {
          setState(() => _loading = false);
          return;
        }
        _activeSchemaFingerprint = fingerprint;
        final patch = await _state!.replaceSchema(schema);
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          if (patch.structural) {
            _renderer = IotSduiRenderer(_state!);
          }
          _loading = false;
          _loadError = null;
        });
        if (schema['_clientIotSchemaCacheHit'] == true) {
          _refreshLiveSchema();
        }
        return;
      }

      _activeSchemaFingerprint = fingerprint;
      final nextState = IotSduiState(
        schema: schema,
        accessToken: widget.accessToken,
        apiBaseUri: widget.source.resolvedApiBaseUri,
      );

      nextState.reloadHandler = () => _load(forceRefresh: true);
      nextState.hostActionHandler = _handleHostAction;
      nextState.deviceOpenHandler =
          ({
            required String modelId,
            required String nodeId,
            required Map<String, dynamic> device,
          }) async {
            final handler = widget.onOpenDevice;
            if (handler == null) {
              throw StateError(
                'No Device SDUI host callback is registered for the IoT page.',
              );
            }

            await handler(
              modelId: modelId,
              nodeId: nodeId,
              online: _asOnlineFlag(device),
            );
            await _refreshAfterDeviceReturn(nextState);
          };

      final nextRenderer = IotSduiRenderer(nextState);

      if (!mounted || generation != _loadGeneration) {
        nextState.dispose();
        return;
      }

      final previous = _state;

      setState(() {
        _state = nextState;
        _renderer = nextRenderer;
        _loading = false;
        _loadError = null;
      });

      previous?.dispose();

      unawaited(() async {
        try {
          await nextState.loadInitialData();
        } catch (error, stackTrace) {
          logDebug('[IOT_SDUI][INITIAL_DATA] $error');
          if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
        }
      }());

      if (schema['_clientIotSchemaCacheHit'] == true && mounted) {
        _refreshLiveSchema();
      }
    } catch (error, stackTrace) {
      final safe = _redact(error.toString());

      logDebug('[IOT_SDUI][LOAD_ERROR] $safe');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _loading = false;
        if (_state == null) {
          _loadError = safe;
        }
      });
    }
  }

  Future<dynamic> _handleHostAction(Map<String, dynamic> action) async {
    final type = (action['action'] ?? action['type'])?.toString().trim();
    final name = action['name']?.toString().trim();

    if (type == 'openOverlay') {
      return _openSchemaOverlay(action);
    }

    if (type == 'navigate') {
      final route = action['route']?.toString().trim();
      if (route == null || route.isEmpty) {
        throw const FormatException('IoT navigate action requires route.');
      }

      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        return null;
      }

      if (mounted) {
        await Navigator.of(context).pushNamed(route);
      }

      return null;
    }

    if (type == 'hostAction' || name != null) {
      if (name == 'back') {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        return null;
      }

      if (name == 'openDevice') {
        final args = action['args'] is Map
            ? Map<String, dynamic>.from(
                (action['args'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};

        final modelId =
            (args['modelId'] ?? action['modelId'])?.toString().trim() ?? '';
        final nodeId =
            (args['nodeId'] ?? action['nodeId'])?.toString().trim() ?? '';

        if (modelId.isEmpty || nodeId.isEmpty) {
          throw const FormatException(
            'IoT openDevice hostAction requires modelId and nodeId.',
          );
        }

        final handler = widget.onOpenDevice;
        if (handler == null) {
          throw StateError(
            'IoT schema requested openDevice but no host callback is registered.',
          );
        }

        await handler(modelId: modelId, nodeId: nodeId);
        final activeState = _state;
        if (activeState != null) {
          await _refreshAfterDeviceReturn(activeState);
        }
        return null;
      }

      if (name == 'openScanner') {
        final formats =
            (action['formats'] as List?)
                ?.map((value) => value.toString())
                .toList(growable: false) ??
            const <String>['qr'];

        final result = await Navigator.of(context).push<Map<String, dynamic>>(
          MaterialPageRoute<Map<String, dynamic>>(
            builder: (_) => ScannerPage(
              formats: formats,
              camera: action['camera']?.toString() ?? 'back',
              qrOnly: action['qrOnly'] != false,
            ),
          ),
        );

        if (result != null) {
          final binding = action['resultBinding']?.toString().trim();
          if (binding != null && binding.isNotEmpty) {
            _state?.writeRuntime(binding, result);
          }
        }

        return result;
      }
    }

    throw FormatException(
      'Unsupported IoT host action: '
      '${action['type'] ?? action['name']}',
    );
  }

  Future<dynamic> _openSchemaOverlay(Map<String, dynamic> action) async {
    final state = _state;
    if (state == null) {
      throw StateError('IoT state is not ready for an overlay action.');
    }

    final overlayId = action['overlayId']?.toString().trim() ?? '';
    if (overlayId.isEmpty) {
      throw const FormatException('openOverlay requires overlayId.');
    }

    final overlays = _asMap(state.schema['overlays']);
    final overlay = _asMap(overlays?[overlayId]);
    if (overlay == null) {
      throw FormatException('IoT schema overlay "$overlayId" is missing.');
    }

    final overlayType = overlay['type']?.toString().trim();
    if (overlayType != 'qrScanner') {
      throw FormatException(
        'Unsupported IoT overlay type "$overlayType" for "$overlayId".',
      );
    }

    return _openQrScannerOverlay(overlayId: overlayId, overlay: overlay);
  }

  Future<dynamic> _openQrScannerOverlay({
    required String overlayId,
    required Map<String, dynamic> overlay,
  }) async {
    final state = _state;
    if (state == null || !mounted) return null;

    final mediaSize = MediaQuery.sizeOf(context);
    final responsive = _asMap(state.schema['responsive']);
    final useSafeViewport = responsive?['safeArea'] == true;
    final safePadding = MediaQuery.viewPaddingOf(context);
    final viewportWidth = useSafeViewport
        ? (mediaSize.width - safePadding.left - safePadding.right)
              .clamp(0.0, double.infinity)
              .toDouble()
        : mediaSize.width;
    final viewportHeight = useSafeViewport
        ? (mediaSize.height - safePadding.top - safePadding.bottom)
              .clamp(0.0, double.infinity)
              .toDouble()
        : mediaSize.height;
    final orientation = viewportWidth > viewportHeight
        ? 'landscape'
        : 'portrait';
    overlay = _resolveResponsiveMapForViewport(
      schema: state.schema,
      source: overlay,
      logicalWidth: viewportWidth,
      logicalHeight: viewportHeight,
      orientation: orientation,
    );

    Map<String, dynamic> responsiveChild(String key) {
      final raw = _asMap(overlay[key]) ?? const <String, dynamic>{};
      return _resolveResponsiveMapForViewport(
        schema: state.schema,
        source: raw,
        logicalWidth: viewportWidth,
        logicalHeight: viewportHeight,
        orientation: orientation,
      );
    }

    final scanner = responsiveChild('scanner');
    final layout = responsiveChild('layout');
    final overlayTheme = responsiveChild('theme');
    final scannerFrame = responsiveChild('scannerFrame');
    final header = responsiveChild('header');
    final hero = responsiveChild('hero');
    overlay = <String, dynamic>{
      ...overlay,
      'scanner': scanner,
      'layout': layout,
      'theme': overlayTheme,
      'scannerFrame': scannerFrame,
      'header': header,
      'hero': hero,
    };

    final maxWidth = _asDouble(layout['maxWidth']);
    final maxHeight = _asDouble(layout['maxHeight']);
    final sheetRadius = _asDouble(layout['sheetRadius']) ?? 0.0;
    final barrierColor = _schemaColor(
      overlayTheme['backdrop'],
      fallback: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.54),
    );

    final result = await showModalBottomSheet<_SchemaScannerFlowResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: barrierColor,
      builder: (sheetContext) {
        final sheetSize = MediaQuery.sizeOf(sheetContext);
        final availableWidth = sheetSize.width;
        final availableHeight = sheetSize.height;
        return Align(
          alignment: _schemaSheetAlignment(layout['align']),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth == null
                  ? availableWidth
                  : maxWidth.clamp(0.0, availableWidth).toDouble(),
              maxHeight: maxHeight == null
                  ? availableHeight
                  : maxHeight.clamp(0.0, availableHeight).toDouble(),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(sheetRadius),
              ),
              child: _SchemaQrScannerSheet(
                overlay: overlay,
                schema: state.schema,
                onProcess: (rawValue, progress, {flowStepIds}) async {
                  final nodeId = _normalizeScannedNodeId(rawValue, scanner);
                  if (nodeId.isEmpty) {
                    return _SchemaScannerFlowResult.failure(
                      overlay['invalidScanMessage']?.toString().trim(),
                    );
                  }

                  final normalize = _asMap(scanner['normalize']);
                  final normalizedField =
                      normalize?['jsonField']?.toString().trim() ?? '';
                  final explicitScanBinding =
                      scanner['resultBinding']?.toString().trim() ??
                      scanner['binding']?.toString().trim();

                  final scanBindings = _runtimeBindingsForField(
                    overlay: overlay,
                    state: state,
                    fieldName: normalizedField,
                    explicitBinding: explicitScanBinding,
                  );

                  if (scanBindings.isEmpty) {
                    return _SchemaScannerFlowResult.failure(
                      'The IoT scanner schema does not declare or reference '
                      'a runtime binding for the normalized scan result.',
                    );
                  }

                  for (final binding in scanBindings) {
                    state.writeRuntime(binding, nodeId);
                  }

                  final rawBinding = scanner['rawResultBinding']
                      ?.toString()
                      .trim();
                  if (rawBinding != null && rawBinding.isNotEmpty) {
                    state.writeRuntime(rawBinding, rawValue);
                  }

                  try {
                    await _captureSchemaLocation(overlay, state);
                  } catch (error) {
                    return _SchemaScannerFlowResult.failure(
                      _redact(error.toString()),
                    );
                  }

                  final flow = overlay['flow'];
                  if (flow is! List) {
                    throw FormatException(
                      'overlays.$overlayId.flow[] is required.',
                    );
                  }

                  Map<String, dynamic>? lastMutationStep;
                  String? lastSourceId;
                  dynamic lastResult;
                  final allowedSteps = flowStepIds
                      ?.map((value) => value.trim())
                      .where((value) => value.isNotEmpty)
                      .toSet();

                  for (final rawStep in flow) {
                    final step = _asMap(rawStep);
                    if (step == null) continue;

                    final stepId =
                        step['step']?.toString().trim() ??
                        step['id']?.toString().trim();
                    if (allowedSteps != null &&
                        allowedSteps.isNotEmpty &&
                        (stepId == null ||
                            stepId.isEmpty ||
                            !allowedSteps.contains(stepId))) {
                      continue;
                    }
                    final statusMessage = step['statusMessage']
                        ?.toString()
                        .trim();

                    progress(
                      stepId,
                      statusMessage,
                      _SchemaScannerPhase.processing,
                    );

                    final sourceId =
                        step['dataSource']?.toString().trim() ?? '';
                    if (sourceId.isEmpty) {
                      continue;
                    }

                    lastResult = await state.callDataSource(sourceId);
                    final failure = state.lastError;
                    if (failure != null && failure.trim().isNotEmpty) {
                      progress(stepId, failure, _SchemaScannerPhase.error);
                      return _SchemaScannerFlowResult.failure(failure);
                    }

                    lastMutationStep = step;
                    lastSourceId = sourceId;
                  }

                  final mutationSource = lastSourceId == null
                      ? null
                      : _asMap(state.dataSources[lastSourceId]);
                  final refreshAfter =
                      lastMutationStep?['refreshAfter'] ??
                      mutationSource?['refreshAfter'];

                  if (refreshAfter is List) {
                    final refreshError = await _refreshAfterScannerAdd(
                      state,
                      refreshAfter,
                    );
                    if (refreshError != null) {
                      progress(
                        lastMutationStep?['step']?.toString().trim(),
                        refreshError,
                        _SchemaScannerPhase.error,
                      );
                      return _SchemaScannerFlowResult.failure(refreshError);
                    }
                  }

                  final visible = _verifyAddedDeviceVisible(
                    state: state,
                    mutationSourceId: lastSourceId,
                    mutationResult: lastResult,
                    scannedNodeId: nodeId,
                  );

                  if (visible == false) {
                    final configuredMessage =
                        lastMutationStep?['notVisibleMessage']
                            ?.toString()
                            .trim();
                    final diagnostic =
                        configuredMessage != null &&
                            configuredMessage.isNotEmpty
                        ? configuredMessage
                        : 'The add-device API completed, but the refreshed '
                              'device datasource did not return the added device.';

                    logDebug(
                      '[IOT_SDUI][ADD_DEVICE][VERIFY] '
                      'mutationCompleted=true '
                      'visibleAfterRefresh=false '
                      'deviceCount=${state.devices.length}',
                    );
                    progress(
                      lastMutationStep?['step']?.toString().trim(),
                      diagnostic,
                      _SchemaScannerPhase.error,
                    );
                    return _SchemaScannerFlowResult.failure(diagnostic);
                  }

                  final successMessage = lastMutationStep?['successMessage']
                      ?.toString()
                      .trim();
                  final closeDelayMs =
                      (lastMutationStep?['closeDelayMs'] as num?)?.toInt() ?? 0;

                  progress(
                    lastMutationStep?['step']?.toString().trim(),
                    successMessage,
                    _SchemaScannerPhase.success,
                  );

                  return _SchemaScannerFlowResult.success(
                    value: lastResult,
                    message: successMessage,
                    closeDelay: Duration(
                      milliseconds: closeDelayMs < 0 ? 0 : closeDelayMs,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );

    if (result == null || !result.success) return null;

    final message = result.message?.trim() ?? '';
    if (message.isNotEmpty) {
      _showIotMessage(message);
    }

    return result.value;
  }

  bool? _verifyAddedDeviceVisible({
    required IotSduiState state,
    required String? mutationSourceId,
    required dynamic mutationResult,
    required String scannedNodeId,
  }) {
    final gridSourceId = state.deviceGrid?['dataSource']?.toString().trim();
    if (gridSourceId == null || gridSourceId.isEmpty) {
      return null;
    }

    final gridSource = _asMap(state.dataSources[gridSourceId]);
    final gridResponse = _asMap(gridSource?['response']);
    final controlField =
        gridResponse?['controlIdField']?.toString().trim() ??
        gridResponse?['idField']?.toString().trim();

    if (controlField == null || controlField.isEmpty) {
      return null;
    }

    var expectedId = scannedNodeId.trim();

    if (mutationSourceId != null && mutationSourceId.isNotEmpty) {
      final mutationSource = _asMap(state.dataSources[mutationSourceId]);
      final mutationResponse = _asMap(mutationSource?['response']);
      final responseNodeField = mutationResponse?['nodeIdField']
          ?.toString()
          .trim();

      if (responseNodeField != null &&
          responseNodeField.isNotEmpty &&
          mutationResult is Map) {
        final returned = _readMapPath(
          Map<String, dynamic>.from(mutationResult.cast<dynamic, dynamic>()),
          responseNodeField,
        )?.toString().trim();

        if (returned != null && returned.isNotEmpty) {
          expectedId = returned;
        }
      }
    }

    if (expectedId.isEmpty) return null;

    for (final device in state.devices) {
      final candidate =
          _readMapPath(device, controlField)?.toString().trim() ?? '';
      if (candidate == expectedId) {
        logDebug(
          '[IOT_SDUI][ADD_DEVICE][VERIFY] '
          'mutationCompleted=true '
          'visibleAfterRefresh=true '
          'controlField=$controlField '
          'deviceCount=${state.devices.length}',
        );
        return true;
      }
    }

    logDebug(
      '[IOT_SDUI][ADD_DEVICE][VERIFY_DETAIL] '
      'controlField=$controlField '
      'deviceCount=${state.devices.length} '
      'expectedSource=${expectedId == scannedNodeId.trim() ? 'scan' : 'mutationResponse'}',
    );
    return false;
  }

  List<String> _runtimeBindingsForField({
    required Map<String, dynamic> overlay,
    required IotSduiState state,
    required String fieldName,
    String? explicitBinding,
  }) {
    final bindings = <String>{};

    final explicit = explicitBinding?.trim() ?? '';
    if (explicit.isNotEmpty) {
      bindings.add(explicit);
    }

    final normalizedField = fieldName.trim();
    if (normalizedField.isEmpty) {
      return bindings.toList(growable: false);
    }

    final flow = overlay['flow'];
    if (flow is! List) {
      return bindings.toList(growable: false);
    }

    for (final rawStep in flow) {
      final step = _asMap(rawStep);
      final sourceId = step?['dataSource']?.toString().trim() ?? '';
      if (sourceId.isEmpty) continue;

      final source = _asMap(state.dataSources[sourceId]);
      if (source == null) continue;

      _collectTemplateBindings(
        source,
        fieldName: normalizedField,
        out: bindings,
      );
    }

    return bindings.toList(growable: false);
  }

  void _collectTemplateBindings(
    dynamic value, {
    required String fieldName,
    required Set<String> out,
  }) {
    if (value is Map) {
      for (final child in value.values) {
        _collectTemplateBindings(child, fieldName: fieldName, out: out);
      }
      return;
    }

    if (value is List) {
      for (final child in value) {
        _collectTemplateBindings(child, fieldName: fieldName, out: out);
      }
      return;
    }

    if (value is! String || !value.contains('{{')) {
      return;
    }

    final expressionPattern = RegExp(r'\{\{\s*([^}]+?)\s*\}\}');
    for (final match in expressionPattern.allMatches(value)) {
      var path = match.group(1)?.trim() ?? '';
      if (path.isEmpty) continue;

      final pipe = path.indexOf('|');
      if (pipe >= 0) {
        path = path.substring(0, pipe).trim();
      }

      if (path.isEmpty) continue;
      final segments = path.split('.');
      if (segments.isNotEmpty && segments.last == fieldName) {
        out.add(path);
      }
    }
  }

  dynamic _readMapPath(Map<String, dynamic> root, String path) {
    dynamic current = root;
    for (final segment in path.split('.')) {
      if (segment.isEmpty) continue;
      if (current is! Map || !current.containsKey(segment)) {
        return null;
      }
      current = current[segment];
    }
    return current;
  }

  String _normalizeScannedNodeId(
    String rawValue,
    Map<String, dynamic> scanner,
  ) {
    final normalize = _asMap(scanner['normalize']);
    var value = rawValue;
    if (normalize?['trim'] != false) value = value.trim();
    if (value.isEmpty) return '';

    final jsonField = normalize?['jsonField']?.toString().trim() ?? '';
    if (jsonField.isEmpty) return value;

    try {
      final decoded = jsonDecode(value);
      dynamic current = decoded;
      for (final part in jsonField.split('.')) {
        if (current is! Map || !current.containsKey(part)) {
          return '';
        }
        current = current[part];
      }
      return current?.toString().trim() ?? '';
    } on FormatException {
      // A plain QR payload remains valid when the code itself is the node id.
      return value;
    }
  }

  Future<void> _captureSchemaLocation(
    Map<String, dynamic> overlay,
    IotSduiState state,
  ) async {
    final location = _asMap(overlay['location']);
    if (location == null || location['provider']?.toString() != 'geolocation') {
      return;
    }

    final required = location['required'] == true;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        if (required) {
          throw StateError('Location services are required by the IoT schema.');
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && required) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (required) {
          throw StateError(
            'Location permission is required by the IoT schema.',
          );
        }
        return;
      }

      final options = _asMap(location['options']) ?? const <String, dynamic>{};
      final timeoutMs = (options['timeout'] as num?)?.toInt();
      final highAccuracy = options['enableHighAccuracy'] == true;
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: highAccuracy
            ? LocationAccuracy.high
            : LocationAccuracy.medium,
        timeLimit: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
      );

      final fields =
          (location['fields'] as List?)
              ?.map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toSet() ??
          const <String>{};

      final explicitBindings =
          _asMap(location['bindings']) ?? const <String, dynamic>{};

      final providerValues = <String, dynamic>{
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'heading': position.heading,
        'speed': position.speed,
      };

      for (final field in fields) {
        if (!providerValues.containsKey(field)) continue;

        final bindings = _runtimeBindingsForField(
          overlay: overlay,
          state: state,
          fieldName: field,
          explicitBinding: explicitBindings[field]?.toString(),
        );

        for (final binding in bindings) {
          state.writeRuntime(binding, providerValues[field]);
        }
      }
    } catch (error) {
      if (required) rethrow;
      logDebug(
        '[IOT_SDUI][SCANNER_LOCATION] optional location unavailable: $error',
      );
    }
  }

  Future<void> _refreshAfterDeviceReturn(IotSduiState state) async {
    if (!mounted || !identical(_state, state)) return;

    // The Device route may have changed server-side membership (for example a
    // schema-declared removeDevice action). Refresh only the datasource IDs
    // declared by the current IoT schema; no endpoint/action is hardcoded here.
    final grid = state.deviceGrid;
    final devicesSourceId = grid?['dataSource']?.toString().trim();
    final liveStatusId = grid?['liveStatusSource']?.toString().trim();

    if (devicesSourceId != null && devicesSourceId.isNotEmpty) {
      await state.callDataSource(devicesSourceId, reportError: false);
    }

    if (liveStatusId != null &&
        liveStatusId.isNotEmpty &&
        liveStatusId != devicesSourceId) {
      unawaited(state.callDataSource(liveStatusId, reportError: false));
    }

    // Also revalidate the IoT schema itself in case device-count/summary or
    // server-declared presentation changed after the Device route closed.
    unawaited(_refreshLiveSchema());
  }

  Future<String?> _refreshAfterScannerAdd(
    IotSduiState state,
    List<dynamic> rawIds,
  ) async {
    final ids = rawIds
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

    final liveStatusId = state.deviceGrid?['liveStatusSource']
        ?.toString()
        .trim();

    for (final sourceId in ids) {
      final source = _asMap(state.dataSources[sourceId]);
      final response = _asMap(source?['response']);
      final returnsSchema = response?['root']?.toString().trim() == 'schema';

      if (returnsSchema) {
        unawaited(_refreshLiveSchema());
        continue;
      }

      if (sourceId == liveStatusId) {
        unawaited(state.callDataSource(sourceId, reportError: false));
        continue;
      }

      await state.callDataSource(sourceId);
      logDebug(
        '[IOT_SDUI][ADD_DEVICE][REFRESH] '
        'source=$sourceId deviceCount=${state.devices.length}',
      );
      final failure = state.lastError;
      if (failure != null && failure.trim().isNotEmpty) {
        return failure;
      }
    }

    return null;
  }

  void _showIotMessage(String message, {bool error = false}) {
    if (!mounted || message.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 5 : 3),
      ),
    );
  }

  Map<String, dynamic> _resolveResponsiveMapForViewport({
    required Map<String, dynamic> schema,
    required Map<String, dynamic> source,
    required double logicalWidth,
    required double logicalHeight,
    required String orientation,
  }) {
    final breakpoint = _resolveResponsiveBreakpointName(
      schema,
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      orientation: orientation,
    );
    if (breakpoint == null) {
      return Map<String, dynamic>.from(source);
    }

    var result = Map<String, dynamic>.from(source);
    for (final key in const <String>[
      'responsiveLayout',
      'responsiveOverrides',
    ]) {
      final overrides = _asMap(source[key]);
      if (overrides == null) continue;

      final common = _asMap(overrides['all']);
      if (common != null) {
        result = _deepMergeResponsive(result, common);
      }

      final selected = _asMap(overrides[breakpoint]);
      if (selected == null) continue;
      result = _deepMergeResponsive(result, selected);

      final orientationOverride = _asMap(
        selected[orientation.trim().toLowerCase()],
      );
      if (orientationOverride != null) {
        result = _deepMergeResponsive(result, orientationOverride);
      }
    }

    return result;
  }

  String? _resolveResponsiveBreakpointName(
    Map<String, dynamic> schema, {
    required double logicalWidth,
    required double logicalHeight,
    required String orientation,
  }) {
    Map<String, dynamic>? responsive = _asMap(schema['responsive']);

    if (responsive == null) {
      final extensions = _asMap(schema['extensions']);
      final universalUi = _asMap(extensions?['universalUi']);
      responsive = _asMap(universalUi?['responsive']);

      if (responsive == null) {
        final serverDrivenUi = _asMap(extensions?['serverDrivenUi']);
        responsive = _asMap(serverDrivenUi?['responsive']);
      }
    }

    final breakpoints = _asMap(responsive?['breakpoints']);
    if (breakpoints == null || breakpoints.isEmpty) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final entry in breakpoints.entries) {
      final name = entry.key.trim();
      if (name.isEmpty) continue;

      final raw = entry.value;
      if (raw is num) {
        candidates.add(<String, dynamic>{
          'name': name,
          'minWidth': raw.toDouble(),
          'maxWidth': double.infinity,
          'minHeight': 0.0,
          'maxHeight': double.infinity,
          'orientation': null,
        });
        continue;
      }

      final config = _asMap(raw);
      if (config == null) continue;
      final requiredOrientation = config['orientation']?.toString().trim();
      candidates.add(<String, dynamic>{
        'name': name,
        'minWidth':
            _responsiveNumber(
              config['minimumWidth'] ?? config['minWidth'] ?? config['from'],
            ) ??
            0.0,
        'maxWidth':
            _responsiveNumber(
              config['maximumWidth'] ?? config['maxWidth'] ?? config['to'],
            ) ??
            double.infinity,
        'minHeight':
            _responsiveNumber(config['minimumHeight'] ?? config['minHeight']) ??
            0.0,
        'maxHeight':
            _responsiveNumber(config['maximumHeight'] ?? config['maxHeight']) ??
            double.infinity,
        'orientation':
            requiredOrientation == null ||
                requiredOrientation.isEmpty ||
                requiredOrientation.toLowerCase() == 'any'
            ? null
            : requiredOrientation.toLowerCase(),
      });
    }

    if (candidates.isEmpty) return null;
    final currentOrientation = orientation.trim().toLowerCase();

    final matches = candidates
        .where((candidate) {
          final requiredOrientation = candidate['orientation'] as String?;
          return (requiredOrientation == null ||
                  requiredOrientation == currentOrientation) &&
              logicalWidth >= (candidate['minWidth'] as double) &&
              logicalWidth <= (candidate['maxWidth'] as double) &&
              logicalHeight >= (candidate['minHeight'] as double) &&
              logicalHeight <= (candidate['maxHeight'] as double);
        })
        .toList(growable: false);

    if (matches.isNotEmpty) {
      final sorted = List<Map<String, dynamic>>.from(matches)
        ..sort(
          (a, b) =>
              (b['minWidth'] as double).compareTo(a['minWidth'] as double),
        );
      return sorted.first['name']?.toString();
    }

    final eligible =
        candidates
            .where(
              (candidate) => logicalWidth >= (candidate['minWidth'] as double),
            )
            .toList(growable: false)
          ..sort(
            (a, b) =>
                (b['minWidth'] as double).compareTo(a['minWidth'] as double),
          );

    return (eligible.isEmpty ? candidates.first : eligible.first)['name']
        ?.toString();
  }

  Map<String, dynamic> _deepMergeResponsive(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final entry in overlay.entries) {
      final current = _asMap(result[entry.key]);
      final incoming = _asMap(entry.value);
      if (current != null && incoming != null) {
        result[entry.key] = _deepMergeResponsive(current, incoming);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  double? _responsiveNumber(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  String _redact(String text) {
    final pattern = RegExp(
      r'([?&][^=&\s]*token[^=]*=)[^&\s]+',
      caseSensitive: false,
    );
    return text.replaceAllMapped(
      pattern,
      (match) => '${match.group(1)}<redacted>',
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _schemaEventDebounceTimer?.cancel();
    _deviceStateTimer?.cancel();
    _nodeStatusSubscription?.cancel();
    _schemaInvalidationSubscription?.cancel();
    _cloudConnectionSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _state?.dispose();
    _repository.dispose();
    super.dispose();
  }

  bool? _asOnlineFlag(Map<String, dynamic> device) {
    final online = device['online'];
    if (online is bool) return online;
    if (online is num) return online != 0;
    final text = (online ?? device['status'])?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'online' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'offline' || text == 'off') {
      return false;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _state == null) {
      return _hostSurface(
        child: const Center(
          child: EfactorDeviceLoader(
            size: 80,
            statusText: 'Loading devices...',
          ),
        ),
      );
    }

    if (_loadError != null && _state == null) {
      return _hostSurface(
        child: SchemaPullToRefresh(
          fillViewport: true,
          onRefresh: () => _load(forceRefresh: true),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.cloud_off_outlined, size: 44),
                  const SizedBox(height: 12),
                  const Text(
                    'Live IoT schema could not be loaded',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
                  ),
                  const SizedBox(height: 10),
                  Text(_loadError!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _load(forceRefresh: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry live schema'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final state = _state!;
    final renderer = _renderer!;

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return _hostSurface(
          background: _parseColor(state.theme['background']),
          child: renderer.build(context),
        );
      },
    );
  }

  Widget _hostSurface({required Widget child, Color? background}) {
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

    if (widget.embedInHostShell) {
      return ColoredBox(
        color: background ?? Colors.transparent,
        child: clampedChild,
      );
    }

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(child: clampedChild),
    );
  }

  Color? _parseColor(dynamic value) {
    final raw = value?.toString().trim();
    if (raw == null || !raw.startsWith('#')) return null;

    var hex = raw.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;

    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }
}

enum _SchemaScannerPhase { idle, processing, error, success }

typedef _SchemaScannerProgress =
    void Function(String? stepId, String? message, _SchemaScannerPhase phase);

typedef _SchemaScannerProcessor =
    Future<_SchemaScannerFlowResult> Function(
      String rawValue,
      _SchemaScannerProgress progress, {
      List<String>? flowStepIds,
    });

class _SchemaScannerFlowResult {
  const _SchemaScannerFlowResult._({
    required this.success,
    this.value,
    this.message,
    this.closeDelay = Duration.zero,
  });

  factory _SchemaScannerFlowResult.success({
    dynamic value,
    String? message,
    Duration closeDelay = Duration.zero,
  }) {
    return _SchemaScannerFlowResult._(
      success: true,
      value: value,
      message: message,
      closeDelay: closeDelay,
    );
  }

  factory _SchemaScannerFlowResult.failure(String? message) {
    return _SchemaScannerFlowResult._(success: false, message: message);
  }

  final bool success;
  final dynamic value;
  final String? message;
  final Duration closeDelay;
}

class _SchemaQrScannerSheet extends StatefulWidget {
  const _SchemaQrScannerSheet({
    required this.overlay,
    required this.schema,
    required this.onProcess,
  });

  final Map<String, dynamic> overlay;
  final Map<String, dynamic> schema;
  final _SchemaScannerProcessor onProcess;

  @override
  State<_SchemaQrScannerSheet> createState() => _SchemaQrScannerSheetState();
}

class _SchemaQrScannerSheetState extends State<_SchemaQrScannerSheet>
    with SingleTickerProviderStateMixin {
  late final MobileScannerController _controller;
  late final AnimationController _scanLineController;

  bool _permissionDenied = false;
  bool _handlingCode = false;
  // Prevent the camera from immediately replaying the same failed QR while it
  // remains inside the frame. A different QR can still be scanned immediately;
  // retrying the same device is available by closing/reopening the scanner.
  String? _failedRawValue;
  String? _activeStepId;
  String? _statusMessage;
  _SchemaScannerPhase _phase = _SchemaScannerPhase.idle;
  final Set<String> _completedSteps = <String>{};

  Map<String, dynamic> get _scanner =>
      _schemaMap(widget.overlay['scanner']) ?? const <String, dynamic>{};

  Map<String, dynamic> get _scannerFrame =>
      _schemaMap(widget.overlay['scannerFrame']) ?? const <String, dynamic>{};

  Map<String, dynamic>? get _scanLineConfig =>
      _schemaMap(_scannerFrame['scanLine']);

  bool get _scanLineEnabled {
    final raw = _scannerFrame['scanLine'];
    if (raw is bool) return raw;

    final config = _scanLineConfig;
    if (config == null) return false;
    return config['enabled'] != false;
  }

  bool get _scanLineAnimated {
    if (!_scanLineEnabled) return false;
    return _scanLineConfig?['animated'] != false;
  }

  Duration get _scanLineDuration {
    final configuredMs =
        _schemaDouble(_scanLineConfig?['durationMs']) ??
        _schemaDouble(_scannerFrame['scanLineDurationMs']);
    final milliseconds = configuredMs?.round();

    // `scanLine: true` is the backward-compatible SDUI contract. Its renderer
    // semantics are an animated scanning indicator. Backend can publish
    // scanLine.durationMs when exact timing needs to be controlled by schema.
    return Duration(
      milliseconds: milliseconds != null && milliseconds > 0
          ? milliseconds
          : 1800,
    );
  }

  bool get _scanLineReverse => _scanLineConfig?['reverse'] != false;

  double get _scanLineOpacity {
    final configured =
        _schemaDouble(_scanLineConfig?['opacity']) ??
        _schemaDouble(_scannerFrame['scanLineOpacity']);
    return (configured ?? 0.70).clamp(0.0, 1.0).toDouble();
  }

  double? get _scanLineThickness {
    final configured =
        _schemaDouble(_scanLineConfig?['thickness']) ??
        _schemaDouble(_scannerFrame['scanLineThickness']);
    return configured != null && configured > 0 ? configured : null;
  }

  List<Map<String, dynamic>> get _flow =>
      _schemaMapList(widget.overlay['flow']);

  @override
  void initState() {
    super.initState();

    final facingMode = _scanner['facingMode']?.toString().trim().toLowerCase();
    _controller = MobileScannerController(
      facing: facingMode == 'user' || facingMode == 'front'
          ? CameraFacing.front
          : CameraFacing.back,
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.normal,
    );

    _scanLineController = AnimationController(
      vsync: this,
      duration: _scanLineDuration,
    );

    if (_scanLineEnabled) {
      if (_scanLineAnimated) {
        _scanLineController.repeat(reverse: _scanLineReverse);
      } else {
        _scanLineController.value = 0.5;
      }
    }

    if (_flow.isNotEmpty) {
      _activeStepId =
          _flow.first['step']?.toString().trim() ??
          _flow.first['id']?.toString().trim();
      _statusMessage = _flow.first['statusMessage']?.toString().trim();
    }

    _ensurePermission();
  }

  Future<void> _ensurePermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _permissionDenied = true);
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handlingCode) return;

    Barcode? qr;
    for (final barcode in capture.barcodes) {
      if (barcode.format == BarcodeFormat.qrCode) {
        qr = barcode;
        break;
      }
    }

    final rawValue = qr?.rawValue?.trim();
    if (rawValue == null || rawValue.isEmpty) return;

    // A failed mutation must not be replayed automatically simply because the
    // same QR is still visible to the camera. This is especially important for
    // add-device mutations, where the server may have partially committed an
    // operation before returning an error.
    if (_failedRawValue == rawValue) return;

    _handlingCode = true;

    final result = await widget.onProcess(rawValue, _applyProgress);

    if (!mounted) return;

    if (result.success) {
      if (result.closeDelay.inMilliseconds > 0) {
        await Future<void>.delayed(result.closeDelay);
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
      return;
    }

    setState(() {
      _failedRawValue = rawValue;
      _handlingCode = false;
      _phase = _SchemaScannerPhase.error;
      final message = result.message?.trim();
      if (message != null && message.isNotEmpty) {
        _statusMessage = message;
      }
    });
  }

  void _applyProgress(
    String? stepId,
    String? message,
    _SchemaScannerPhase phase,
  ) {
    if (!mounted) return;

    setState(() {
      if (stepId != null && stepId.isNotEmpty) {
        final previous = _activeStepId;
        if (previous != null &&
            previous.isNotEmpty &&
            previous != stepId &&
            phase != _SchemaScannerPhase.error) {
          _completedSteps.add(previous);
        }
        _activeStepId = stepId;
      }

      final text = message?.trim();
      if (text != null && text.isNotEmpty) {
        _statusMessage = text;
      }

      _phase = phase;

      if (phase == _SchemaScannerPhase.success) {
        for (final step in _schemaMapList(widget.overlay['steps'])) {
          final id = step['id']?.toString().trim();
          if (id != null && id.isNotEmpty) {
            _completedSteps.add(id);
          }
        }
      }
    });
  }

  Future<void> _handleHeaderAction(Map<String, dynamic> action) async {
    final onTap = _schemaMap(action['onTap']) ?? action;
    final type = (onTap['action'] ?? onTap['type'])?.toString().trim();
    if (type == 'openPrompt') {
      await _openSchemaPrompt(onTap);
    }
  }

  Future<void> _openSchemaPrompt(Map<String, dynamic> action) async {
    if (_handlingCode || !mounted) return;

    final promptId = action['promptId']?.toString().trim() ?? '';
    final prompt = _resolveOverlayPrompt(
      overlay: widget.overlay,
      schema: widget.schema,
      promptId: promptId,
    );
    if (prompt == null) return;

    _handlingCode = true;
    try {
      await _controller.stop();
    } catch (_) {}

    if (!mounted) {
      _handlingCode = false;
      return;
    }

    final submitted = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _SchemaOverlayPromptDialog(
          prompt: prompt,
          overlay: widget.overlay,
        );
      },
    );

    if (!mounted) return;

    if (submitted == null || submitted.trim().isEmpty) {
      _handlingCode = false;
      try {
        await _controller.start();
      } catch (_) {}
      return;
    }

    final statusMessage = prompt['statusMessage']?.toString().trim();
    if (statusMessage != null && statusMessage.isNotEmpty) {
      _applyProgress(
        _activeStepId,
        statusMessage,
        _SchemaScannerPhase.processing,
      );
    }

    final connectAction = _promptPrimarySubmitAction(prompt);
    final flow = connectAction?['flow'];
    final flowStepIds = flow is List
        ? flow.map((value) => value.toString()).toList(growable: false)
        : const <String>[];

    final result = await widget.onProcess(
      submitted.trim(),
      _applyProgress,
      flowStepIds: flowStepIds,
    );

    if (!mounted) return;

    if (result.success) {
      if (result.closeDelay.inMilliseconds > 0) {
        await Future<void>.delayed(result.closeDelay);
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
      return;
    }

    setState(() {
      _handlingCode = false;
      _phase = _SchemaScannerPhase.error;
      final message = result.message?.trim();
      if (message != null && message.isNotEmpty) {
        _statusMessage = message;
      }
    });
    try {
      await _controller.start();
    } catch (_) {}
  }

  Widget _buildHeaderActionButton({
    required BuildContext context,
    required Map<String, dynamic> action,
    required Color accent,
  }) {
    final materialTheme = Theme.of(context);
    final style = _schemaMap(action['style']) ?? const <String, dynamic>{};
    final label =
        action['label']?.toString().trim() ??
        action['title']?.toString().trim() ??
        '';
    final iconName = action['icon']?.toString().trim() ?? '';
    final semanticLabel =
        action['ariaLabel']?.toString().trim() ??
        action['title']?.toString().trim() ??
        label;
    final icons = IotSchemaIcon(widget.schema);
    final iconSize = _schemaDouble(style['iconSize']) ??
        _schemaDouble(style['width']) ??
        18;
    final iconColor =
        _schemaColor(style['color']) ??
        _schemaColor(style['iconColor']) ??
        accent;
    final background = _schemaColor(style['background']);
    final radius = _schemaDouble(style['borderRadius']);

    Widget? icon;
    if (iconName.isNotEmpty) {
      icon = icons.buildNamed(
        context,
        name: iconName,
        width: iconSize,
        height: iconSize,
        color: iconColor,
        semanticLabel: semanticLabel,
      );
    }

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) icon,
        if (icon != null && label.isNotEmpty) const SizedBox(width: 6),
        if (label.isNotEmpty)
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: materialTheme.textTheme.labelMedium?.copyWith(
              color: iconColor,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );

    final hasChrome = background != null || radius != null;

    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: background ?? Colors.transparent,
        borderRadius: radius == null ? null : BorderRadius.circular(radius),
        child: InkWell(
          onTap: () => _handleHeaderAction(action),
          borderRadius: radius == null ? null : BorderRadius.circular(radius),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: hasChrome ? 10 : 8,
              vertical: hasChrome ? 8 : 6,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scanLineController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final materialTheme = Theme.of(context);
    final overlayTheme =
        _schemaMap(widget.overlay['theme']) ?? const <String, dynamic>{};
    final layout =
        _schemaMap(widget.overlay['layout']) ?? const <String, dynamic>{};
    final header =
        _schemaMap(widget.overlay['header']) ?? const <String, dynamic>{};
    final hero =
        _schemaMap(widget.overlay['hero']) ?? const <String, dynamic>{};
    final scannerFrame =
        _schemaMap(widget.overlay['scannerFrame']) ?? const <String, dynamic>{};

    final accent = _schemaColor(
      overlayTheme['accent'],
      fallback: materialTheme.colorScheme.primary,
    )!;
    final scannerBg = _schemaColor(
      overlayTheme['scannerBg'],
      fallback: materialTheme.colorScheme.inverseSurface,
    )!;
    final frameAccent = _schemaColor(
      overlayTheme['frameAccent'],
      fallback: accent,
    )!;
    final surface = materialTheme.colorScheme.surface;

    final sheetRadius = _schemaDouble(layout['sheetRadius']) ?? 0.0;
    final scannerMinHeight = _schemaDouble(layout['scannerMinHeight']) ?? 0.0;
    final frameRadius = _schemaDouble(scannerFrame['cornerRadius']) ?? 0.0;
    final cornerSize = _schemaDouble(scannerFrame['cornerSize']) ?? 0.0;
    final cornerBorder = _schemaDouble(scannerFrame['cornerBorder']) ?? 0.0;
    final frameAspectRatio =
        _schemaAspectRatio(scannerFrame['aspectRatio']) ?? 1.0;

    final headerTitle = header['title']?.toString().trim() ?? '';
    final closeIconName = header['closeIcon']?.toString().trim();
    final rightAction = _schemaMap(header['rightAction']);
    final heroKicker = hero['kicker']?.toString().trim() ?? '';
    final heroSubtitle = hero['subtitle']?.toString().trim() ?? '';
    final heroIconName = hero['icon']?.toString().trim();

    final heroGradient = _schemaGradient(overlayTheme['heroGradient']);
    final steps = _schemaMapList(widget.overlay['steps']);
    final actions = _schemaMapList(widget.overlay['actions']);

    Map<String, dynamic>? closeAction;
    for (final action in actions) {
      final onTap = _schemaMap(action['onTap']);
      if ((onTap?['action'] ?? onTap?['type'])?.toString() == 'closeOverlay') {
        closeAction = action;
        break;
      }
    }

    return Material(
      color: surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(sheetRadius)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (headerTitle.isNotEmpty ||
                  closeIconName != null ||
                  rightAction != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: <Widget>[
                      if (closeIconName != null && closeIconName.isNotEmpty)
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(_schemaIcon(closeIconName)),
                        )
                      else
                        const SizedBox(width: 48),
                      Expanded(
                        child: Text(
                          headerTitle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: materialTheme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (rightAction != null)
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _buildHeaderActionButton(
                              context: context,
                              action: rightAction,
                              accent: accent,
                            ),
                          ),
                        )
                      else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
              if (heroKicker.isNotEmpty ||
                  heroSubtitle.isNotEmpty ||
                  heroIconName != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: heroGradient == null
                          ? materialTheme.colorScheme.surfaceContainerLow
                          : null,
                      gradient: heroGradient,
                      borderRadius: BorderRadius.circular(
                        sheetRadius > 0 ? sheetRadius / 2 : 0,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: <Widget>[
                          if (heroIconName != null &&
                              heroIconName.isNotEmpty) ...[
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(
                                  sheetRadius > 0 ? sheetRadius / 2 : 0,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Icon(
                                  _schemaIcon(heroIconName),
                                  color: materialTheme.colorScheme.onPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (heroKicker.isNotEmpty)
                                  Text(
                                    heroKicker,
                                    style: materialTheme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: accent,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                if (heroSubtitle.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    heroSubtitle,
                                    style: materialTheme.textTheme.bodySmall
                                        ?.copyWith(
                                          color: materialTheme
                                              .colorScheme
                                              .onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Container(
                  constraints: BoxConstraints(minHeight: scannerMinHeight),
                  decoration: BoxDecoration(
                    color: scannerBg,
                    borderRadius: BorderRadius.circular(frameRadius),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _permissionDenied
                      ? Center(
                          child: Text(
                            widget.overlay['permissionDeniedMessage']
                                    ?.toString()
                                    .trim() ??
                                '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: materialTheme.colorScheme.onInverseSurface,
                            ),
                          ),
                        )
                      : AspectRatio(
                          aspectRatio: frameAspectRatio,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final qrbox =
                                  _schemaMap(_scanner['qrbox']) ??
                                  const <String, dynamic>{};
                              final requestedWidth =
                                  _schemaDouble(qrbox['width']) ??
                                  constraints.maxWidth;
                              final requestedHeight =
                                  _schemaDouble(qrbox['height']) ??
                                  requestedWidth;

                              final frameWidth = requestedWidth
                                  .clamp(1.0, constraints.maxWidth)
                                  .toDouble();
                              final frameHeight = requestedHeight
                                  .clamp(1.0, constraints.maxHeight)
                                  .toDouble();

                              return Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  MobileScanner(
                                    controller: _controller,
                                    onDetect: _onDetect,
                                    errorBuilder: (context, error) {
                                      return Center(
                                        child: Text(
                                          error.errorDetails?.message ??
                                              error.toString(),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: materialTheme
                                                .colorScheme
                                                .onInverseSurface,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  if (scannerFrame['vignette'] == true)
                                    IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: RadialGradient(
                                            radius: 0.95,
                                            colors: <Color>[
                                              Colors.transparent,
                                              scannerBg.withValues(alpha: 0.72),
                                            ],
                                            stops: const <double>[0.55, 1.0],
                                          ),
                                        ),
                                      ),
                                    ),
                                  IgnorePointer(
                                    child: Center(
                                      child: SizedBox(
                                        width: frameWidth,
                                        height: frameHeight,
                                        child: AnimatedBuilder(
                                          animation: _scanLineController,
                                          builder: (context, child) {
                                            return CustomPaint(
                                              painter: _SchemaScannerFramePainter(
                                                color: frameAccent,
                                                cornerSize: cornerSize,
                                                borderWidth: cornerBorder,
                                                drawScanLine: _scanLineEnabled,
                                                scanLineProgress:
                                                    _scanLineEnabled
                                                    ? (_scanLineAnimated
                                                          ? _scanLineController
                                                                .value
                                                          : 0.5)
                                                    : 0.5,
                                                scanLineOpacity:
                                                    _scanLineOpacity,
                                                scanLineThickness:
                                                    _scanLineThickness,
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                ),
              ),
              if (steps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Row(
                    children: <Widget>[
                      for (var index = 0; index < steps.length; index++) ...[
                        if (index > 0) const SizedBox(width: 8),
                        Expanded(
                          child: _buildStep(context, steps[index], accent),
                        ),
                      ],
                    ],
                  ),
                ),
              if ((_statusMessage ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _phase == _SchemaScannerPhase.error
                          ? materialTheme.colorScheme.errorContainer
                          : materialTheme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(
                        sheetRadius > 0 ? sheetRadius / 2 : 0,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: <Widget>[
                          if (_schemaMap(
                                widget.overlay['statusPill'],
                              )?['showDot'] ==
                              true) ...[
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: _phase == _SchemaScannerPhase.error
                                    ? materialTheme.colorScheme.error
                                    : accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              _statusMessage!,
                              style: materialTheme.textTheme.bodySmall
                                  ?.copyWith(
                                    color: _phase == _SchemaScannerPhase.error
                                        ? materialTheme
                                              .colorScheme
                                              .onErrorContainer
                                        : materialTheme
                                              .colorScheme
                                              .onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (closeAction != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        closeAction['label']?.toString().trim() ?? '',
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(
    BuildContext context,
    Map<String, dynamic> step,
    Color accent,
  ) {
    final id = step['id']?.toString().trim() ?? '';
    final label = step['label']?.toString().trim() ?? '';
    final isActive = id.isNotEmpty && id == _activeStepId;
    final isComplete = id.isNotEmpty && _completedSteps.contains(id);
    final theme = Theme.of(context);

    final background = isActive || isComplete
        ? accent
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = isActive || isComplete
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SchemaScannerFramePainter extends CustomPainter {
  const _SchemaScannerFramePainter({
    required this.color,
    required this.cornerSize,
    required this.borderWidth,
    required this.drawScanLine,
    required this.scanLineProgress,
    required this.scanLineOpacity,
    this.scanLineThickness,
  });

  final Color color;
  final double cornerSize;
  final double borderWidth;
  final bool drawScanLine;
  final double scanLineProgress;
  final double scanLineOpacity;
  final double? scanLineThickness;

  @override
  void paint(Canvas canvas, Size size) {
    if (borderWidth <= 0 || cornerSize <= 0) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round;

    final c = cornerSize.clamp(0.0, size.shortestSide / 2).toDouble();

    final path = Path()
      ..moveTo(0, c)
      ..lineTo(0, 0)
      ..lineTo(c, 0)
      ..moveTo(size.width - c, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, c)
      ..moveTo(size.width, size.height - c)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width - c, size.height)
      ..moveTo(c, size.height)
      ..lineTo(0, size.height)
      ..lineTo(0, size.height - c);

    canvas.drawPath(path, paint);

    if (drawScanLine) {
      final progress = scanLineProgress.clamp(0.0, 1.0).toDouble();
      final top = c;
      final bottom = (size.height - c).clamp(top, size.height).toDouble();
      final lineY = top + ((bottom - top) * progress);

      final linePaint = Paint()
        ..color = color.withValues(alpha: scanLineOpacity)
        ..strokeWidth =
            scanLineThickness ??
            (borderWidth > 1 ? borderWidth / 2 : borderWidth)
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(c, lineY),
        Offset(size.width - c, lineY),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SchemaScannerFramePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.cornerSize != cornerSize ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.drawScanLine != drawScanLine ||
        oldDelegate.scanLineProgress != scanLineProgress ||
        oldDelegate.scanLineOpacity != scanLineOpacity ||
        oldDelegate.scanLineThickness != scanLineThickness;
  }
}

Map<String, dynamic>? _schemaMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
  }
  return null;
}

List<Map<String, dynamic>> _schemaMapList(dynamic value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item.cast<dynamic, dynamic>()))
      .toList(growable: false);
}

double? _schemaDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().trim() ?? '');
}

double? _schemaAspectRatio(dynamic value) {
  final direct = _schemaDouble(value);
  if (direct != null && direct > 0) return direct;

  final raw = value?.toString().trim() ?? '';
  final parts = raw.split(':');
  if (parts.length != 2) return null;

  final width = double.tryParse(parts[0].trim());
  final height = double.tryParse(parts[1].trim());
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return width / height;
}

Alignment _schemaSheetAlignment(dynamic value) {
  switch (value?.toString().trim().toLowerCase()) {
    case 'top':
    case 'toponmobile':
      return Alignment.topCenter;
    case 'center':
    case 'centeronmobile':
      return Alignment.center;
    case 'bottom':
    case 'bottomonmobile':
    default:
      return Alignment.bottomCenter;
  }
}

Color? _schemaColor(dynamic value, {Color? fallback}) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return fallback;

  if (raw.startsWith('#')) {
    var hex = raw.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return fallback;
  }

  final rgba = RegExp(
    r'^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+))?\s*\)$',
    caseSensitive: false,
  ).firstMatch(raw);

  if (rgba != null) {
    final red = double.tryParse(rgba.group(1) ?? '');
    final green = double.tryParse(rgba.group(2) ?? '');
    final blue = double.tryParse(rgba.group(3) ?? '');
    final alpha = double.tryParse(rgba.group(4) ?? '1');

    if (red != null && green != null && blue != null && alpha != null) {
      return Color.fromRGBO(
        red.round().clamp(0, 255).toInt(),
        green.round().clamp(0, 255).toInt(),
        blue.round().clamp(0, 255).toInt(),
        alpha.clamp(0.0, 1.0).toDouble(),
      );
    }
  }

  return fallback;
}

Gradient? _schemaGradient(dynamic value) {
  if (value is! List || value.length < 2) return null;

  final colors = value
      .map((item) => _schemaColor(item))
      .whereType<Color>()
      .toList(growable: false);

  if (colors.length < 2) return null;
  return LinearGradient(colors: colors);
}

IconData _schemaIcon(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'x':
    case 'close':
      return Icons.close;
    case 'qrcode':
    case 'qr-code':
      return Icons.qr_code_2;
    case 'qrframe':
    case 'qr-frame':
    case 'qr':
    case 'scanner':
      return Icons.qr_code_scanner;
    case 'back':
    case 'arrow-left':
      return Icons.arrow_back;
    case 'camera':
      return Icons.camera_alt_outlined;
    case 'check':
      return Icons.check;
    default:
      return Icons.widgets_outlined;
  }
}

Map<String, dynamic>? _resolveOverlayPrompt({
  required Map<String, dynamic> overlay,
  required Map<String, dynamic> schema,
  required String promptId,
}) {
  final wanted = promptId.trim();
  final manual = _schemaMap(overlay['manualEntry']);
  if (manual != null && manual['enabled'] != false) {
    final id = (manual['id'] ?? manual['promptId'])?.toString().trim() ?? '';
    if (wanted.isEmpty || id.isEmpty || id == wanted) {
      return manual;
    }
  }

  final prompts = _schemaMap(schema['prompts']);
  if (wanted.isEmpty || prompts == null) return null;
  return _schemaMap(prompts[wanted]);
}

Map<String, dynamic>? _promptPrimarySubmitAction(Map<String, dynamic> prompt) {
  for (final action in _schemaMapList(prompt['actions'])) {
    final onTap = _schemaMap(action['onTap']) ?? action;
    final type = (onTap['action'] ?? onTap['type'])?.toString().trim();
    if (type == 'submitNodeId' || type == 'submit') {
      return <String, dynamic>{...action, ...onTap};
    }
  }
  return null;
}

class _SchemaOverlayPromptDialog extends StatefulWidget {
  const _SchemaOverlayPromptDialog({
    required this.prompt,
    required this.overlay,
  });

  final Map<String, dynamic> prompt;
  final Map<String, dynamic> overlay;

  @override
  State<_SchemaOverlayPromptDialog> createState() =>
      _SchemaOverlayPromptDialogState();
}

class _SchemaOverlayPromptDialogState extends State<_SchemaOverlayPromptDialog> {
  late final TextEditingController _controller;
  bool _attemptedSubmit = false;

  Map<String, dynamic> get _input =>
      _schemaMap(widget.prompt['input']) ?? const <String, dynamic>{};

  bool get _required => _input['required'] == true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _input['value']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleAction(Map<String, dynamic> action) {
    final onTap = _schemaMap(action['onTap']) ?? action;
    final type = (onTap['action'] ?? onTap['type'])?.toString().trim();
    if (type == 'closePrompt' || type == 'cancel') {
      Navigator.of(context).pop();
      return;
    }
    if (type == 'submitNodeId' || type == 'submit') {
      final value = _controller.text.trim();
      if (_required && value.isEmpty) {
        setState(() => _attemptedSubmit = true);
        return;
      }
      Navigator.of(context).pop(value);
    }
  }

  ButtonStyle _actionStyle({
    required String styleName,
    required Color accent,
    required ThemeData theme,
  }) {
    switch (styleName) {
      case 'primary':
        return FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: theme.colorScheme.onPrimary,
        );
      case 'destructive':
        return FilledButton.styleFrom(
          backgroundColor: theme.colorScheme.error,
          foregroundColor: theme.colorScheme.onError,
        );
      default:
        return OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overlayTheme =
        _schemaMap(widget.overlay['theme']) ?? const <String, dynamic>{};
    final layout =
        _schemaMap(widget.overlay['layout']) ?? const <String, dynamic>{};
    final accent = _schemaColor(
          overlayTheme['accent'],
          fallback: theme.colorScheme.primary,
        ) ??
        theme.colorScheme.primary;
    final radius = _schemaDouble(layout['sheetRadius']) ?? 24;
    final title = widget.prompt['title']?.toString().trim() ?? '';
    final subtitle = widget.prompt['subtitle']?.toString().trim() ?? '';
    final label = _input['label']?.toString().trim() ?? '';
    final placeholder = _input['placeholder']?.toString().trim() ?? '';
    final autocapitalize =
        _input['autocapitalize']?.toString().trim().toLowerCase();
    final actions = _schemaMapList(widget.prompt['actions']);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (title.isNotEmpty)
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (label.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: _input['spellcheck'] != false,
              enableSuggestions: _input['autocomplete']?.toString() != 'off',
              textCapitalization: autocapitalize == 'off'
                  ? TextCapitalization.none
                  : TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: placeholder,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(radius > 0 ? radius / 2 : 0),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(radius > 0 ? radius / 2 : 0),
                  borderSide: BorderSide(color: accent, width: 1.6),
                ),
              ),
              onChanged: (_) {
                if (_attemptedSubmit) setState(() {});
              },
              onSubmitted: (_) {
                final connect = _promptPrimarySubmitAction(widget.prompt);
                if (connect != null) _handleAction(connect);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                for (var index = 0; index < actions.length; index++) ...[
                  if (index > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _buildPromptButton(
                      action: actions[index],
                      accent: accent,
                      theme: theme,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPromptButton({
    required Map<String, dynamic> action,
    required Color accent,
    required ThemeData theme,
  }) {
    final label = action['label']?.toString().trim() ?? '';
    final styleName = action['style']?.toString().trim().toLowerCase() ?? '';
    final buttonStyle = _actionStyle(
      styleName: styleName,
      accent: accent,
      theme: theme,
    );
    if (styleName == 'primary' || styleName == 'destructive') {
      return FilledButton(
        style: buttonStyle,
        onPressed: () => _handleAction(action),
        child: Text(label),
      );
    }
    return OutlinedButton(
      style: buttonStyle,
      onPressed: () => _handleAction(action),
      child: Text(label),
    );
  }
}
