import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/scan_repository.dart';
import '../sdui/action_registry.dart';
import '../services/device_command_transport.dart';
import '../services/device_frame_builder.dart';
import '../services/device_parameter_store.dart';
import '../services/efactor_cloud_service.dart';
import '../services/efactor_device_api_transport.dart';
import '../services/efactor_http_transport.dart';
import '../services/json_http.dart';
import '../services/schema_patch.dart';
import '../sdui/schema_runtime.dart';

/// Runtime state, typed binding validation and schema action dispatch.
class AppState extends ChangeNotifier {
  AppState(
    Map<String, dynamic> schema, {
    http.Client? client,
    ScanRepository? scanRepository,
    DeviceCommandTransport? transport,
    String? accessToken,
    GlobalKey<ScaffoldMessengerState>? messengerKey,
    this.onAuthenticationFailure,
    this.onOpenScanner,
    this.onOpenWifiConfig,
    this.onOpenInfo,
    this.onPostProvisionRefresh,
    this.onDeviceRemoved,
    this.onActivePageChanged,
  })  : _schema = schema,
        _client = client ?? http.Client(),
        _scanRepository = scanRepository ?? ScanRepository(),
        _accessToken = accessToken ?? '',
        _messengerKey = messengerKey,
        _transportWasInjected = transport != null {
    _transport = transport ?? EfactorHttpTransport(client: _client);
    _deviceApiTransport = EfactorDeviceApiTransport();
    EfactorCloudService.instance.localDevices.addListener(_onLocalDevicesChanged);
    _initialize(schema);
  }

  Map<String, dynamic> _schema;
  final http.Client _client;
  final ScanRepository _scanRepository;
  late final DeviceCommandTransport _transport;
  late final DeviceCommandTransport _deviceApiTransport;
  final bool _transportWasInjected;
  String _accessToken;
  final GlobalKey<ScaffoldMessengerState>? _messengerKey;
  final Map<String, dynamic> _parameters = <String, dynamic>{};
  final Map<String, dynamic> _scanResult = <String, dynamic>{
    'scanId': null,
    'modelId': null,
    'nodeId': null,
    'deviceId': null,
    'value': null,
    'format': null,
    'scannedAt': null,
    'resourceUri': null,
  };

  // Latest Wi-Fi provisioning result synchronized with the same scan API.
  final Map<String, dynamic> _wifiConfig = <String, dynamic>{
    'ssid': null,
    'password': null,
    'security': null,
    'connected': false,
    'deviceIp': null,
    'updatedAt': null,
  };
  final Map<String, Timer> _sendDebounce = <String, Timer>{};
  final Set<String> _pendingBindings = <String>{};
  final Map<String, dynamic> _optimisticPrevious = <String, dynamic>{};
  final Map<String, dynamic> _runtimeState = <String, dynamic>{};
  final Set<String> _enabledTransports = <String>{};
  final Map<String, dynamic> _cloudTelemetryBuffer = <String, dynamic>{};
  final Map<String, dynamic> _latestCloudTelemetry = <String, dynamic>{};

  /// Read-only snapshot of buffered cloud telemetry waiting for multi-page controls.
  Map<String, dynamic> get cloudTelemetryBuffer =>
      Map<String, dynamic>.unmodifiable(_cloudTelemetryBuffer);

  /// Permanent read-only snapshot of all latest cloud telemetry received for this device.
  Map<String, dynamic> get latestCloudTelemetry =>
      Map<String, dynamic>.unmodifiable(_latestCloudTelemetry);

  DeviceParameterStore? _parameterStore;
  Timer? _parameterPersistTimer;
  static const Duration _parameterPersistDebounce = Duration(milliseconds: 400);

  // When the user drives a control, the local value is applied optimistically
  // before the device confirms it. A server snapshot captured during that
  // window can still carry the previous value, so the local value wins until
  // the window expires. Outside the window the device (or another remote) is
  // the source of truth and the server value must be applied, otherwise a
  // change made on the physical remote never becomes visible here.
  final Map<String, DateTime> _locallyChangedAt = <String, DateTime>{};
  static const Duration _localEchoWindow = Duration(seconds: 12);

  bool _shouldKeepLocalValue(String parameterKey) {
    final binding = 'device.parameters.$parameterKey';
    if (_pendingBindings.contains(binding)) return true;

    final changedAt = _locallyChangedAt[binding];
    if (changedAt == null) return false;

    if (DateTime.now().difference(changedAt) < _localEchoWindow) return true;

    _locallyChangedAt.remove(binding);
    return false;
  }

  /// Schema snapshots publish `"--"` (and similar) as empty placeholders for
  /// text/telemetry fields. Live `auto_get_nodes_params` values must never be
  /// wiped by those placeholders on a hot schema refresh.
  static bool isUnsetTelemetryValue(dynamic value) {
    if (value == null) return true;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(value.trim())) {
        return true;
      }
      return text.isEmpty ||
          text == '--' ||
          text == '-' ||
          text == 'n/a' ||
          text == 'na' ||
          text == 'null' ||
          text == 'undefined' ||
          text == 'nil';
    }
    return false;
  }

  /// Prefer a real live value over an unset schema placeholder.
  static dynamic preferLiveParameterValue({
    required dynamic previous,
    required dynamic incoming,
    required bool preserveLive,
    bool incomingIsPlaceholder = false,
  }) {
    final incomingValue = incoming is Map && incoming.containsKey('value')
        ? incoming['value']
        : incoming;
    if (!preserveLive) return incomingValue;
    if (!isUnsetTelemetryValue(previous)) {
      if (isUnsetTelemetryValue(incomingValue) || incomingIsPlaceholder) {
        return previous;
      }
    }
    return incomingValue;
  }

  // Runtime device connectivity. Schema `state.online` is only a snapshot.
  // Live IoT node status takes precedence over that frozen value.
  bool? _runtimeOnline;
  bool _liveOnlineKnown = false;

  int _activePageIndex = 0;
  SchemaRuntime? _schemaRuntime;
  String? _schemaRuntimeFingerprint;
  final Map<String, _BindingTick> _bindingTicks = <String, _BindingTick>{};
  final _BindingTick _navigationTick = _BindingTick();
  final _BindingTick _schemaStructureTick = _BindingTick();

  /// Incremented on every parameter mutation.
  ///
  /// Widget caches keyed only on the schema definition cannot see a value
  /// change, because the value does not live in the schema. Including this
  /// counter in such a cache key restores the ordinary Flutter rebuild path.
  int _parameterRevision = 0;
  int get parameterRevision => _parameterRevision;

  /// Binds this runtime to a durable per-device parameter cache.
  ///
  /// Call once after construction (model/node are host identity, not schema).
  void attachParameterStore({
    required String modelId,
    required String nodeId,
  }) {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty) return;
    _parameterStore = DeviceParameterStore(modelId: model, nodeId: node);
  }

  /// Loads last-known live values from disk and overlays them onto schema
  /// placeholders so power / speed / direction stay visible immediately.
  ///
  /// Only keys that already exist in the schema parameter map are restored
  /// (or that match a declared control binding), so junk never reappears.
  Future<int> hydrateParametersFromCache() async {
    final store = _parameterStore;
    if (store == null) return 0;

    final cached = await store.read();
    if (cached == null || cached.isEmpty) {
      logDebug('[DEVICE_PARAMS][CACHE] miss');
      return 0;
    }

    var applied = 0;
    for (final entry in cached.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty) continue;
      if (isUnsetTelemetryValue(entry.value)) continue;

      final known = _parameters.containsKey(key) ||
          controls.any(
            (control) =>
                parameterKeyForBinding(control['binding']?.toString() ?? '') ==
                key,
          );
      if (!known) continue;

      final binding = 'device.parameters.$key';
      final previous = _parameters[key];
      if (previous == entry.value) continue;
      // Cached real value always wins over schema `"--"`. Skip cache entries
      // that are still multi-field protocol names (`Resistance`) rather than
      // readings — those must not wipe a seeded asperui_value.
      final cachedIsFieldName = controls.any(
        (control) =>
            parameterKeyForBinding(control['binding']?.toString() ?? '') ==
                key &&
            isCommandFieldNamePlaceholder(control, entry.value),
      );
      if (cachedIsFieldName) continue;
      if (!isUnsetTelemetryValue(previous) && previous == entry.value) {
        continue;
      }
      try {
        setBinding(binding, entry.value, dispatch: false);
        if (_parameters[key] != previous) applied++;
      } catch (error) {
        logDebug(
          '[DEVICE_PARAMS][CACHE] hydrate rejected $key=${entry.value}: $error',
        );
      }
    }

    logDebug(
      '[DEVICE_PARAMS][CACHE] hydrated applied=$applied of=${cached.length}',
    );
    return applied;
  }

  void _scheduleParameterPersist() {
    if (_parameterStore == null) return;
    _parameterPersistTimer?.cancel();
    _parameterPersistTimer = Timer(_parameterPersistDebounce, () {
      unawaited(_persistParametersNow());
    });
  }

  Future<void> _persistParametersNow() async {
    final store = _parameterStore;
    if (store == null) return;
    // Never persist multi-field protocol names (`Resistance`) — only real
    // readings. Same map is used on Android and iOS SharedPreferences.
    final cleaned = <String, dynamic>{};
    for (final entry in _parameters.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (isUnsetTelemetryValue(value)) continue;
      final isFieldName = controls.any(
        (control) =>
            parameterKeyForBinding(control['binding']?.toString() ?? '') ==
                key &&
            isCommandFieldNamePlaceholder(control, value),
      );
      if (isFieldName) continue;
      cleaned[key] = value;
    }
    await store.writeIfChanged(cleaned);
  }

  // ── Public access to token so main.dart can inject after cloud init ─────────
  String get accessToken => _accessToken;
  void setAccessToken(String token) {
    _accessToken = token.trim();
  }

  /// Applies live node connectivity from the IoT status contract.
  ///
  /// Schema `state.online` is a published snapshot and must not replace this
  /// once a live reading is known.
  void applyLiveOnline(bool online) {
    _liveOnlineKnown = true;
    if (_runtimeOnline == online) return;
    _runtimeOnline = online;
    notifyListeners();
  }

  /// Called when a protected SDUI/device API returns HTTP 401/403.
  final Future<void> Function()? onAuthenticationFailure;

  /// Pager index selected by the schema's existing page controls.
  ///
  /// Return false when that slot's document is not on screen yet. The index
  /// stays on the page that is already painted, and the host reveals the new
  /// slot after its schema is applied. Schema replacement uses
  /// [revealPageIndex] and does not call this.
  final bool Function(int pageIndex)? onActivePageChanged;

  Future<void> _notifyAuthenticationFailure() async {
    final callback = onAuthenticationFailure;
    if (callback != null) {
      await callback();
    }
  }

  /// Host callback for the native `openScanner` action.
  Future<void> Function(
    BuildContext context,
    AppState state,
    Map<String, dynamic> action,
  )? onOpenScanner;

  /// Host callback for the schema `openWifiConfig` action.
  Future<void> Function(
    BuildContext context,
    AppState state,
    Map<String, dynamic> action,
  )? onOpenWifiConfig;

  /// Host callback for `openDeviceInfo` / `openInfo`.
  Future<void> Function(
    BuildContext context,
    AppState state,
    Map<String, dynamic> action,
  )? onOpenInfo;

  /// Host callback used only when the server Wi-Fi contract explicitly asks
  /// for a post-provision `deviceState` refresh. The host owns the live Device
  /// schema repository, so AppState never invents a second schema URL.
  final Future<void> Function()? onPostProvisionRefresh;

  /// Host callback invoked only after a schema-declared device-removal action
  /// has completed successfully. The host owns route lifecycle and list refresh;
  /// AppState does not invent any navigation target or backend endpoint.
  final Future<void> Function()? onDeviceRemoved;

  Future<void> notifyDeviceRemoved() async {
    final callback = onDeviceRemoved;
    if (callback != null) {
      await callback();
    }
  }

  Map<String, dynamic> get schema => _schema;

  SchemaRuntime get schemaRuntime {
    final fingerprint = schemaFingerprint(_schema);
    if (_schemaRuntime != null && _schemaRuntimeFingerprint == fingerprint) {
      return _schemaRuntime!;
    }
    _schemaRuntime = SchemaRuntime(_schema);
    _schemaRuntimeFingerprint = fingerprint;
    return _schemaRuntime!;
  }

  Listenable get navigationListenable => _navigationTick;

  Listenable get schemaStructureListenable => _schemaStructureTick;

  Listenable listenableForControl({String? id, String? binding}) {
    return Listenable.merge(<Listenable>[
      listenableForBinding(binding),
      listenableForNode(id),
    ]);
  }

  Listenable listenableForBinding(String? binding) {
    final key = 'b:${binding?.trim() ?? ''}';
    return _bindingTicks.putIfAbsent(key, _BindingTick.new);
  }

  Listenable listenableForNode(String? id) {
    final key = 'n:${id?.trim() ?? ''}';
    return _bindingTicks.putIfAbsent(key, _BindingTick.new);
  }

  Map<String, dynamic>? controlById(String? id) {
    final target = id?.trim() ?? '';
    if (target.isEmpty) return null;
    return _findControl(_schema, target);
  }

  Map<String, dynamic>? _findControl(dynamic node, String id) {
    if (node is Map) {
      if (node['id']?.toString() == id) {
        return node is Map<String, dynamic>
            ? node
            : Map<String, dynamic>.from(node.cast<dynamic, dynamic>());
      }
      for (final key in const ['pages', 'controls', 'children', 'components']) {
        final found = _findControl(node[key], id);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findControl(item, id);
        if (found != null) return found;
      }
    }
    return null;
  }

  void _tickChannel(String key) {
    _bindingTicks[key]?.ping();
  }

  static final RegExp _parameterBindingPrefix =
      RegExp(r'^(device\.|state\.)?parameters\.');
  static final RegExp _parameterBindingSuffix = RegExp(r'\.value$');

  /// The parameter key a binding string addresses, regardless of spelling.
  static String parameterKeyForBinding(String binding) {
    return binding
        .replaceFirst(_parameterBindingPrefix, '')
        .replaceFirst(_parameterBindingSuffix, '');
  }

  /// Repaints every widget observing [key], whichever binding spelling it
  /// registered with.
  ///
  /// A control subscribes through [listenableForControl] using the exact
  /// `control['binding']` string, and `_tickChannel` is a silent no-op for a
  /// key nobody registered. A tap therefore always repaints, because the widget
  /// passes its own binding back into [setBinding]. A remote/server update only
  /// knows the parameter key, so without this fan-out it pings a channel that
  /// no widget is listening on and the UI keeps the stale value.
  void _notifyParameterChanged(String key, {String? originBinding}) {
    _parameterRevision++;

    final channels = <String>{
      if (originBinding != null && originBinding.isNotEmpty) originBinding,
      'device.parameters.$key',
      'state.parameters.$key',
      'parameters.$key',
      'device.parameters.$key.value',
      'state.parameters.$key.value',
      'parameters.$key.value',
    };

    // Every control actually bound to this parameter, plus its node channel.
    final matchingControlIds = <String>{};
    for (final control in controls) {
      final raw = control['binding']?.toString() ?? '';
      if (raw.isEmpty) continue;
      if (parameterKeyForBinding(raw) != key) continue;

      channels.add(raw);
      final id = control['id']?.toString().trim() ?? '';
      if (id.isNotEmpty) matchingControlIds.add(id);
    }

    // universalUi aliases address the same value as `parameters.<aliasId>`,
    // resolved through sourceKey by _resolveUniversalParameterBinding.
    final extData = _schema['extensions'] is Map
        ? (_schema['extensions'] as Map)['universalUi']
        : null;
    final uData = extData is Map ? extData['data'] : null;
    final aliases = (uData is Map && uData['parameters'] is Map)
        ? uData['parameters'] as Map
        : null;
    if (aliases != null) {
      for (final entry in aliases.entries) {
        final sourceKey = (entry.value is Map)
            ? (entry.value as Map)['sourceKey']?.toString()
            : null;
        if (sourceKey == null || !matchingControlIds.contains(sourceKey)) {
          continue;
        }
        final aliasId = entry.key.toString();
        channels
          ..add('parameters.$aliasId')
          ..add('parameters.$aliasId.value');
      }
    }

    for (final channel in channels) {
      _tickChannel('b:$channel');
    }
    for (final id in matchingControlIds) {
      _tickChannel('n:$id');
    }

    notifyListeners();
  }

  List<Map<String, dynamic>> get pages {
    final paging = _schema['paging'];
    if (paging is Map &&
        paging['pages'] is List &&
        (paging['pages'] as List).isNotEmpty) {
      return [
        for (final item in paging['pages'] as List)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    }
    final direct = _schema['pages'];
    if (direct is List && direct.isNotEmpty) {
      return [
        for (final item in direct)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    }
    return const [];
  }

  List<Map<String, dynamic>> get controls {
    final list = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addControl(dynamic item) {
      if (item is Map) {
        final map = item is Map<String, dynamic>
            ? item
            : Map<String, dynamic>.from(item);
        final id = map['id']?.toString() ?? '';
        final binding = map['binding']?.toString() ?? '';
        final key = id.isNotEmpty ? id : (binding.isNotEmpty ? binding : null);
        if (key != null) {
          if (!seen.add(key)) return;
        }
        list.add(map);
      }
    }

    final rootControls = _schema['controls'];
    if (rootControls is List) {
      for (final item in rootControls) {
        addControl(item);
      }
    }

    for (final page in pages) {
      final pageControls = page['controls'];
      if (pageControls is List) {
        for (final item in pageControls) {
          addControl(item);
        }
      }
      final pageComponents = page['components'] ?? page['children'];
      if (pageComponents is List) {
        for (final item in pageComponents) {
          addControl(item);
        }
      }
    }

    return list;
  }

  int get activePageIndex => _activePageIndex;

  Map<String, dynamic> get activePage {
    if (pages.isEmpty) return const {};
    return pages[_activePageIndex.clamp(0, pages.length - 1)];
  }

  bool isBindingPending(String binding) => _pendingBindings.contains(binding);

  void _initialize(Map<String, dynamic> schema) {
    final rawState = schema['state'];
    final state = rawState is Map ? rawState : const {};
    final rawDevice = state['device'];
    final device = rawDevice is Map ? rawDevice : const {};
    _parameters.clear();

    // 1. Root state.device.parameters
    final deviceParams = device['parameters'];
    if (deviceParams is Map) {
      for (final entry in deviceParams.entries) {
        final val = entry.value;
        final actualVal =
            (val is Map && val.containsKey('value')) ? val['value'] : val;
        _parameters[entry.key.toString()] = actualVal;
      }
    }

    // 2. Production extensions.serverDrivenUi.state.parameters
    final sduiParams =
        schema['extensions']?['serverDrivenUi']?['state']?['parameters'];
    if (sduiParams is Map) {
      for (final entry in sduiParams.entries) {
        final val = entry.value;
        final actualVal =
            (val is Map && val.containsKey('value')) ? val['value'] : val;
        _parameters[entry.key.toString()] = actualVal;

        final meta = val is Map ? (val['meta'] as Map?) : null;
        final paramKey = meta?['parameterKey']?.toString();
        if (paramKey != null && paramKey.isNotEmpty) {
          _parameters[paramKey] = actualVal;
        }
      }
    }

    // 3. Controls array initial values fallback across root and all pages
    void seedControlInit(dynamic ctrl) {
      if (ctrl is Map) {
        final binding = ctrl['binding']?.toString() ?? '';
        final key = binding
            .replaceFirst(RegExp(r'^(device\.|state\.)?parameters\.'), '')
            .replaceFirst(RegExp(r'\.value$'), '');
        if (key.isNotEmpty && !_parameters.containsKey(key)) {
          final initVal = ctrl['initialValue'] ??
              ctrl['value'] ??
              ctrl['component']?['props']?['value'] ??
              ctrl['component']?['props']?['text'] ??
              ctrl['props']?['value'] ??
              ctrl['props']?['text'];
          if (initVal != null) {
            _parameters[key] = initVal;
          }
        }
      }
    }

    final controlsList = schema['controls'];
    if (controlsList is List) {
      for (final ctrl in controlsList) {
        seedControlInit(ctrl);
      }
    }
    final rawPages = schema['pages'] ??
        schema['extensions']?['serverDrivenUi']?['paging']?['pages'];
    if (rawPages is List) {
      for (final page in rawPages) {
        if (page is Map) {
          final pCtrls = page['controls'];
          if (pCtrls is List) {
            for (final ctrl in pCtrls) {
              seedControlInit(ctrl);
            }
          }
        }
      }
    }

    final rawWifi = state['wifiConfig'];
    final initialWifi = rawWifi is Map
        ? Map<String, dynamic>.from(rawWifi)
        : <String, dynamic>{};
    if (initialWifi.isNotEmpty) {
      _wifiConfig
        ..addAll(initialWifi)
        ..['deviceIp'] = initialWifi['deviceIp'] ?? initialWifi['device_ip'];
    }

    // Current device connectivity and Wi-Fi provisioning-session confirmation
    // are different state concepts. A schema may legitimately start a new
    // provisioning session with onlineConfirmed=false while the already-paired
    // device is online. Resolve the canonical device-online state first and
    // allow provisioning to promote it to online only when confirmation is true.
    if (!_liveOnlineKnown) {
      final extUi = schema['extensions'] is Map
          ? (schema['extensions'] as Map)['universalUi']
          : null;
      final extData = extUi is Map ? extUi['data'] : null;
      final extState = extData is Map ? extData['state'] : null;
      final declaredOnline = state['online'] ??
          (extState is Map ? extState['online'] : null);
      if (declaredOnline is bool) {
        _runtimeOnline = declaredOnline;
      } else {
        final initialConnected = initialWifi['connected'];
        if (initialConnected is bool) {
          _runtimeOnline = initialConnected;
        }
      }
    }

    final rawProv = state['wifiProvisioning'];
    final provisioningState = rawProv is Map ? rawProv : const {};
    if (provisioningState['onlineConfirmed'] == true) {
      _runtimeOnline = true;
    }

    _activePageIndex = (state['activePageIndex'] as num?)?.toInt() ??
        (schema['navigation']?['activeIndex'] as num?)?.toInt() ??
        0;
    _seedReadingsFromSchemaFrames();
    _clampPage();
    drainCloudTelemetryBuffer();
  }

  /// Replaces the schema atomically while preserving compatible live values and
  /// the currently open page. Unchanged controls keep their existing map
  /// identity so only dirty nodes are rebuilt.
  SchemaPatchResult replaceSchema(
    Map<String, dynamic> next, {
    bool preserveValues = true,
    bool preservePage = true,
  }) {
    final patch = SchemaPatch.merge(_schema, next);
    if (patch.unchanged) return patch;

    final previousValues = Map<String, dynamic>.from(_parameters);
    final previousPageId = activePage['id']?.toString();

    _schema = patch.schema;
    _schemaRuntime = null;
    _schemaRuntimeFingerprint = null;

    // A Device screen may render a validated cached schema first and then
    // replace it with the live schema. The published `state.online` field is a
    // snapshot, not live node connectivity. Once live status is known, do not
    // let that snapshot overwrite Online with Offline.
    final rawNextState = next['state'];
    final nextState = rawNextState is Map ? rawNextState : const {};
    if (!_liveOnlineKnown) {
      final extUi = next['extensions'] is Map
          ? (next['extensions'] as Map)['universalUi']
          : null;
      final extData = extUi is Map ? extUi['data'] : null;
      final extState = extData is Map ? extData['state'] : null;
      final declaredOnline = nextState['online'] ??
          (extState is Map ? extState['online'] : null);
      if (declaredOnline is bool) {
        _runtimeOnline = declaredOnline;
      } else {
        final incomingWifi = nextState['wifiConfig'] is Map
            ? nextState['wifiConfig'] as Map
            : const {};
        final incomingConnected = incomingWifi['connected'];
        if (incomingConnected is bool) {
          _runtimeOnline = incomingConnected;
        }
      }
    }

    final rawNextProv = nextState['wifiProvisioning'];
    final provisioningState = rawNextProv is Map ? rawNextProv : const {};
    if (provisioningState['onlineConfirmed'] == true) {
      _runtimeOnline = true;
    }

    final rawNextDev = nextState['device'];
    final rawNextParams = rawNextDev is Map ? rawNextDev['parameters'] : null;
    final incoming = rawNextParams is Map
        ? Map<String, dynamic>.from(rawNextParams)
        : const <String, dynamic>{};

    // Parameter values that changed on the device (physical remote, another
    // app, a scene) arrive inside the refreshed schema snapshot. They are only
    // rejected while this client still owns the value: a command in flight, or
    // one confirmed inside the local echo window.
    final liveValueChanges = <String>[];

    bool incomingFieldNamePlaceholder(String key, dynamic incoming) {
      if (isUnsetTelemetryValue(incoming)) return true;
      for (final ctrl in controls) {
        final bindingKey =
            parameterKeyForBinding(ctrl['binding']?.toString() ?? '');
        if (bindingKey != key) continue;
        if (isFrameFieldNameOrPlaceholder(ctrl, incoming)) return true;
      }
      return false;
    }

    if (patch.structural) {
      _parameters.clear();
      for (final entry in incoming.entries) {
        final binding = 'device.parameters.${entry.key}';
        final oldValue = previousValues[entry.key];
        final keepEcho = preserveValues &&
            previousValues.containsKey(entry.key) &&
            _shouldKeepLocalValue(entry.key) &&
            _isValidValue(binding, oldValue, throwOnError: false);

        if (keepEcho) {
          _parameters[entry.key] = oldValue;
          continue;
        }

        final isPlaceholder = incomingFieldNamePlaceholder(
          entry.key.toString(),
          entry.value,
        );
        final ctrl = controlForBinding(binding);
        final frameVal = ctrl != null ? schemaFrameReading(ctrl) : null;
        final effectiveIncoming =
            isPlaceholder && frameVal != null ? frameVal : entry.value;

        final merged = preferLiveParameterValue(
          previous: oldValue,
          incoming: effectiveIncoming,
          preserveLive: preserveValues && previousValues.containsKey(entry.key),
          incomingIsPlaceholder: isPlaceholder,
        );
        _parameters[entry.key] = merged;
        if (previousValues.containsKey(entry.key) &&
            previousValues[entry.key] != merged) {
          liveValueChanges.add(entry.key.toString());
        }
      }
      // Preserve live values and telemetry across other pages not present in incoming
      if (preserveValues) {
        for (final prevEntry in previousValues.entries) {
          if (!_parameters.containsKey(prevEntry.key)) {
            _parameters[prevEntry.key] = prevEntry.value;
          }
        }
      }
      // Seed newly added controls across merged pages
      final controlsList = _schema['controls'];
      if (controlsList is List) {
        for (final ctrl in controlsList) {
          if (ctrl is Map) {
            final binding = ctrl['binding']?.toString() ?? '';
            final key = binding
                .replaceFirst(RegExp(r'^(device\.|state\.)?parameters\.'), '')
                .replaceFirst(RegExp(r'\.value$'), '');
            if (key.isNotEmpty && !_parameters.containsKey(key)) {
              final ctrlMap =
                  Map<String, dynamic>.from(ctrl.cast<dynamic, dynamic>());
              final initVal = ctrl['initialValue'] ?? ctrl['value'];
              final frameVal = schemaFrameReading(ctrlMap);
              if (isFrameFieldNameOrPlaceholder(ctrlMap, initVal)) {
                _parameters[key] = frameVal ?? initVal;
              } else if (initVal != null) {
                _parameters[key] = initVal;
              }
            }
          }
        }
      }
      // The whole parameter map was rebuilt, so any definition-keyed widget
      // cache must be treated as stale.
      _parameterRevision++;
    } else {
      for (final entry in incoming.entries) {
        if (previousValues.containsKey(entry.key) &&
            preserveValues &&
            _shouldKeepLocalValue(entry.key)) {
          continue;
        }
        final isPlaceholder = incomingFieldNamePlaceholder(
          entry.key.toString(),
          entry.value,
        );
        final binding = 'device.parameters.${entry.key}';
        final ctrl = controlForBinding(binding);
        final frameVal = ctrl != null ? schemaFrameReading(ctrl) : null;
        final effectiveIncoming =
            isPlaceholder && frameVal != null ? frameVal : entry.value;

        final merged = preferLiveParameterValue(
          previous: previousValues[entry.key],
          incoming: effectiveIncoming,
          preserveLive:
              preserveValues && previousValues.containsKey(entry.key),
          incomingIsPlaceholder: isPlaceholder,
        );
        if (previousValues.containsKey(entry.key) &&
            previousValues[entry.key] == merged) {
          continue;
        }
        // Placeholder-only incoming with no previous key: still seed the map
        // so bindings resolve, but never clobber a real live value above.
        _parameters[entry.key] = merged;
        liveValueChanges.add(entry.key.toString());
      }
    }

    // A non-structural patch only ticks the changed widget nodes, so a value
    // that moved without its node definition changing would otherwise never
    // repaint the bound control.
    for (final key in liveValueChanges) {
      _notifyParameterChanged(key);
      logDebug(
        '[SDUI][LIVE_SYNC] device.parameters.$key = ${_parameters[key]} '
        '(from server snapshot)',
      );
    }
    if (liveValueChanges.isNotEmpty || patch.structural) {
      _scheduleParameterPersist();
    }

    if (preservePage && previousPageId != null) {
      final index = pages.indexWhere(
        (page) => page['id']?.toString() == previousPageId,
      );
      if (index >= 0) {
        _activePageIndex = index;
      } else {
        _activePageIndex =
            (next['state']?['activePageIndex'] as num?)?.toInt() ?? 0;
      }
    } else {
      _activePageIndex =
          (next['state']?['activePageIndex'] as num?)?.toInt() ?? 0;
    }

    _clampPage();
    _seedReadingsFromSchemaFrames();
    drainCloudTelemetryBuffer();
    if (patch.structural) {
      _schemaStructureTick.ping();
      notifyListeners();
    } else {
      for (final id in patch.changedNodeIds) {
        _tickChannel('n:$id');
      }
      // _notifyParameterChanged already notified for every live value change.
    }
    return patch;
  }

  void _clampPage() {
    _activePageIndex =
        pages.isEmpty ? 0 : _activePageIndex.clamp(0, pages.length - 1);
  }

  set activePageIndex(int value) {
    final next = pages.isEmpty ? 0 : value.clamp(0, pages.length - 1);
    if (next == _activePageIndex) return;
    // A later page document is a separate schema. Keep the painted page
    // until that document is ready, instead of showing its empty slide.
    if (onActivePageChanged?.call(next) == false) return;
    _activePageIndex = next;
    drainCloudTelemetryBuffer();
    _navigationTick.ping();
    notifyListeners();
  }

  /// Shows a pager slot after its schema has been replaced.
  ///
  /// This does not ask the host to download another page.
  void revealPageIndex(int index) {
    final next = pages.isEmpty ? 0 : index.clamp(0, pages.length - 1);
    if (next == _activePageIndex) return;
    _activePageIndex = next;
    drainCloudTelemetryBuffer();
    _navigationTick.ping();
    notifyListeners();
  }

  dynamic resolveBinding(String? binding) {
    if (binding == null || binding.isEmpty) return null;

    if (binding.startsWith('device.parameters.') ||
        binding.startsWith('state.parameters.') ||
        binding.startsWith('parameters.')) {
      final key = binding
          .replaceFirst(RegExp(r'^(device\.|state\.)?parameters\.'), '')
          .replaceFirst(RegExp(r'\.value$'), '');
      if (_parameters.containsKey(key)) {
        return _parameters[key];
      }
      if (binding.startsWith('parameters.')) {
        final univ = _resolveUniversalParameterBinding(binding);
        if (univ != null) return univ;
      }
      return _parameters[key];
    }

    switch (binding) {
      case 'state.activePageIndex':
        return _activePageIndex;
      case 'state.activePageName':
      case 'navigation.activePage.title':
        return activePage['title'];
      case 'state.activePageSubtitle':
        return activePage['subtitle'];
      case 'state.activePageNo':
        return activePage['pageNo'];
      case 'state.activePageId':
        return activePage['id'];
      case 'state.pageProgress':
        return pages.isEmpty ? 0.0 : (_activePageIndex + 1) / pages.length;
      case 'state.pageProgressPercent':
        return pages.isEmpty
            ? 0.0
            : ((_activePageIndex + 1) / pages.length) * 100.0;
      case 'state.online':
      case 'state.online.value':
      case 'state.deviceconnectivity.online':
        final nodeId = resolveDeviceIdentity().nodeId;
        final isLocal = EfactorCloudService.instance.isNodeLocal(nodeId);
        final cloudOnline = _runtimeOnline ??
            _schema['extensions']?['universalUi']?['data']?['state']
                ?['online'] ??
            false;
        return isLocal || (cloudOnline == true);
      case 'state.onlineLabel':
      case 'state.deviceconnectivity.label':
        final nodeId = resolveDeviceIdentity().nodeId;
        final isLocal = EfactorCloudService.instance.isNodeLocal(nodeId);
        final cloudOnline = _runtimeOnline ??
            _schema['extensions']?['universalUi']?['data']?['state']
                ?['online'] ??
            false;
        final online = isLocal || (cloudOnline == true);
        return online ? 'Online' : 'Offline';
      case 'state.isLocal':
      case 'state.isLocalOnline':
      case 'state.localOnline':
        final nodeId = resolveDeviceIdentity().nodeId;
        return EfactorCloudService.instance.isNodeLocal(nodeId);
      case 'state.connectivityType':
      case 'state.connectivityMode':
        final nodeId = resolveDeviceIdentity().nodeId;
        final isLocal = EfactorCloudService.instance.isNodeLocal(nodeId);
        if (isLocal) return 'local';
        final cloudOnline = _runtimeOnline ??
            _schema['extensions']?['universalUi']?['data']?['state']
                ?['online'] ??
            false;
        if (cloudOnline == true) return 'cloud';
        return 'offline';
      case 'state.connectivityLabel':
        final nodeId = resolveDeviceIdentity().nodeId;
        final isLocal = EfactorCloudService.instance.isNodeLocal(nodeId);
        if (isLocal) return 'Local (LAN)';
        final cloudOnline = _runtimeOnline ??
            _schema['extensions']?['universalUi']?['data']?['state']
                ?['online'] ??
            false;
        if (cloudOnline == true) return 'Cloud';
        return 'Offline';
      case 'state.localDeviceIp':
      case 'state.localDevice.ip':
        final nodeId = resolveDeviceIdentity().nodeId;
        return EfactorCloudService.instance.getLocalDevice(nodeId)?.ip;
      case 'state.localDevicePort':
      case 'state.localDevice.port':
        final nodeId = resolveDeviceIdentity().nodeId;
        return EfactorCloudService.instance.getLocalDevice(nodeId)?.port;
      case 'app.modelNo':
      case r'$app.modelNo':
        return _schema['meta']?['app']?['modelNo'];
      case 'state.scanResult':
        return Map<String, dynamic>.from(_scanResult);
      case 'state.scanResult.value':
        return _scanResult['value'];
      case 'state.scanResult.format':
        return _scanResult['format'];
      case 'state.scanResult.scannedAt':
        return _scanResult['scannedAt'];
      case 'state.scanResult.nodeId':
        return _scanResult['nodeId'];
      case 'state.wifiConfig':
        return Map<String, dynamic>.from(_wifiConfig);
      case 'state.wifiConfig.ssid':
        return _wifiConfig['ssid'];
      case 'state.wifiConfig.password':
        return _wifiConfig['password'];
      case 'state.wifiConfig.security':
        return _wifiConfig['security'];
      case 'state.wifiConfig.connected':
        return _wifiConfig['connected'];
      case 'state.wifiConfig.deviceIp':
      case 'state.wifiConfig.device_ip':
        return _wifiConfig['deviceIp'];
      case 'state.wifiConfig.updatedAt':
        return _wifiConfig['updatedAt'];
    }

    if (binding.startsWith('state.scanResult.')) {
      return _scanResult[binding.substring('state.scanResult.'.length)];
    }
    if (binding.startsWith('state.wifiConfig.')) {
      final key = binding.substring('state.wifiConfig.'.length);
      return key == 'device_ip' ? _wifiConfig['deviceIp'] : _wifiConfig[key];
    }
    if (_runtimeState.containsKey(binding)) {
      return _runtimeState[binding];
    }
    return null;
  }

  dynamic _resolveUniversalParameterBinding(String binding) {
    // parameters.parameter-1-pavan.value
    final parts = binding.split('.');
    if (parts.length < 3) return null;
    final id = parts[1];
    final extData = _schema['extensions'] is Map
        ? (_schema['extensions'] as Map)['universalUi']
        : null;
    final uData = extData is Map ? extData['data'] : null;
    final parameters = (uData is Map && uData['parameters'] is Map)
        ? uData['parameters'] as Map
        : null;
    final sourceKey = parameters?[id] is Map
        ? parameters![id]['sourceKey']?.toString()
        : null;
    if (sourceKey == null) return null;
    final control = controls.cast<Map<String, dynamic>?>().firstWhere(
          (item) => item?['id']?.toString() == sourceKey,
          orElse: () => null,
        );
    if (control == null) return null;
    return resolveBinding(control['binding']?.toString());
  }

  Map<String, dynamic> get parameters =>
      Map<String, dynamic>.unmodifiable(_parameters);

  /// Applies a live parameter update received from remote control or cloud push.
  /// Does not re-dispatch to avoid ping-pong loops.
  void applyRemoteParameter(String paramName, dynamic value) {
    final cleanName = paramName.trim();
    if (cleanName.isEmpty) return;

    // Cloud often wraps a reading as `{ "value": 28.82, "unit": "V" }`.
    // The scalar inside `value` is the reading the schema binding displays.
    if (value is Map &&
        value.containsKey('value') &&
        value['value'] is! Map &&
        value['value'] is! List) {
      value = value['value'];
    }

    // Never let an empty/`--` cloud field wipe a real reading we already hold.
    if (isUnsetTelemetryValue(value)) {
      logDebug(
        '[SDUI][REMOTE_SYNC] ignore unset "$cleanName"=$value',
      );
      return;
    }

    _latestCloudTelemetry[cleanName] = value;
    final matched = _tryApplyRemoteParameter(cleanName, value);
    if (!matched) {
      // Buffer unmatched parameter so when pages 2..N are merged later,
      // they automatically hydrate their live cloud values without waiting!
      _cloudTelemetryBuffer[cleanName] = value;
      logDebug(
        '[SDUI][REMOTE_SYNC] buffered unmatched telemetry "$cleanName" '
        '(value=$value). Total buffered: ${_cloudTelemetryBuffer.length}',
      );
    }
  }

  /// Attempts to apply a live parameter against current parameters, declared
  /// controls, fuzzy matches, and protocol aliases. Returns true if matched.
  bool _tryApplyRemoteParameter(String cleanName, dynamic value) {
    var matched = false;

    // 1. Direct match
    if (_parameters.containsKey(cleanName)) {
      if (_applyRemoteBinding('device.parameters.$cleanName', value)) {
        matched = true;
        // ignore: avoid_print
        print('[SDUI][REMOTE_SYNC] direct match: $cleanName = $value');
      }
    }

    // Channel/page prefix-suffix extraction (e.g. "power_2", "switch2", "2_power", "2:power")
    int? channelNumber;
    String baseName = cleanName;
    final prefixMatch = RegExp(r'^(\d+)[_:\-\.](.+)$').firstMatch(cleanName);
    if (prefixMatch != null) {
      channelNumber = int.tryParse(prefixMatch.group(1)!);
      baseName = prefixMatch.group(2)!;
    } else {
      final suffixMatch =
          RegExp(r'^([a-zA-Z_\-]+?)_?(\d+)$').firstMatch(cleanName);
      if (suffixMatch != null) {
        channelNumber = int.tryParse(suffixMatch.group(2)!);
        baseName = suffixMatch.group(1)!;
      }
    }

    if (channelNumber != null) {
      final chPrefix = '${channelNumber}_';
      final baseLower = baseName.toLowerCase();

      // 1b. Direct channel-scoped match in _parameters (e.g. "2_power")
      final chScopedKey = '${channelNumber}_$baseLower';
      if (_parameters.containsKey(chScopedKey)) {
        if (_applyRemoteBinding('device.parameters.$chScopedKey', value)) {
          matched = true;
          // ignore: avoid_print
          print(
            '[SDUI][REMOTE_SYNC] channel-scoped match: $cleanName -> $chScopedKey = $value',
          );
        }
      }

      // 2b. Channel-scoped match against registered parameter keys (e.g. "2_power_command_2_toggle_switch")
      for (final key in _parameters.keys.toList()) {
        final lowerKey = key.toLowerCase();
        if (!lowerKey.startsWith(chPrefix) &&
            !lowerKey.startsWith('device.parameters.$chPrefix')) {
          continue;
        }
        if (_isMultiFieldCommandBinding(key)) continue;

        final parts = lowerKey.split('_');
        if (parts.contains(baseLower) ||
            lowerKey.contains('_${baseLower}_') ||
            lowerKey.endsWith('_$baseLower') ||
            lowerKey.contains(baseLower)) {
          if (_applyRemoteBinding('device.parameters.$key', value)) {
            matched = true;
            // ignore: avoid_print
            print(
              '[SDUI][REMOTE_SYNC] channel matched $cleanName -> $key = $value',
            );
          }
        }
      }

      // 3b. Channel-scoped match against controls
      for (final ctrl in controls) {
        final rawBinding = ctrl['binding']?.toString() ?? '';
        final key = parameterKeyForBinding(rawBinding);
        if (key.isEmpty) continue;
        final lowerKey = key.toLowerCase();
        if (!lowerKey.startsWith(chPrefix)) continue;
        if (!_parameterAliasMatches(ctrl, key, baseLower) &&
            !lowerKey.contains(baseLower)) {
          continue;
        }
        if (_applyRemoteBinding('device.parameters.$key', value)) {
          matched = true;
          // ignore: avoid_print
          print(
            '[SDUI][REMOTE_SYNC] channel control match $cleanName -> $key = $value',
          );
        }
      }
    }

    // 2. Fuzzy/suffix match against registered parameter keys
    // e.g. remote sends "power", schema keys are "1_power", "2_power"
    // or remote sends "speed", schema keys are "1_speed_command_2_slider", "1_speed"
    final lowerName = cleanName.toLowerCase();
    for (final key in _parameters.keys.toList()) {
      final lowerKey = key.toLowerCase();
      if (lowerKey == lowerName) continue;
      // Multi-field command rows (tuning / Remote Pairing) must not all
      // receive a shared-frame alias via `contains('tuning')`.
      if (_isMultiFieldCommandBinding(key)) continue;

      final parts = lowerKey.split('_');
      if (parts.contains(lowerName) ||
          lowerKey.startsWith('${lowerName}_') ||
          lowerKey.endsWith('_$lowerName') ||
          lowerKey.contains(lowerName)) {
        if (_applyRemoteBinding('device.parameters.$key', value)) {
          matched = true;
          // ignore: avoid_print
          print('[SDUI][REMOTE_SYNC] matched $cleanName -> $key = $value');
        }
      }
    }

    // 2c. Multi-page indexed response matching in _parameters
    // Handles keys like "3_command_get_status_response_11_text", "5_remote_address_response_11_text",
    // "1_get_status_response_11_text" whose parameter key doesn't include the metric name.
    for (final key in _parameters.keys.toList()) {
      final respMatch = RegExp(r'(?:response|resp)[-_](\d+)').firstMatch(key);
      if (respMatch == null) continue;
      final idx = int.tryParse(respMatch.group(1)!);
      if (idx == null) continue;

      final frame = _findDeviceFrameForBinding(key);
      final responseList = frame?['response'] as List?;
      if (responseList != null && idx >= 0 && idx < responseList.length) {
        final field = responseList[idx];
        if (field is Map) {
          final defName =
              field['default_name']?.toString().toLowerCase().trim() ?? '';
          final fieldDesc =
              field['Field_description']?.toString().toLowerCase().trim() ??
                  '';
          final compactDef = defName.replaceAll(RegExp(r'[\s_\-]+'), '');
          final compactLower = lowerName.replaceAll(RegExp(r'[\s_\-]+'), '');

          if (defName == lowerName ||
              compactDef == compactLower ||
              defName.contains(lowerName) ||
              fieldDesc == lowerName) {
            if (_applyRemoteBinding('device.parameters.$key', value)) {
              matched = true;
              // ignore: avoid_print
              print(
                '[SDUI][REMOTE_SYNC] indexed response match $cleanName -> $key = $value',
              );
            }
          }
        }
      }
    }

    // 3. Match against declared controls[] from schema if not yet in _parameters
    for (final ctrl in controls) {
      final rawBinding = ctrl['binding']?.toString() ?? '';
      final key = rawBinding
          .replaceFirst(RegExp(r'^(device\.|state\.)?parameters\.'), '')
          .replaceFirst(RegExp(r'\.value$'), '');
      if (key.isNotEmpty && !_parameters.containsKey(key)) {
        if (_isMultiFieldCommandBinding(key) ||
            _frameHasMultipleDataFields(ctrl)) {
          continue;
        }
        final lowerKey = key.toLowerCase();
        final parts = lowerKey.split('_');
        if (lowerKey == lowerName ||
            parts.contains(lowerName) ||
            lowerKey.startsWith('${lowerName}_') ||
            lowerKey.endsWith('_$lowerName') ||
            lowerKey.contains(lowerName)) {
          if (_applyRemoteBinding('device.parameters.$key', value)) {
            matched = true;
            // ignore: avoid_print
            print(
              '[SDUI][REMOTE_SYNC] matched from control $cleanName -> $key = $value',
            );
          }
        }
      }
    }

    // 4. Schema-declared aliases. Live payloads use short names (`Voltage`,
    // `rpm`, `name`) while bindings use protocol keys (`2_voltage_…`).
    // `controls[].id` is often `2:Voltage` and `parameter` / `parameterName`
    // is the published label. No device-specific names are hardcoded here.
    for (final ctrl in controls) {
      final rawBinding = ctrl['binding']?.toString() ?? '';
      final key = parameterKeyForBinding(rawBinding);
      if (key.isEmpty) continue;
      if (!_parameterAliasMatches(ctrl, key, lowerName)) continue;
      if (_applyRemoteBinding('device.parameters.$key', value)) {
        matched = true;
        // ignore: avoid_print
        print(
          '[SDUI][REMOTE_SYNC] alias match $cleanName -> $key = $value',
        );
      }
    }

    return matched;
  }

  /// Drains and applies latest cloud telemetry against newly merged controls/parameters.
  /// Called whenever new schema controls are merged into state across multi-page models.
  int drainCloudTelemetryBuffer() {
    var appliedCount = 0;
    // 1. Re-apply all known latest cloud telemetry entries across newly merged controls
    for (final entry in _latestCloudTelemetry.entries) {
      if (_tryApplyRemoteParameter(entry.key, entry.value)) {
        appliedCount++;
      }
    }
    // 2. Also re-attempt any buffered raw items
    final bufferedKeys = _cloudTelemetryBuffer.keys.toList();
    for (final key in bufferedKeys) {
      final val = _cloudTelemetryBuffer[key];
      if (_tryApplyRemoteParameter(key, val)) {
        _cloudTelemetryBuffer.remove(key);
      }
    }
    if (appliedCount > 0) {
      logDebug(
        '[SDUI][REMOTE_SYNC] auto-hydrated $appliedCount reading(s) across pages',
      );
    }
    return appliedCount;
  }

  /// Applies one cloud document.
  ///
  /// `getAllNodes` only carries name and power. Speed, direction, rpm and the
  /// other readings arrive as `auto_get_nodes_params`, either pushed on the
  /// socket or returned by that action. A reading wrapped as
  /// `{value: n}` or `{asperui_value: n}` is applied under its parameter name.
  ///
  /// When a schema control whose parameter name contains "log" is on, each
  /// value that actually changed is appended to the schema terminal console.
  int ingestCloudPayload(dynamic data, {String? nodeId}) {
    final target = nodeId?.trim().toLowerCase().replaceAll(RegExp(r'\.+$'), '');
    var changed = 0;
    late void Function(dynamic node) walk;

    String normalizeNode(dynamic value) => (value ?? '')
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\.+$'), '');

    bool sameNode(dynamic value) {
      final node = normalizeNode(value);
      if (target == null || target.isEmpty || node.isEmpty) return true;
      return node == target;
    }

    void applyScalar(String name, dynamic value) {
      if (_cloudEnvelopeKeys.contains(name)) return;
      final lowerName = name.trim().toLowerCase();
      final isLogEnvelopeName = lowerName == 'message' ||
          lowerName == 'log' ||
          lowerName == 'logs' ||
          lowerName == 'displaylog' ||
          lowerName == 'display_log' ||
          lowerName == 'display log';
      if (isLogEnvelopeName) {
        final text = value?.toString() ?? '';
        final isToggle = value is bool ||
            text == 'true' ||
            text == 'false' ||
            text == '1' ||
            text == '0' ||
            text == '00' ||
            text == '01' ||
            text.toUpperCase() == 'ON' ||
            text.toUpperCase() == 'OFF';
        if (!isToggle || _isTerminalAlias(lowerName)) {
          if (_appendTerminalLine(text)) {
            changed++;
          }
          return;
        }
      }
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map || decoded is List) {
              walk(decoded);
              return;
            }
          } catch (_) {}
        }
      }
      final before = Map<String, dynamic>.from(_parameters);
      final terminal = _logGateIsOn() &&
          _isTerminalAlias(name.trim().toLowerCase());
      if (terminal) {
        if (_appendTerminalLine(value?.toString() ?? '')) changed++;
        return;
      }
      applyRemoteParameter(name, value);
      final changedKeys = <String>[
        for (final key in <String>{...before.keys, ..._parameters.keys})
          if (!readingsAreEqual(before[key], _parameters[key])) key,
      ];
      changed += changedKeys.length;
      if (_logGateIsOn()) {
        for (final key in changedKeys) {
          if (_isTerminalKey(key)) continue;
          final shown = _parameters[key];
          _appendTerminalLine('$name=$shown');
        }
      }
    }

    walk = (dynamic node) {
      if (node is List) {
        for (final item in node) {
          walk(item);
        }
        return;
      }
      if (node is! Map) return;
      final map = Map<String, dynamic>.from(node.cast<dynamic, dynamic>());
      if (map.containsKey('controls') && map.containsKey('schemaVersion')) {
        return;
      }

      final pairName =
          (map['name'] ?? map['key'] ?? map['param'] ?? map['parameter'])
              ?.toString()
              .trim();
      final pairKeys = map.keys.map((key) => key.toString()).toSet();
      const pairMeta = <String>{
        'name',
        'key',
        'param',
        'parameter',
        'value',
        'unit',
        'asperui_value',
        'val',
        'reading',
      };
      if (pairName != null &&
          pairName.isNotEmpty &&
          map.containsKey('value') &&
          map['value'] is! List &&
          pairKeys.difference(pairMeta).isEmpty) {
        applyScalar(pairName, map['value']);
        return;
      }

      for (final entry in map.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value;
        if (key.isEmpty) {
          if (value is Map || value is List) walk(value);
          continue;
        }
        if (_cloudEnvelopeKeys.contains(key)) continue;
        if (key == 'connectivity' && value is Map) {
          final connected = value['connected'];
          if (connected != null) {
            final online = connected == true ||
                connected.toString().toLowerCase() == 'true';
            final offline = connected == false ||
                connected.toString().toLowerCase() == 'false';
            if (online || offline) applyLiveOnline(online);
          }
          continue;
        }
        if (value is List) {
          if (key == 'all_nodes' || key == 'nodes' || key == 'node_details') {
            for (final item in value) {
              if (item is! Map) continue;
              final config = item['config'];
              final itemNode = item['node_id'] ??
                  item['nodeId'] ??
                  item['id'] ??
                  (config is Map
                      ? (config['node_id'] ?? config['nodeId'])
                      : null);
              if (sameNode(itemNode)) walk(item);
            }
            continue;
          }
          if (key == 'devices' ||
              key == 'switches' ||
              key == 'gangs' ||
              key == 'channels' ||
              key == 'sub_devices') {
            for (var i = 0; i < value.length; i++) {
              final sub = value[i];
              if (sub is! Map) continue;

              int? subIndex;
              final pageName = sub['page_name'] ??
                  sub['pageName'] ??
                  sub['name'] ??
                  sub['title'];
              if (pageName != null) {
                final numMatch =
                    RegExp(r'(\d+)').firstMatch(pageName.toString());
                if (numMatch != null) {
                  subIndex = int.tryParse(numMatch.group(1)!);
                }
              }
              subIndex ??= (sub['page_no'] ??
                      sub['pageNo'] ??
                      sub['page'] ??
                      sub['channel'] ??
                      sub['gang'] ??
                      sub['index'] ??
                      sub['id'] as num?)
                  ?.toInt();
              subIndex ??= (i + 1);

              for (final subEntry in sub.entries) {
                final subKey = subEntry.key.toString().trim();
                final subVal = subEntry.value;
                if (_cloudEnvelopeKeys.contains(subKey)) continue;
                if (subVal is Map || subVal is List) {
                  walk(subVal);
                  continue;
                }
                applyScalar('${subIndex}_$subKey', subVal);
                applyScalar('${subKey}_$subIndex', subVal);
                if (value.length == 1) {
                  applyScalar(subKey, subVal);
                }
              }
            }
            continue;
          }
          walk(value);
          continue;
        }
        if (value is Map) {
          final pageMatch = RegExp(
            r'^(?:page|channel|gang|device|sw|switch)[_]?(\d+)$',
            caseSensitive: false,
          ).firstMatch(key);
          if (pageMatch != null) {
            final pageNum = int.tryParse(pageMatch.group(1)!);
            if (pageNum != null) {
              for (final subEntry in value.entries) {
                final subK = subEntry.key.toString().trim();
                final subV = subEntry.value;
                if (_cloudEnvelopeKeys.contains(subK)) continue;
                if (subV is! Map && subV is! List) {
                  applyScalar('${pageNum}_$subK', subV);
                  applyScalar('${subK}_$pageNum', subV);
                  applyScalar(subK, subV);
                } else {
                  walk(subV);
                }
              }
              continue;
            }
          }
          final reading = _scalarReading(value);
          if (reading != null && !_cloudContainerKeys.contains(key)) {
            applyScalar(key, reading);
            continue;
          }
          if (!sameNode(value['node_id'] ?? value['nodeId'] ?? value['id'])) {
            continue;
          }
          walk(value);
          continue;
        }
        if (_cloudContainerKeys.contains(key)) {
          if (value is String &&
              _logGateIsOn() &&
              (key == 'data' || key == 'message')) {
            applyScalar('log', value);
          }
          continue;
        }
        applyScalar(key, value);
      }
    };

    if (data is Map) {
      final direct = data['node_id'] ??
          data['nodeId'] ??
          data['device_id'] ??
          data['deviceId'];
      if (!sameNode(direct) &&
          data['all_nodes'] is! List &&
          data['nodes'] is! List) {
        return 0;
      }
    }
    walk(data);
    return changed;
  }

  /// Live parameter snapshot. This is `api.php?action=auto_get_nodes_params`,
  /// the channel the device SDK uses for speed, direction, rpm and the rest.
  /// It is not the multi-megabyte schema document.
  Future<int> refreshLiveNodeParams() async {
    final nodeId = resolveDeviceIdentity().nodeId?.trim() ?? '';
    final uri = _liveNodeParamsUri(nodeId);
    if (uri == null) {
      logDebug('[SDUI][LIVE_PARAMS] skipped — no schema host');
      return 0;
    }
    try {
      logDebug('[SDUI][LIVE_PARAMS] GET $uri');
      final response = await _client
          .get(
            uri,
            headers: <String, String>{
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
              if (_accessToken.isNotEmpty)
                'Authorization': 'Bearer $_accessToken',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        logDebug('[SDUI][LIVE_PARAMS] HTTP ${response.statusCode}');
        return 0;
      }
      final decoded = jsonDecode(response.body);
      final changed = ingestCloudPayload(decoded, nodeId: nodeId);
      logDebug('[SDUI][LIVE_PARAMS] changed=$changed');
      return changed;
    } catch (error) {
      logDebug('[SDUI][LIVE_PARAMS] failed: $error');
      return 0;
    }
  }

  Uri? _liveNodeParamsUri(String nodeId) {
    if (nodeId.isEmpty) return null;
    final raw = rewritePublicApiUrl(
      _schema['meta']?['links']?['schema']?.toString() ??
          _schema['meta']?['links']?['parameters']?.toString() ??
          _schema['_clientConnection']?['schemaUrl']?.toString() ??
          _schema['_clientSchemaSource']?.toString(),
    );
    final base = raw == null ? null : Uri.tryParse(raw);
    if (base == null || !base.hasScheme || base.host.isEmpty) return null;
    final segments =
        base.pathSegments.where((part) => part.trim().isNotEmpty).toList();
    if (segments.isEmpty) return null;
    segments[segments.length - 1] = 'api.php';
    return base.replace(
      pathSegments: segments,
      queryParameters: <String, String>{
        'action': 'auto_get_nodes_params',
        'node_id': nodeId,
      },
    );
  }

  static const Set<String> _cloudEnvelopeKeys = <String>{
    'node_id',
    'nodeId',
    'device_id',
    'deviceId',
    'id',
    'startId',
    'action',
    'type',
    'url',
    'token',
    'apiKey',
    'access_token',
    'accessToken',
    'success',
    'total',
    'user_id',
    'userId',
    'timestamp',
    'ts',
    'role',
    'frame',
    'module_type',
    'node_type',
    'device_name',
    'ui_type',
    'page_name',
    'ui_description',
    'local_control',
    'primary',
    'brand_logo',
    'Need_Help',
    'chat_status',
    'device_image',
    'device_p2p_control',
    'Device Communication',
    'Status',
    'schemaVersion',
    'schema_json',
    'controls',
    'widgetTree',
  };

  static const Set<String> _cloudContainerKeys = <String>{
    'config',
    'status',
    'connectivity',
    'devices',
    'parameters',
    'params',
    'data',
    'state',
    'pages',
    'commands',
    'response',
    'error',
    'schema',
    'payload',
  };

  static dynamic _scalarReading(Map<dynamic, dynamic> value) {
    const keys = <String>['value', 'asperui_value', 'val', 'reading'];
    var found = false;
    dynamic reading;
    for (final key in keys) {
      if (!value.containsKey(key)) continue;
      final candidate = value[key];
      if (candidate is Map || candidate is List) return null;
      reading = candidate;
      found = true;
      break;
    }
    if (!found) return null;
    for (final key in value.keys) {
      final name = key.toString();
      if (keys.contains(name) ||
          name == 'unit' ||
          name == 'type' ||
          name == 'data_type') {
        continue;
      }
      return null;
    }
    return reading;
  }

  bool _isTerminalControl(Map<String, dynamic> control) {
    final props = control['component']?['props'];
    if (props is! Map) return false;
    return props['variant']?.toString().trim().toLowerCase() == 'terminal';
  }

  bool _isTerminalAlias(String aliasLower) {
    if (aliasLower.isEmpty) return false;
    for (final control in controls) {
      if (!_isTerminalControl(control)) continue;
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key.isEmpty) continue;
      if (_parameterAliasMatches(control, key, aliasLower)) return true;
    }
    return false;
  }

  bool _isTerminalKey(String parameterKey) {
    for (final control in controls) {
      if (!_isTerminalControl(control)) continue;
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key == parameterKey) return true;
    }
    return false;
  }

  bool _keyIsLogGate(String parameterKey) {
    for (final control in controls) {
      final name = (control['parameter'] ?? control['parameterName'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (!name.contains('log')) continue;
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key == parameterKey) return true;
    }
    return false;
  }

  bool _logGateIsOn() {
    for (final control in controls) {
      final name = (control['parameter'] ?? control['parameterName'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (!name.contains('log')) continue;
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key.isEmpty) continue;
      if (_telemetryIsOn(_parameters[key])) return true;
    }
    return false;
  }

  bool _telemetryIsOn(dynamic value) => telemetryIsOn(value);

  /// Resolves a human-readable parameter or field label for a schema control,
  /// extracting names from responseField definitions when default_name is "Data".
  static String resolveControlDisplayName(Map<String, dynamic> control) {
    final responseField = responseFieldFor(control);
    final rawRespName = responseField?['default_name']?.toString().trim();
    final candidateName = (rawRespName != null &&
            rawRespName.isNotEmpty &&
            rawRespName.toLowerCase() != 'data' &&
            rawRespName.toLowerCase() != 'none')
        ? rawRespName
        : (responseField?['value'] ??
            responseField?['asperui_value'] ??
            control['protocolMeta']?['default'] ??
            responseField?['default_name'] ??
            responseField?['Field_description']);
    final resp = candidateName?.toString().trim() ?? '';
    if (resp.isNotEmpty &&
        resp.toLowerCase() != 'none' &&
        resp.toLowerCase() != 'data') {
      return resp;
    }
    final param = (control['parameter'] ?? control['parameterName'])
        ?.toString()
        .trim() ??
        '';
    if (param.isNotEmpty && param.toLowerCase() != 'data') {
      return param;
    }
    final label = (control['label'] ?? control['title'])?.toString().trim() ?? '';
    if (label.isNotEmpty && label.toLowerCase() != 'data') {
      return label;
    }
    return '';
  }

  /// Writes the readings already on screen into the terminal when a log
  /// gate turns on, then later cloud changes append after them.
  void _appendLiveSnapshotToConsole() {
    final seen = <String>{};
    for (final control in controls) {
      if (_isTerminalControl(control)) continue;
      final name = resolveControlDisplayName(control);
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower.contains('log') || lower == 'data' || seen.contains(lower)) {
        continue;
      }
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key.isEmpty) continue;
      final value = _parameters[key];
      final text = value?.toString() ?? '';
      if (isUnsetTelemetryValue(value) ||
          _isConsolePlaceholder(text, control)) {
        continue;
      }
      seen.add(lower);
      _appendTerminalLine('$name=$value');
    }
  }

  bool _appendTerminalLine(String raw) {
    var line = raw.trim();
    if (line.isEmpty || isUnsetTelemetryValue(line)) return false;
    if (line.length > 500) line = line.substring(0, 500);
    var wrote = false;
    for (final control in controls) {
      if (!_isTerminalControl(control)) continue;
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key.isEmpty) continue;
      final prompt = _terminalPrompt(control);
      final rendered = prompt.isEmpty ? line : '$prompt $line';
      final current = _parameters[key]?.toString() ?? '';
      final base = _isConsolePlaceholder(current, control) ? '' : current;
      final existing = base.split('\n');
      if (existing.isNotEmpty && existing.last == rendered) continue;
      final nextLines = <String>[
        if (base.isNotEmpty) ...existing,
        rendered,
      ];
      final capped = nextLines.length > 200
          ? nextLines.sublist(nextLines.length - 200)
          : nextLines;
      try {
        setBinding(
          'device.parameters.$key',
          capped.join('\n'),
          dispatch: false,
        );
        wrote = true;
      } catch (error) {
        logDebug('[SDUI][CONSOLE] rejected $key: $error');
      }
    }
    return wrote;
  }

  String _terminalPrompt(Map<String, dynamic> control) {
    final props = control['component']?['props'];
    if (props is! Map) return '';
    return props['promptSymbol']?.toString().trim() ?? '';
  }

  bool _isConsolePlaceholder(String text, Map<String, dynamic> control) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isUnsetTelemetryValue(trimmed)) return true;
    final framed = schemaFrameReading(control)?.toString().trim() ?? '';
    if (framed.isNotEmpty && readingsAreEqual(trimmed, framed)) return true;
    for (final raw in <dynamic>[
      control['parameter'],
      control['parameterName'],
      control['value'],
      control['label'],
    ]) {
      final name = raw?.toString().trim() ?? '';
      if (name.isNotEmpty && readingsAreEqual(trimmed, name)) return true;
    }
    return false;
  }

  /// Reloads live `state.device.parameters` from the schema-declared parameters
  /// URL (`meta.links.parameters` / `_clientConnection.schemaUrl`).
  ///
  /// Why this exists: `getAllNodes` / `getAllNodesStatus` only carry the
  /// device-level `power` flag. Speed, Direction, Buzzer, etc. are absent from
  /// those replies, so remote changes never reach the UI unless we pull the
  /// parameter snapshot from the schema endpoint (or receive an
  /// `auto_get_nodes_params` push).
  Future<int> refreshLiveParametersFromServer() async {
    final rawUrl = rewritePublicApiUrl(
      _schema['meta']?['links']?['parameters']?.toString() ??
          _schema['_clientConnection']?['schemaUrl']?.toString() ??
          _schema['_clientSchemaSource']?.toString(),
    );
    if (rawUrl == null || rawUrl.isEmpty) {
      logDebug('[SDUI][PARAM_REFRESH] skipped — no schema parameters URL');
      return 0;
    }

    final base = Uri.tryParse(rawUrl);
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      logDebug('[SDUI][PARAM_REFRESH] skipped — invalid URL: $rawUrl');
      return 0;
    }

    final uri = base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        '_ts': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );

    try {
      logDebug('[SDUI][PARAM_REFRESH] GET $uri');
      final response = await _client
          .get(
            uri,
            headers: <String, String>{
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
              if (_accessToken.isNotEmpty)
                'Authorization': 'Bearer $_accessToken',
            },
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        logDebug(
          '[SDUI][PARAM_REFRESH] HTTP ${response.statusCode}',
        );
        return 0;
      }

      final decoded = decodeJsonBody(
        body: response.body,
        contentType: response.headers['content-type'],
        source: uri.toString(),
      );
      if (decoded is! Map) {
        logDebug('[SDUI][PARAM_REFRESH] root is not an object');
        return 0;
      }

      final root = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final parameters = _extractDeviceParameters(root);
      if (parameters == null || parameters.isEmpty) {
        logDebug(
          '[SDUI][PARAM_REFRESH] no state.device.parameters in response',
        );
        return 0;
      }

      var applied = 0;
      var skippedPlaceholder = 0;
      for (final entry in parameters.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;

        final incomingValue = entry.value is Map &&
                (entry.value as Map).containsKey('value')
            ? (entry.value as Map)['value']
            : entry.value;

        // api_schema snapshots still publish `"--"` for unread telemetry.
        // Applying those would wipe values that auto_get_nodes_params just set.
        if (isUnsetTelemetryValue(incomingValue) &&
            _parameters.containsKey(key) &&
            !isUnsetTelemetryValue(_parameters[key])) {
          skippedPlaceholder++;
          continue;
        }
        if (isUnsetTelemetryValue(incomingValue) &&
            !_parameters.containsKey(key)) {
          // Seed missing keys with the placeholder so bindings resolve, but
          // do not count them as live updates.
          final binding = 'device.parameters.$key';
          try {
            setBinding(binding, incomingValue, dispatch: false);
          } catch (error) {
            logDebug(
              '[SDUI][PARAM_REFRESH] rejected $key=$incomingValue: $error',
            );
          }
          continue;
        }

        final binding = 'device.parameters.$key';
        final previous = _parameters[key];
        try {
          setBinding(binding, incomingValue, dispatch: false);
          if (_parameters[key] != previous) {
            applied++;
            logDebug(
              '[SDUI][PARAM_REFRESH] $key: $previous -> ${_parameters[key]}',
            );
          }
        } catch (error) {
          logDebug(
            '[SDUI][PARAM_REFRESH] rejected $key=$incomingValue: $error',
          );
        }
      }
      logDebug(
        '[SDUI][PARAM_REFRESH] done updated=$applied '
        'skippedPlaceholder=$skippedPlaceholder of=${parameters.length}',
      );
      return applied;
    } catch (error) {
      logDebug('[SDUI][PARAM_REFRESH] failed: $error');
      return 0;
    }
  }

  /// Locates `state.device.parameters` in a full schema document or API wrap.
  static Map<String, dynamic>? _extractDeviceParameters(
    Map<String, dynamic> root,
  ) {
    Map<String, dynamic>? asMap(dynamic value) {
      if (value is Map) {
        return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
      }
      return null;
    }

    Map<String, dynamic>? fromSchema(Map<String, dynamic>? schema) {
      if (schema == null) return null;
      final state = asMap(schema['state']);
      final device = asMap(state?['device']);
      return asMap(device?['parameters']);
    }

    final direct = fromSchema(root);
    if (direct != null && direct.isNotEmpty) return direct;

    final nestedSchema = asMap(root['schema']);
    final fromNested = fromSchema(nestedSchema);
    if (fromNested != null && fromNested.isNotEmpty) return fromNested;

    final data = asMap(root['data']);
    if (data != null) {
      // Production api_schema.php wraps the document as data.schema_json.
      for (final key in const <String>[
        'schema_json',
        'schemaJson',
        'schema',
        'device_ui_schema',
        'deviceUiSchema',
      ]) {
        final nested = fromSchema(asMap(data[key]));
        if (nested != null && nested.isNotEmpty) return nested;
      }
      final fromData = fromSchema(data);
      if (fromData != null && fromData.isNotEmpty) return fromData;

      // Some responses put parameters at data.parameters / data.state.parameters.
      final dataParams = asMap(data['parameters']);
      if (dataParams != null && dataParams.isNotEmpty) return dataParams;
      final dataState = asMap(data['state']);
      final dataDevice = asMap(dataState?['device']);
      final dataDeviceParams = asMap(dataDevice?['parameters']);
      if (dataDeviceParams != null && dataDeviceParams.isNotEmpty) {
        return dataDeviceParams;
      }
    }

    // Live parameter-only payloads may put the map at the root.
    final rootParams = asMap(root['parameters']);
    if (rootParams != null && rootParams.isNotEmpty) return rootParams;

    return null;
  }

  /// True when a schema control declares [alias] as its published parameter name.
  ///
  /// Uses only schema fields (`parameter`, `parameterName`, control id after
  /// `:`, and the first token of the protocol binding key).
  bool _parameterAliasMatches(
    Map<String, dynamic> control,
    String parameterKey,
    String aliasLower,
  ) {
    if (aliasLower.isEmpty) return false;

    String compact(String text) => text
        .toLowerCase()
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'[\s_\-]+'), '');

    final aliasCompact = compact(aliasLower);

    bool same(String? raw) {
      final text = raw?.trim().toLowerCase() ?? '';
      if (text.isEmpty) return false;
      if (text == aliasLower) return true;
      // Cloud keys sometimes use underscores where schema default_name has
      // spaces (`Remote_Address` vs `Remote Address`). Same on both platforms.
      if (compact(text) == aliasCompact) return true;
      // Check parenthesized substring e.g. "Speed (RPM)" matching "rpm" or "Voltage (V)" matching "v"
      final parenMatch = RegExp(r'\(([^)]+)\)').firstMatch(text);
      if (parenMatch != null) {
        final inside = parenMatch.group(1)!.trim().toLowerCase();
        if (inside == aliasLower || compact(inside) == aliasCompact) {
          return true;
        }
      }
      return false;
    }

    // Multi-field command rows (tuning, Remote Pairing, …) publish under
    // `commands[N].default_name` (`Resistance`, `Remote Address`, …). Match
    // that first so one cloud key does not paint every row of the frame.
    final canonicalFrame = _resolveCanonicalDeviceConfigFrame(control);
    final commandField = commandFieldFor(control, canonicalFrame) ??
        (control['commandField'] is Map
            ? Map<String, dynamic>.from(control['commandField'])
            : null);
    if (commandField != null &&
        same(commandField['default_name']?.toString())) {
      return true;
    }
    final responseField = responseFieldFor(control, canonicalFrame) ??
        (control['responseField'] is Map
            ? Map<String, dynamic>.from(control['responseField'])
            : null);
    if (responseField != null) {
      if (same(responseField['default_name']?.toString())) return true;
      if (same(responseField['name']?.toString())) return true;
      if (same(responseField['Field_description']?.toString())) return true;
    }

    if (commandField != null && _frameHasMultipleDataFields(control)) {
      // Shared frame parameter (`tuning`) must not alias every command row.
      return false;
    }

    // A response row belongs to its specific indexed response field.
    // Do not let a shared command name like "Command Get Status" alias every response row!
    if (responseField != null) {
      return false;
    }

    if (same(control['parameter']?.toString())) return true;
    if (same(control['parameterName']?.toString())) return true;
    if (same(control['label']?.toString())) return true;
    if (same(control['name']?.toString())) return true;
    if (same(control['title']?.toString())) return true;
    if (same(control['protocolMeta']?['parameter']?.toString())) return true;
    if (same(control['protocolMeta']?['name']?.toString())) return true;

    final id = control['id']?.toString() ?? '';
    final colon = id.lastIndexOf(':');
    if (colon >= 0 && colon < id.length - 1 && same(id.substring(colon + 1))) {
      return true;
    }
    final dashNameMatch =
        RegExp(r'(?:response|command)-\d+-(.+)$').firstMatch(id);
    if (dashNameMatch != null && same(dashNameMatch.group(1))) {
      return true;
    }

    final firstToken = parameterKey.toLowerCase().split('_').firstWhere(
          (part) => part.isNotEmpty && int.tryParse(part) == null,
          orElse: () => '',
        );
    if (firstToken == aliasLower) return true;

    return false;
  }

  static final RegExp _responseControlId =
      RegExp(r'(?::|[-_])(?:response|resp)[-_](\d+)(?:[-_]|$)');
  static final RegExp _commandControlId =
      RegExp(r'(?::|[-_])(?:command|cmd)[-_](\d+)(?:[-_]|$)');

  /// A generated response row, addressed by the schema id `…:response-N-…`.
  static bool isResponseControl(Map<String, dynamic> control) {
    return _responseControlId.hasMatch(control['id']?.toString() ?? '');
  }

  /// A generated command row, addressed by the schema id `…:command-N-…`.
  static bool isCommandControl(Map<String, dynamic> control) {
    return _commandControlId.hasMatch(control['id']?.toString() ?? '');
  }

  /// `deviceFrame.commands[N]` for a command row. Index N is the schema id.
  static Map<String, dynamic>? commandFieldFor(
    Map<String, dynamic> control, [
    Map<String, dynamic>? fallbackFrame,
  ]) {
    var match = _commandControlId.firstMatch(control['id']?.toString() ?? '');
    match ??= _commandControlId.firstMatch(control['binding']?.toString() ?? '');
    if (match == null) return null;
    final index = int.tryParse(match.group(1) ?? '');
    if (index == null) return null;
    final frame = control['deviceFrame'] ??
        control['deviceConfigFrame'] ??
        control['protocolMeta']?['frame'] ??
        fallbackFrame;
    if (frame is! Map) return null;
    final commands = frame['commands'];
    if (commands is! List || commands.isEmpty) return null;

    // 1. Exact index match
    if (index >= 0 && index < commands.length) {
      final field = commands[index];
      if (field is Map) {
        return Map<String, dynamic>.from(field.cast<dynamic, dynamic>());
      }
    }

    // 2. Modulo index match (for offset control IDs like command-21 with 19 commands)
    if (index >= commands.length) {
      final modIndex = index % commands.length;
      final field = commands[modIndex];
      if (field is Map) {
        return Map<String, dynamic>.from(field.cast<dynamic, dynamic>());
      }
    }

    // 3. Match by field_index inside command field
    for (final raw in commands) {
      if (raw is Map) {
        final fIdx = raw['field_index'] ?? raw['index'] ?? raw['command_index'];
        if (fIdx != null &&
            (fIdx == index || fIdx.toString() == index.toString())) {
          return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
        }
      }
    }

    // 4. Match by label or parameter name against field default_name / name
    final label = _frameLabel(control).trim().toLowerCase();
    if (label.isNotEmpty && label != 'data') {
      for (final raw in commands) {
        if (raw is Map) {
          final defName =
              raw['default_name']?.toString().trim().toLowerCase() ?? '';
          final name = raw['name']?.toString().trim().toLowerCase() ?? '';
          if ((defName.isNotEmpty && defName == label) ||
              (name.isNotEmpty && name == label)) {
            return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
          }
        }
      }
    }

    return null;
  }

  /// True when a frame publishes more than one `Data` command field.
  ///
  /// Those frames share one `parameter` name across many control rows; cloud
  /// keys and captions must use each field's `default_name` instead.
  static bool _frameHasMultipleDataFields(
    Map<String, dynamic> control, [
    Map<String, dynamic>? fallbackFrame,
  ]) {
    final frame = control['deviceFrame'] ??
        control['deviceConfigFrame'] ??
        control['protocolMeta']?['frame'] ??
        fallbackFrame;
    if (frame is! Map) return false;
    final commands = frame['commands'];
    if (commands is! List) return false;
    var count = 0;
    for (final raw in commands) {
      if (raw is! Map) continue;
      final description =
          raw['Field_description']?.toString().trim().toLowerCase() ?? '';
      if (description != 'data') continue;
      count += 1;
      if (count > 1) return true;
    }
    return false;
  }

  /// Binding owned by a multi-field command row (`…:command-N-…`).
  bool _isMultiFieldCommandBinding(String parameterKey) {
    if (parameterKey.isEmpty) return false;
    for (final ctrl in controls) {
      final key = parameterKeyForBinding(ctrl['binding']?.toString() ?? '');
      if (key != parameterKey) continue;
      final canonical = _resolveCanonicalDeviceConfigFrame(ctrl);
      return commandFieldFor(ctrl, canonical) != null &&
          _frameHasMultipleDataFields(ctrl, canonical);
    }
    return false;
  }

  /// True when [value] is still a protocol field name or placeholder in the frame
  /// rather than an actual reading or user setting.
  ///
  /// Multi-page schemas from server snapshots often store field names
  /// (`Speed1`, `Resistance`, `Remote Key Speed 5`, `Mortgage_Time`, `Voltage`, `rpm`)
  /// or placeholders (`[]`, `"--"`, `OFF`, `null`) instead of the true `asperui_value`.
  /// Treat these as unset placeholders so seeding and display can replace them with
  /// live readings or frame defaults.
  static bool isFrameFieldNameOrPlaceholder(
    Map<String, dynamic> control,
    dynamic value,
  ) {
    if (value == null) return true;
    if (isUnsetTelemetryValue(value)) return true;

    final valText = value.toString().trim();
    if (valText.isEmpty ||
        valText == '[]' ||
        valText == '[""]' ||
        valText == '--' ||
        RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(valText)) {
      return true;
    }

    final lowerVal = valText.toLowerCase();

    // Check control's own field first
    final cmd = commandFieldFor(control);
    if (cmd != null) {
      final name = cmd['default_name']?.toString().trim() ?? '';
      if (name.isNotEmpty && readingsAreEqual(value, name)) return true;
    }
    final resp = responseFieldFor(control);
    if (resp != null) {
      final name = resp['default_name']?.toString().trim() ?? '';
      if (name.isNotEmpty && readingsAreEqual(value, name)) return true;
      // If the response row expects a numeric reading (asperui_value is numeric),
      // a non-numeric string like "OFF" or "Display" is an uninitialized placeholder.
      // But for boolean, switch, or power status controls, "OFF" is a valid state.
      final asperui = resp['asperui_value'];
      final expectsNumeric =
          asperui != null && num.tryParse(asperui.toString().trim()) != null;
      if (expectsNumeric && (lowerVal == 'off' || lowerVal == 'display')) {
        return true;
      }
    }

    // Check all commands and response fields in the control's deviceFrame
    final frame = control['deviceFrame'];
    if (frame is Map) {
      final commands = frame['commands'];
      if (commands is List) {
        for (final item in commands) {
          if (item is! Map) continue;
          final name = item['default_name']?.toString().trim() ?? '';
          final lower = name.toLowerCase();
          if (name.isNotEmpty && lower != 'data' && lower != 'none') {
            if (readingsAreEqual(value, name)) return true;
          }
        }
      }
      final response = frame['response'];
      if (response is List) {
        for (final item in response) {
          if (item is! Map) continue;
          final name = item['default_name']?.toString().trim() ?? '';
          final lower = name.toLowerCase();
          if (name.isNotEmpty && lower != 'data' && lower != 'none') {
            if (readingsAreEqual(value, name)) return true;
          }
        }
      }
    }

    // Check declared control placeholders
    for (final raw in <dynamic>[
      control['value'],
      control['label'],
      control['parameter'],
      control['parameterName'],
    ]) {
      final name = raw?.toString().trim() ?? '';
      if (name.isNotEmpty && readingsAreEqual(value, name)) return true;
    }

    return false;
  }

  /// True when [value] is still the protocol field name rather than a reading.
  static bool isCommandFieldNamePlaceholder(
    Map<String, dynamic> control,
    dynamic value,
  ) {
    return isFrameFieldNameOrPlaceholder(control, value);
  }

  /// `deviceFrame.response[N]` for a response row. Index N is the schema id.
  static Map<String, dynamic>? responseFieldFor(
    Map<String, dynamic> control, [
    Map<String, dynamic>? fallbackFrame,
  ]) {
    var match = _responseControlId.firstMatch(control['id']?.toString() ?? '');
    match ??= _responseControlId.firstMatch(control['binding']?.toString() ?? '');
    if (match == null) return null;
    final index = int.tryParse(match.group(1) ?? '');
    if (index == null) return null;
    final frame = control['deviceFrame'] ??
        control['deviceConfigFrame'] ??
        control['protocolMeta']?['frame'] ??
        fallbackFrame;
    if (frame is! Map) return null;
    final response = frame['response'];
    if (response is! List || response.isEmpty) return null;

    // 1. Exact index match
    if (index >= 0 && index < response.length) {
      final field = response[index];
      if (field is Map) {
        return Map<String, dynamic>.from(field.cast<dynamic, dynamic>());
      }
    }

    // 2. Modulo index match (for offset response IDs)
    if (index >= response.length) {
      final modIndex = index % response.length;
      final field = response[modIndex];
      if (field is Map) {
        return Map<String, dynamic>.from(field.cast<dynamic, dynamic>());
      }
    }

    // 3. Match by field_index inside response field
    for (final raw in response) {
      if (raw is Map) {
        final fIdx =
            raw['field_index'] ?? raw['index'] ?? raw['response_index'];
        if (fIdx != null &&
            (fIdx == index || fIdx.toString() == index.toString())) {
          return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
        }
      }
    }

    // 4. Match by label or parameter name against field default_name / name
    final label = _frameLabel(control).trim().toLowerCase();
    if (label.isNotEmpty && label != 'data') {
      for (final raw in response) {
        if (raw is Map) {
          final defName =
              raw['default_name']?.toString().trim().toLowerCase() ?? '';
          final name = raw['name']?.toString().trim().toLowerCase() ?? '';
          if ((defName.isNotEmpty && defName == label) ||
              (name.isNotEmpty && name == label)) {
            return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
          }
        }
      }
    }

    return null;
  }

  /// Finds the declared device frame for a parameter binding by searching
  /// controls, schema deviceConfig, and node_details.
  Map<String, dynamic>? _findDeviceFrameForBinding(String parameterKey) {
    for (final ctrl in controls) {
      if (parameterKeyForBinding(ctrl['binding']?.toString() ?? '') ==
          parameterKey) {
        final frame = ctrl['deviceFrame'] ??
            ctrl['deviceConfigFrame'] ??
            ctrl['protocolMeta']?['frame'] ??
            _resolveCanonicalDeviceConfigFrame(ctrl);
        if (frame is Map) return Map<String, dynamic>.from(frame);
      }
    }

    final deviceConfig = _schema['deviceConfig'];
    if (deviceConfig is Map) {
      final devices = deviceConfig['devices'];
      if (devices is List) {
        for (final rawDev in devices.whereType<Map>()) {
          final pages = rawDev['pages'];
          if (pages is Map) {
            for (final pageVal in pages.values) {
              if (pageVal is Map) {
                for (final frameVal in pageVal.values) {
                  if (frameVal is Map && frameVal['response'] is List) {
                    return Map<String, dynamic>.from(frameVal);
                  }
                }
              }
            }
          }
        }
      }
    }

    final nodeDetails = _schema['node_details'];
    if (nodeDetails is List) {
      for (final rawNode in nodeDetails.whereType<Map>()) {
        final config = rawNode['config'];
        if (config is Map && config['devices'] is List) {
          for (final rawDev in (config['devices'] as List).whereType<Map>()) {
            final pages = rawDev['pages'];
            if (pages is Map) {
              for (final pageVal in pages.values) {
                if (pageVal is Map) {
                  for (final frameVal in pageVal.values) {
                    if (frameVal is Map && frameVal['response'] is List) {
                      return Map<String, dynamic>.from(frameVal);
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    return null;
  }

  /// The command frame publishes `trigger_ui` with a true entry when its
  /// response rows stay hidden until that trigger is on.
  static bool frameRevealsResponseRows(Map<String, dynamic> control) {
    if (control['revealsResponse'] == true ||
        control['revealsResponseRows'] == true ||
        control['frameRevealsResponseRows'] == true ||
        control['expandable'] == true ||
        control['revealBinding'] != null) {
      return true;
    }
    final frame = control['deviceFrame'];
    if (frame is! Map) return false;
    final flags = frame['trigger_ui'];
    if (flags is! List) return false;
    for (final flag in flags) {
      if (flag == true) return true;
      if (flag?.toString().trim().toLowerCase() == 'true') return true;
    }
    return false;
  }

  static bool telemetryIsOn(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'on' ||
        text == 'true' ||
        text == 'yes' ||
        text == '1' ||
        text == '01';
  }

  /// Bindings that open or close a terminal console.
  List<Listenable> logGateListenables() {
    final gates = <Listenable>[];
    for (final control in controls) {
      final name = (control['parameter'] ?? control['parameterName'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (!name.contains('log')) continue;
      gates.add(
        listenableForControl(
          id: control['id']?.toString(),
          binding: control['binding']?.toString(),
        ),
      );
    }
    return gates;
  }

  /// Text a field should paint.
  ///
  /// A terminal stays blank while its log gate is off, including the schema
  /// placeholder (`00`, `Display`). A response row shows
  /// `response[N].default_name` until a cloud reading replaces the
  /// placeholder `OFF`.
  String presentedFieldText(Map<String, dynamic> control, String resolved) {
    if (_isTerminalControl(control)) {
      if (!_logGateIsOn()) return '';
      if (_isConsolePlaceholder(resolved, control)) return '';
      return resolved;
    }
    // Never return field['default_name'] as the displayed text inside the box.
    // If the reading is an unset placeholder or frame field name, prefer the frame's
    // default reading (asperui_value / value) if present, or non-placeholder declared values,
    // or empty string.
    if (_responseReadingIsPlaceholder(control, resolved) ||
        isFrameFieldNameOrPlaceholder(control, resolved)) {
      final canonicalFrame = _resolveCanonicalDeviceConfigFrame(control);
      final frameReading = schemaFrameReading(control, canonicalFrame);
      if (frameReading != null &&
          !isUnsetTelemetryValue(frameReading) &&
          !isFrameFieldNameOrPlaceholder(control, frameReading)) {
        return frameReading.toString();
      }
      if (!isResponseControl(control)) {
        final declared = control['initialValue'] ??
            control['value'] ??
            control['component']?['props']?['value'] ??
            control['component']?['props']?['text'] ??
            control['props']?['value'] ??
            control['props']?['text'];
        if (declared != null &&
            !isUnsetTelemetryValue(declared) &&
            !isFrameFieldNameOrPlaceholder(control, declared)) {
          return declared.toString();
        }
      }
      return '';
    }
    return resolved;
  }

  bool _responseReadingIsPlaceholder(Map<String, dynamic> control, String text) {
    if (text.trim().isEmpty || isUnsetTelemetryValue(text)) return true;
    for (final raw in <dynamic>[
      control['value'],
      control['label'],
      control['parameter'],
      control['parameterName'],
    ]) {
      final name = raw?.toString().trim() ?? '';
      if (name.isNotEmpty && readingsAreEqual(text, name)) return true;
    }
    return false;
  }

  /// Writes a remote value without dispatching a command back to the device.
  ///
  /// Remote payloads carry protocol-shaped values, so a value that the schema
  /// rejects for this binding must never take down the cloud message stream.
  bool _applyRemoteBinding(String binding, dynamic value) {
    final key = parameterKeyForBinding(binding);
    if (_keyIsLogGate(key)) {
      final text = value?.toString().trim() ?? '';
      final isToggle = value is bool ||
          text == 'true' ||
          text == 'false' ||
          text == '1' ||
          text == '0' ||
          text == '00' ||
          text == '01' ||
          text.toUpperCase() == 'ON' ||
          text.toUpperCase() == 'OFF';
      if (!isToggle && text.isNotEmpty) {
        _appendTerminalLine(text);
        return true;
      }
    }
    try {
      setBinding(binding, value, dispatch: false);
      return true;
    } catch (error) {
      logDebug('[SDUI][REMOTE_SYNC] rejected $binding=$value: $error');
      return false;
    }
  }

  /// True when [a] and [b] are the same reading.
  ///
  /// `1`, `"1"` and `1.0` match. Protocol codes such as `"01"` stay distinct
  /// from `"1"`. Cloud repeats of the current reading must not rewrite state.
  static bool readingsAreEqual(dynamic a, dynamic b) {
    if (identical(a, b) || a == b) return true;
    if (a == null || b == null) return false;
    final as = a.toString().trim();
    final bs = b.toString().trim();
    if (as == bs) return true;
    final an = num.tryParse(as);
    final bn = num.tryParse(bs);
    if (an != null && bn != null) {
      final padded = RegExp(r'^0\d');
      if (padded.hasMatch(as) || padded.hasMatch(bs)) return false;
      return an == bn;
    }
    return as.toLowerCase() == bs.toLowerCase();
  }

  static dynamic _extractFieldReading(
    Map<String, dynamic>? field,
    String label,
    Map<String, dynamic> control,
  ) {
    if (field == null) return null;
    for (final key in const [
      'asperui_value',
      'asperui',
      'value',
      'default_value',
      'defaultValue',
      'default',
      'val',
    ]) {
      final candidate = field[key];
      if (candidate == null || isUnsetTelemetryValue(candidate)) continue;
      if (label.isNotEmpty && readingsAreEqual(candidate, label)) continue;
      if (isFrameFieldNameOrPlaceholder(control, candidate)) continue;
      return candidate;
    }
    return null;
  }

  /// Extracts the default reading declared in the schema frame.
  ///
  /// Multi-field frames (tuning, Remote Pairing) address one command by the
  /// schema id `…:command-N-…`. Prefer that row's `asperui_value` or default value
  /// so every control does not collapse onto the first Data field.
  static dynamic schemaFrameReading(
    Map<String, dynamic> control, [
    dynamic fallbackFrame,
  ]) {
    final label = _frameLabel(control);
    final fallbackMap = fallbackFrame is Map<String, dynamic>
        ? fallbackFrame
        : (fallbackFrame is Map
            ? Map<String, dynamic>.from(fallbackFrame)
            : null);

    final commandField = commandFieldFor(control, fallbackMap);
    if (commandField != null) {
      final reading = _extractFieldReading(commandField, label, control);
      if (reading != null) return reading;
    }
    final responseField = responseFieldFor(control, fallbackMap);
    if (responseField != null) {
      final reading = responseField['asperui_value'] ?? responseField['asperui'];
      if (reading != null &&
          !isUnsetTelemetryValue(reading) &&
          (label.isEmpty || !readingsAreEqual(reading, label)) &&
          !isFrameFieldNameOrPlaceholder(control, reading)) {
        return reading;
      }
    }
    final frames = <dynamic>[
      control['deviceFrame'],
      control['deviceConfigFrame'],
      control['protocolMeta'] is Map
          ? (control['protocolMeta'] as Map)['frame']
          : null,
      fallbackMap,
    ];
    for (final frame in frames) {
      final reading = dataFieldReading(frame, label);
      if (reading != null) return reading;
    }
    return null;
  }

  static dynamic dataFieldReading(dynamic frame, String label) {
    if (frame is! Map) return null;
    final commands = frame['commands'];
    if (commands is! List) return null;
    for (final raw in commands) {
      if (raw is! Map) continue;
      final description =
          raw['Field_description']?.toString().trim().toLowerCase() ?? '';
      if (description != 'data') continue;
      for (final key in const [
        'asperui_value',
        'asperui',
        'value',
        'default_value',
        'defaultValue',
        'default',
        'val',
      ]) {
        final reading = raw[key];
        if (reading == null || isUnsetTelemetryValue(reading)) continue;
        if (label.isNotEmpty && readingsAreEqual(reading, label)) continue;
        return reading;
      }
    }
    return null;
  }

  static String _frameLabel(Map<String, dynamic> control) {
    for (final raw in <dynamic>[
      control['parameter'],
      control['parameterName'],
      control['deviceFrame'] is Map
          ? (control['deviceFrame'] as Map)['name']
          : null,
    ]) {
      final text = raw?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// Copies schema frame readings into bindings that are still empty or still
  /// showing the parameter name. A different live value is left alone.
  void _seedReadingsFromSchemaFrames() {
    for (final raw in controls) {
      final control = Map<String, dynamic>.from(raw);
      final canonicalFrame = _resolveCanonicalDeviceConfigFrame(control);
      if (canonicalFrame != null) {
        raw['deviceConfigFrame'] ??= canonicalFrame;
        control['deviceConfigFrame'] ??= canonicalFrame;
      }
      final key = parameterKeyForBinding(control['binding']?.toString() ?? '');
      if (key.isEmpty) continue;
      final label = _frameLabel(control);
      final reading = schemaFrameReading(control, canonicalFrame) ??
          dataFieldReading(canonicalFrame, label);
      final declaredFallback = control['initialValue'] ??
          control['value'] ??
          control['component']?['props']?['value'] ??
          control['component']?['props']?['text'] ??
          control['props']?['value'] ??
          control['props']?['text'];
      final effectiveReading = (reading != null && !isUnsetTelemetryValue(reading))
          ? reading
          : (declaredFallback != null &&
                  !isUnsetTelemetryValue(declaredFallback) &&
                  !isFrameFieldNameOrPlaceholder(control, declaredFallback))
              ? declaredFallback
              : null;
      if (effectiveReading == null || isUnsetTelemetryValue(effectiveReading)) {
        continue;
      }
      final current = _parameters[key];
      final currentIsLabel =
          label.isNotEmpty && readingsAreEqual(current, label);
      final currentIsPlaceholder =
          isFrameFieldNameOrPlaceholder(control, current) || currentIsLabel;
      if (!currentIsPlaceholder &&
          !readingsAreEqual(current, effectiveReading)) {
        continue;
      }
      if (readingsAreEqual(current, effectiveReading)) continue;
      try {
        setBinding('device.parameters.$key', effectiveReading, dispatch: false);
      } catch (error) {
        logDebug('[SDUI][SCHEMA_READING] rejected $key=$effectiveReading: $error');
      }
    }
  }

  /// Resolves the canonical reading for a control using the active schema frame.
  dynamic getControlReading(Map<String, dynamic> control) {
    return schemaFrameReading(
      control,
      _resolveCanonicalDeviceConfigFrame(control),
    );
  }

  /// Updates local state immediately and schedules the control's declared
  /// backend action. Existing widgets that call setBinding therefore remain
  /// compatible while gaining server action support.
  void setBinding(String binding, dynamic value, {bool dispatch = true}) {
    if (binding.startsWith('device.parameters.') ||
        binding.startsWith('state.parameters.') ||
        binding.startsWith('parameters.')) {
      if (dispatch && !_isBindingWritable(binding)) {
        logDebug(
          '[DEVICE ACCESS] blocked write to read-only binding=$binding',
        );
        return;
      }

      final validated = _validatedValue(binding, value);
      final key = parameterKeyForBinding(binding);
      final same = readingsAreEqual(_parameters[key], validated);
      if (same && !dispatch) {
        // Cloud repeated the value already on screen. Do not rewrite it.
        logDebug(
          '[SDUI][LIVE_SYNC] no-op $binding already == $validated',
        );
        return;
      }

      if (dispatch) {
        _optimisticPrevious.putIfAbsent(binding, () => _parameters[key]);
        // This client now owns the value until the echo window expires.
        _locallyChangedAt['device.parameters.$key'] = DateTime.now();
      } else {
        // A remote/server value replaces local ownership immediately.
        _locallyChangedAt.remove('device.parameters.$key');
      }
      if (!same) {
        _parameters[key] = validated;
        _notifyParameterChanged(key, originBinding: binding);
        logDebug('[SDUI] update $binding = $validated');
        _scheduleParameterPersist();
        final control = controlForBinding(binding);
        final revealBinding = control?['revealBinding']?.toString().trim();
        if (revealBinding != null && revealBinding.isNotEmpty && revealBinding != binding) {
          _runtimeState[revealBinding] = validated;
          _tickChannel('b:$revealBinding');
        }
      }

      if (dispatch) {
        _scheduleControlAction(binding);
      }
      if (!same && _keyIsLogGate(key) && _telemetryIsOn(validated)) {
        _appendLiveSnapshotToConsole();
        if (dispatch) unawaited(refreshLiveNodeParams());
      }
      return;
    }

    if (binding == 'state.activePageIndex') {
      if (value is! num) {
        throw const FormatException('activePageIndex requires a number.');
      }
      activePageIndex = value.toInt();
      return;
    }

    if (binding == 'state.scanResult.value' ||
        binding.startsWith('state.scanResult.')) {
      final key = binding == 'state.scanResult.value'
          ? 'value'
          : binding.substring('state.scanResult.'.length);
      if (_scanResult[key] == value) return;
      _scanResult[key] = value;
      notifyListeners();
      logDebug('[SDUI] update $binding = $value');
      return;
    }

    if (binding == 'state.wifiConfig' && value is Map) {
      _wifiConfig
        ..clear()
        ..addAll(Map<String, dynamic>.from(value))
        ..['deviceIp'] = value['deviceIp'] ?? value['device_ip'];

      final connected = value['connected'];
      if (connected is bool) {
        _runtimeOnline = connected;
      }

      notifyListeners();
      return;
    }

    if (binding.startsWith('state.wifiConfig.')) {
      final rawKey = binding.substring('state.wifiConfig.'.length);
      final key = rawKey == 'device_ip' ? 'deviceIp' : rawKey;
      if (_wifiConfig[key] == value) return;

      _wifiConfig[key] = value;
      if (key == 'connected' && value is bool) {
        _runtimeOnline = value;
      }

      notifyListeners();
      return;
    }

    if (binding.startsWith('state.')) {
      if (_runtimeState[binding] == value) return;
      _runtimeState[binding] = value;
      _tickChannel('b:$binding');
      notifyListeners();
      logDebug('[SDUI] update $binding = $value');
      for (final c in controls) {
        if (c['revealBinding']?.toString().trim() == binding) {
          final cBinding = c['binding']?.toString().trim();
          if (cBinding != null && cBinding.isNotEmpty && cBinding != binding) {
            setBinding(cBinding, value, dispatch: false);
          }
          break;
        }
      }
      return;
    }
  }

  Map<String, dynamic>? controlForBinding(String binding) {
    for (final control in controls) {
      if (control['binding']?.toString() == binding) return control;
    }
    return null;
  }

  bool _isBindingWritable(String binding) {
    final matching = controls
        .where((control) => control['binding']?.toString() == binding)
        .toList();
    if (matching.isEmpty) return true;

    final declared = matching.where(
      (control) => _controlAccess(control) != null,
    );
    if (declared.isEmpty) {
      return true; // preserve schemas with no access contract
    }
    return declared.any(_isControlWritable);
  }

  String? _controlAccess(Map<String, dynamic> control) {
    final protocolMeta = control['protocolMeta'] as Map?;
    final direct = control['access']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final protocol = protocolMeta?['access']?.toString().trim();
    if (protocol != null && protocol.isNotEmpty) return protocol;

    final frame = control['deviceFrame'] as Map?;
    final commands = frame?['commands'] as List?;
    if (commands != null) {
      for (final raw in commands.whereType<Map>()) {
        final value = raw['ui_description']?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  bool isBindingWritable(String binding) => _isBindingWritable(binding);

  bool _isControlWritable(Map<String, dynamic> control) {
    if (control['writable'] == false || control['readOnly'] == true) {
      return false;
    }
    final compProps = control['component']?['props'];
    if (compProps is Map && compProps['sendButton'] is Map) {
      final sb = compProps['sendButton'];
      if (sb['visible'] != false &&
          sb['visible']?.toString().toLowerCase() != 'false') {
        return true;
      }
    }
    final access = _controlAccess(control);
    if (access == null) return control['interactive'] != false;
    final normalized = access.toLowerCase().replaceAll(' ', '');
    return normalized.contains('write');
  }

  static final RegExp _protocolByte = RegExp(r'^[0-9a-f]{1,2}$');

  /// Reads a boolean out of the text forms a device or backend may send.
  ///
  /// Returns null when the text is not a boolean in any recognised spelling, so
  /// callers can leave non-boolean values (enum options such as "00"/"01" on a
  /// direction control) untouched. Device frames carry zero padded protocol
  /// bytes, so "00" is false and any other byte is true.
  static bool? _booleanFromProtocolText(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;

    switch (text) {
      case 'true':
      case 'on':
      case 'yes':
        return true;
      case 'false':
      case 'off':
      case 'no':
        return false;
    }

    if (_protocolByte.hasMatch(text)) {
      return int.parse(text, radix: 16) != 0;
    }

    return null;
  }

  dynamic _validatedValue(String binding, dynamic value) {
    final matchingControls = controls
        .where((control) => control['binding']?.toString() == binding)
        .toList();

    var coerced = value;
    if (matchingControls.isNotEmpty) {
      final control = matchingControls.first;
      final isApiGenerated =
          control['componentTypeSource']?.toString().toLowerCase() == 'api' ||
              control['apiComponentKey'] != null;
      final type = isApiGenerated
          ? _typeForComponent(control['componentType']?.toString())
          : (control['valueType']?.toString() ??
              _typeForComponent(control['componentType']?.toString()));

      if (type == 'boolean') {
        if (coerced is String) {
          final parsed = _booleanFromProtocolText(coerced);
          if (parsed != null) coerced = parsed;
        } else if (coerced is num) {
          coerced = coerced != 0;
        }
      } else if (type == 'number') {
        if (coerced is String) {
          final parsed = num.tryParse(coerced.trim());
          if (parsed != null) coerced = parsed;
        } else if (coerced is bool) {
          coerced = coerced ? 1 : 0;
        }
      } else if (type == 'enum') {
        final matched = resolveEnumOption(control, coerced);
        if (matched != null && matched['value'] != null) {
          coerced = matched['value'];
        }
      } else if (type == 'string') {
        if (coerced != null && coerced is! String) {
          coerced = coerced.toString();
        }
      }
    } else {
      if (coerced is String) {
        final s = coerced.trim().toLowerCase();
        if (s == 'true' || s == 'on') {
          coerced = true;
        } else if (s == 'false' || s == 'off') {
          coerced = false;
        }
      }
    }

    _isValidValue(binding, coerced, throwOnError: true);
    return coerced;
  }

  bool _isValidValue(
    String binding,
    dynamic value, {
    required bool throwOnError,
  }) {
    final matchingControls = controls
        .where((control) => control['binding']?.toString() == binding)
        .toList();
    if (matchingControls.isEmpty) return true;

    bool accepts(Map<String, dynamic> control) {
      final isApiGenerated =
          control['componentTypeSource']?.toString().toLowerCase() == 'api' ||
              control['apiComponentKey'] != null;
      final type = isApiGenerated
          ? _typeForComponent(control['componentType']?.toString())
          : (control['valueType']?.toString() ??
              _typeForComponent(control['componentType']?.toString()));
      switch (type) {
        case 'boolean':
          if (value is bool) return true;
          if (value is String) return _booleanFromProtocolText(value) != null;
          if (value is num) return true;
          return false;
        case 'number':
          num? numericValue;
          if (value is num) {
            numericValue = value;
          } else if (value is String) {
            numericValue = num.tryParse(value.trim());
            if (numericValue == null) return false;
          } else {
            return false;
          }
          final constraints = control['constraints'] as Map? ?? const {};
          final min = constraints['minimum'] as num?;
          final max = constraints['maximum'] as num?;
          if (numericValue == 0) return true;
          return (min == null || numericValue >= min) &&
              (max == null || numericValue <= max);
        case 'enum':
          final options = _optionsFor(control);
          return options.isEmpty || resolveEnumOption(control, value) != null;
        case 'string':
          return value is String;
        case 'trigger':
          return true;
        default:
          return true;
      }
    }

    // The updated API schema may expose command/response/error components as
    // separate controls that intentionally share one protocol binding. Accept
    // a value when any declaration for that binding accepts it.
    if (matchingControls.any(accepts)) return true;

    final control = matchingControls.first;
    void fail(String message) {
      if (throwOnError) throw FormatException(message);
    }

    final type = control['valueType']?.toString() ??
        _typeForComponent(control['componentType']?.toString());

    switch (type) {
      case 'boolean':
        if (value is! bool &&
            value is! num &&
            (value is! String ||
                !['true', 'false', '1', '0', 'on', 'off', 'yes', 'no']
                    .contains(value.trim().toLowerCase()))) {
          fail('${control['id']} requires a Boolean value.');
          return false;
        }
        break;
      case 'number':
        num? numeric;
        if (value is num) {
          numeric = value;
        } else if (value is String) {
          numeric = num.tryParse(value.trim());
        }
        if (numeric == null) {
          fail('${control['id']} requires a number.');
          return false;
        }
        final constraints = control['constraints'] as Map? ?? const {};
        final min = constraints['minimum'] as num?;
        final max = constraints['maximum'] as num?;
        if (min != null && numeric < min) {
          if (numeric != 0) {
            fail('${control['id']} value is below $min.');
            return false;
          }
        }
        if (max != null && numeric > max) {
          fail('${control['id']} value is above $max.');
          return false;
        }
        break;
      case 'enum':
        final options = _optionsFor(control);
        if (options.isNotEmpty &&
            !options.any((option) => _enumOptionMatches(option['value'], value))) {
          fail('${control['id']} enum value is not in options.');
          return false;
        }
        break;
      case 'string':
        if (value is! String) {
          fail('${control['id']} requires a string.');
          return false;
        }
        break;
    }
    return true;
  }

  String _typeForComponent(String? type) {
    final normalized = type?.toString().trim().toLowerCase() ?? '';
    switch (normalized) {
      case 'switch':
      case 'button':
        return 'boolean';
      case 'slider':
      case 'powergauge':
      case 'needlegauge':
      case 'lineargauge':
        return 'number';
      case 'segmented':
      case 'buttongroup':
      case 'dropdown':
      case 'drop down':
      case 'select':
      case 'combobox':
        return 'enum';
      case 'textfield':
      case 'value':
        return 'string';
      default:
        return 'string';
    }
  }

  /// Extracts bracket tokens from bracket protocol strings like `"[OFF][WHITE][RED][GREEN][BLUE]"`
  /// or from lists of bracket strings.
  static List<String> extractBracketTokens(dynamic raw) {
    if (raw == null) return const [];
    final output = <String>[];
    void collect(dynamic value) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }
      if (value == null) return;
      final text = value.toString().trim();
      if (text.isEmpty) return;
      final matches = RegExp(r'\[([^\]]*)\]').allMatches(text).toList();
      if (matches.isNotEmpty) {
        for (final match in matches) {
          final token = match.group(1)?.trim() ?? '';
          if (token.isNotEmpty) output.add(token);
        }
        return;
      }
      output.add(text);
    }
    collect(raw);
    return output;
  }

  /// Parses and normalizes enum / dropdown options from any format into a clean
  /// `List<Map<String, dynamic>>` where each option has `{label: ..., value: ...}`.
  /// Handles:
  /// - Concatenated bracket strings: `"[OFF][WHITE][RED][GREEN][BLUE]"`
  /// - Lists of maps with bracket labels: `[{"label": "[OFF][WHITE]...", "value": "[00][01]..."}]`
  /// - Lists of raw strings: `["[OFF]", "[WHITE]"]` or `["OFF", "WHITE"]`
  /// - Protocol tokens paired with value tokens
  static List<Map<String, dynamic>> normalizeEnumOptions(
    dynamic rawOptions, {
    dynamic rawValues,
  }) {
    if (rawOptions == null) return const [];

    String formatIndexValue(int index, int totalCount) {
      if (totalCount > 16) {
        return index.toRadixString(16).padLeft(2, '0').toUpperCase();
      }
      return index.toString().padLeft(2, '0');
    }

    if (rawOptions is List && rawOptions.isNotEmpty) {
      final mapList = rawOptions.whereType<Map>().toList();
      if (mapList.isNotEmpty) {
        final result = <Map<String, dynamic>>[];
        bool hadBrackets = false;

        for (final raw in mapList) {
          final item = Map<String, dynamic>.from(raw);
          final label = (item['label'] ?? item['text'] ?? item['title'])
                  ?.toString()
                  .trim() ??
              '';
          final val = item['value'];

          final labelTokens = extractBracketTokens(label);
          final valTokens = extractBracketTokens(val);

          if (labelTokens.length > 1) {
            hadBrackets = true;
            for (var i = 0; i < labelTokens.length; i++) {
              final subLabel = labelTokens[i];
              final subVal = i < valTokens.length
                  ? valTokens[i]
                  : formatIndexValue(i, labelTokens.length);
              result.add(<String, dynamic>{
                ...item,
                'label': subLabel,
                'value': subVal,
              });
            }
          } else if (labelTokens.length == 1 &&
              RegExp(r'^\[.*\]$').hasMatch(label)) {
            hadBrackets = true;
            final cleanLabel = labelTokens.first;
            final cleanVal = valTokens.isNotEmpty ? valTokens.first : val;
            result.add(<String, dynamic>{
              ...item,
              'label': cleanLabel,
              'value': cleanVal,
            });
          } else {
            result.add(item);
          }
        }

        final hasClean = result.any((item) =>
            !RegExp(r'^\[\d+\]').hasMatch(item['label']?.toString() ?? ''));
        if (hasClean || hadBrackets) {
          return result;
        }
      }

      final labelTokens = extractBracketTokens(rawOptions);
      if (labelTokens.isNotEmpty) {
        final valTokens = extractBracketTokens(rawValues);
        final result = <Map<String, dynamic>>[];
        for (var i = 0; i < labelTokens.length; i++) {
          final lbl = labelTokens[i];
          final val = i < valTokens.length
              ? valTokens[i]
              : formatIndexValue(i, labelTokens.length);
          result.add(<String, dynamic>{
            'label': lbl,
            'value': val,
          });
        }
        return result;
      }
    }

    if (rawOptions is String && rawOptions.trim().isNotEmpty) {
      final labelTokens = extractBracketTokens(rawOptions);
      if (labelTokens.isNotEmpty) {
        final valTokens = extractBracketTokens(rawValues);
        final result = <Map<String, dynamic>>[];
        for (var i = 0; i < labelTokens.length; i++) {
          final lbl = labelTokens[i];
          final val = i < valTokens.length
              ? valTokens[i]
              : formatIndexValue(i, labelTokens.length);
          result.add(<String, dynamic>{
            'label': lbl,
            'value': val,
          });
        }
        return result;
      }
    }

    return const [];
  }

  /// Resolves clean enum/dropdown options for a control from all available schema sources:
  /// control.props.options, widgetTree.options, control.options, protocolMeta.items, or deviceFrame.
  static List<Map<String, dynamic>> optionsFor(Map<String, dynamic> control) {
    final rawTreeProps =
        control['component'] is Map && control['component']['widgetTree'] is Map && control['component']['widgetTree']['properties'] is Map
            ? control['component']['widgetTree']['properties']['props']
            : null;
    final treeProps = rawTreeProps is Map ? rawTreeProps : null;
    final controlProps = control['props'] is Map ? control['props'] as Map : null;
    final compProps = control['component'] is Map && control['component']['props'] is Map
        ? control['component']['props'] as Map
        : null;

    final candidates = <dynamic>[
      controlProps?['options'],
      treeProps?['options'],
      compProps?['options'],
      control['options'],
      control['component'] is Map ? control['component']['options'] : null,
      control['rightAccessory'] is Map ? control['rightAccessory']['options'] : null,
    ];

    final treeChildren =
        control['component'] is Map && control['component']['widgetTree'] is Map && control['component']['widgetTree']['children'] is List
            ? control['component']['widgetTree']['children'] as List
            : null;
    final directChildren = control['widgetTree'] is Map && control['widgetTree']['children'] is List
        ? control['widgetTree']['children'] as List
        : null;
    for (final list in [treeChildren, directChildren]) {
      if (list != null) {
        for (final ch in list) {
          if (ch is Map) {
            final rawChProps = (ch['properties'] is Map ? ch['properties']['props'] : null) ?? ch['props'];
            final chProps = rawChProps is Map ? rawChProps : null;
            if (chProps?['options'] != null) {
              candidates.add(chProps!['options']);
            }
          }
        }
      }
    }

    List<Map<String, dynamic>>? resolved;
    for (final candidate in candidates) {
      final normalized = normalizeEnumOptions(candidate);
      if (normalized.isNotEmpty) {
        final hasMeaningful = normalized.any((item) =>
            !RegExp(r'^\[\d+\]').hasMatch(item['label']?.toString() ?? ''));
        if (hasMeaningful) {
          resolved = normalized;
          break;
        }
      }
    }

    final meta = control['protocolMeta'] as Map?;
    if (resolved == null && meta != null) {
      final items = meta['items'];
      final itemValues = meta['item_values'] ?? meta['sno_asperui'];
      final fromMeta = normalizeEnumOptions(items, rawValues: itemValues);
      if (fromMeta.isNotEmpty) resolved = fromMeta;

      if (resolved == null) {
        final uiComponents = meta['ui_components'];
        if (uiComponents is List) {
          for (final raw in uiComponents) {
            if (raw is Map) {
              final fromUi = normalizeEnumOptions(
                raw['items'],
                rawValues: raw['item_values'] ?? raw['sno_asperui'],
              );
              if (fromUi.isNotEmpty) {
                resolved = fromUi;
                break;
              }
            }
          }
        }
      }
    }

    if (resolved == null) {
      final frame = control['deviceFrame'] as Map?;
      if (frame != null) {
        final commands = frame['commands'];
        if (commands is List) {
          for (final cmd in commands) {
            if (cmd is Map && cmd['asperui'] != null) {
              final fromCmd = normalizeEnumOptions(
                cmd['asperui'],
                rawValues: cmd['asperui_values'] ?? cmd['sno_asperui'],
              );
              if (fromCmd.isNotEmpty) {
                resolved = fromCmd;
                break;
              }
            }
          }
        }
      }
    }

    if (resolved == null) {
      for (final candidate in candidates) {
        final normalized = normalizeEnumOptions(candidate);
        if (normalized.isNotEmpty) {
          resolved = normalized;
          break;
        }
      }
    }

    if (resolved == null || resolved.isEmpty) return const [];
    return _enrichOptionsWithProtocolAliases(resolved, control);
  }

  /// Attaches sno / label / payload aliases so live status indices (e.g. `02`)
  /// match command dropdown hex values (e.g. `0000020150DC…`) and labels (`FRY`).
  static List<Map<String, dynamic>> _enrichOptionsWithProtocolAliases(
    List<Map<String, dynamic>> options,
    Map<String, dynamic> control,
  ) {
    final meta = control['protocolMeta'] as Map? ?? const <String, dynamic>{};
    final labels = extractBracketTokens(meta['items']);
    final payloads = extractBracketTokens(meta['item_values']);
    final sno = extractBracketTokens(meta['sno_asperui']);

    final frame = control['deviceFrame'] as Map?;
    List<String> frameLabels = const [];
    List<String> frameValues = const [];
    List<String> frameSno = const [];
    if (frame != null) {
      final commands = frame['commands'];
      if (commands is List) {
        for (final cmd in commands) {
          if (cmd is! Map) continue;
          final fl = extractBracketTokens(cmd['asperui']);
          final fv = extractBracketTokens(cmd['asperui_values']);
          final fs = extractBracketTokens(cmd['sno_asperui']);
          if (fl.isNotEmpty || fv.isNotEmpty || fs.isNotEmpty) {
            frameLabels = fl;
            frameValues = fv;
            frameSno = fs;
            break;
          }
        }
      }
    }

    final aliasLabels = labels.isNotEmpty ? labels : frameLabels;
    final aliasPayloads = payloads.isNotEmpty ? payloads : frameValues;
    final aliasSno = sno.isNotEmpty ? sno : frameSno;
    if (aliasLabels.isEmpty && aliasPayloads.isEmpty && aliasSno.isEmpty) {
      return options;
    }

    final enriched = <Map<String, dynamic>>[];
    for (var i = 0; i < options.length; i++) {
      final option = Map<String, dynamic>.from(options[i]);
      final aliases = <String>{};
      void addAlias(dynamic raw) {
        final text = raw?.toString().trim() ?? '';
        if (text.isEmpty) return;
        if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(text)) return;
        aliases.add(text);
      }

      addAlias(option['label']);
      addAlias(option['value']);
      if (i < aliasLabels.length) addAlias(aliasLabels[i]);
      if (i < aliasPayloads.length) addAlias(aliasPayloads[i]);
      if (i < aliasSno.length) addAlias(aliasSno[i]);

      // Drop the canonical value from aliases to avoid duplicate work.
      final canonical = option['value']?.toString().trim();
      if (canonical != null) aliases.remove(canonical);
      if (aliases.isNotEmpty) {
        option['aliases'] = aliases.toList(growable: false);
      }
      if (i < aliasSno.length &&
          (option['sno'] == null || option['sno'].toString().trim().isEmpty)) {
        option['sno'] = aliasSno[i];
      }
      enriched.add(option);
    }
    return enriched;
  }

  List<Map<String, dynamic>> _optionsFor(Map<String, dynamic> control) =>
      optionsFor(control);

  /// Resolves an incoming live / UI value onto a single option, matching
  /// option value, label, sno, payload aliases, and protocolMeta parallel arrays.
  static Map<String, dynamic>? resolveEnumOption(
    Map<String, dynamic> control,
    dynamic value,
  ) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(text)) return null;

    final options = optionsFor(control);
    for (final option in options) {
      if (enumOptionEntryMatches(option, value)) return option;
    }

    final meta = control['protocolMeta'] as Map?;
    if (meta == null) return null;
    final labels = extractBracketTokens(meta['items']);
    final payloads = extractBracketTokens(meta['item_values']);
    final sno = extractBracketTokens(meta['sno_asperui']);
    final count = [labels.length, payloads.length, sno.length, options.length]
        .fold<int>(0, (max, n) => n > max ? n : max);
    for (var i = 0; i < count; i++) {
      final candidates = <dynamic>[
        if (i < labels.length) labels[i],
        if (i < payloads.length) payloads[i],
        if (i < sno.length) sno[i],
      ];
      if (!candidates.any((c) => _enumOptionMatches(c, value))) continue;
      if (i < options.length) return options[i];
      return <String, dynamic>{
        'label': i < labels.length ? labels[i] : text,
        'value': i < payloads.length
            ? payloads[i]
            : (i < sno.length ? sno[i] : text),
        if (i < sno.length) 'sno': sno[i],
      };
    }
    return null;
  }

  static bool enumOptionEntryMatches(
    Map<String, dynamic> option,
    dynamic incomingValue,
  ) {
    if (_enumOptionMatches(option['value'], incomingValue) ||
        _enumOptionMatches(option['label'], incomingValue) ||
        _enumOptionMatches(option['sno'], incomingValue) ||
        _enumOptionMatches(option['runtimeValue'], incomingValue)) {
      return true;
    }
    final aliases = option['aliases'];
    if (aliases is List) {
      for (final alias in aliases) {
        if (_enumOptionMatches(alias, incomingValue)) return true;
      }
    }
    return false;
  }

  static bool _enumOptionMatches(dynamic optionValue, dynamic incomingValue) {
    if (optionValue == incomingValue) return true;
    if (optionValue == null || incomingValue == null) return false;
    final optStr = optionValue.toString().trim().toLowerCase();
    final incStr = incomingValue.toString().trim().toLowerCase();
    if (optStr == incStr) return true;

    // Concatenated bracket protocol strings (e.g. [OFF][WHITE]... or [00][01]...)
    // are unparsed option lists and must never match a single option.
    if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(optStr) ||
        RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(incStr)) {
      return false;
    }

    final optNum = num.tryParse(optStr);
    final incNum = num.tryParse(incStr);
    if (optNum != null && incNum != null && optNum == incNum) return true;

    final optClean = optStr.startsWith('0x') ? optStr.substring(2) : optStr;
    final incClean = incStr.startsWith('0x') ? incStr.substring(2) : incStr;
    final optHex = int.tryParse(optClean, radix: 16);
    final incHex = int.tryParse(incClean, radix: 16);
    // Equate short protocol indices (e.g. `02`/`2`) or equal-length hex.
    // Never equate sno `02` with a long recipe payload just because both parse.
    if (optHex != null && incHex != null && optHex == incHex) {
      final bothShort = optClean.length <= 4 && incClean.length <= 4;
      final sameLength = optClean.length == incClean.length;
      if (bothShort || sameLength) return true;
    }

    final optStripped = optStr.replaceFirst(RegExp(r'^0+'), '');
    final incStripped = incStr.replaceFirst(RegExp(r'^0+'), '');
    if (optStripped.isNotEmpty &&
        optStripped == incStripped &&
        optStr.length <= 4 &&
        incStr.length <= 4) {
      return true;
    }

    return false;
  }

  static bool enumOptionMatches(dynamic optionValue, dynamic incomingValue) =>
      _enumOptionMatches(optionValue, incomingValue);

  Map<String, dynamic>? _stringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  void _scheduleControlAction(String binding) {
    final control = controlForBinding(binding);
    if (control == null || !_isControlWritable(control)) return;

    _sendDebounce[binding]?.cancel();
    // Some generated schemas expose interaction metadata as a list (for
    // example an event/interaction collection) rather than a single map.
    // Treat only map-shaped interaction configuration as debounce metadata;
    // never cast a list to Map because that aborts the otherwise-valid
    // device-frame dispatch path.
    final component = _stringMap(control['component']);
    final interaction = _stringMap(control['interaction']) ??
        _stringMap(component?['interaction']) ??
        const <String, dynamic>{};

    final extensions = _stringMap(schema['extensions']);
    final universalUi = _stringMap(extensions?['universalUi']);
    final interactions = _stringMap(universalUi?['interactions']);
    final globalControls =
        _stringMap(interactions?['controls']) ?? const <String, dynamic>{};
    final debounceMs = (interaction['debounceMs'] as num?)?.toInt() ??
        (control['debounceMs'] as num?)?.toInt() ??
        (globalControls['debounceMs'] as num?)?.toInt() ??
        0;

    _sendDebounce[binding] = Timer(
      Duration(milliseconds: debounceMs),
      () => dispatchControlAction(control),
    );
  }

  Future<void> dispatchControlAction(Map<String, dynamic> control) async {
    if (!_isControlWritable(control)) {
      logDebug(
        '[DEVICE ACCESS] ignored action for read-only control=${control['id']}',
      );
      return;
    }

    // Controls are authoritative for interaction semantics. setBinding already
    // performed the declared local update, so an inline send event must send
    // that same binding/value. This avoids stale generated action templates
    // while remaining fully schema-driven.
    final events = List<Map<String, dynamic>>.from(
      control['events'] as List? ?? const [],
    );
    final send = events.cast<Map<String, dynamic>?>().firstWhere(
              (event) =>
                  event?['event']?.toString().toLowerCase() == 'onchanged' &&
                  event?['action']?['type']?.toString().toLowerCase() == 'send',
              orElse: () => null,
            ) ??
        events.cast<Map<String, dynamic>?>().firstWhere(
              (event) =>
                  event?['action']?['type']?.toString().toLowerCase() == 'send',
              orElse: () => null,
            );
    if (send != null) {
      final binding = send['action']?['binding']?.toString().trim();
      await sendBinding(
        binding == null || binding.isEmpty
            ? control['binding']?.toString() ?? ''
            : binding,
      );
      return;
    }

    final actionId = control['action']?.toString();
    if (actionId != null && actionId.isNotEmpty) {
      await dispatchActionId(actionId);
    }
  }

  Future<void> dispatchActionId(
    String actionId, {
    BuildContext? context,
    Map<String, dynamic>? parameters,
  }) async {
    final normalized = actionId.trim();
    if (normalized.isEmpty) return;

    final schemaAction = lookupActionMap(normalized);
    final actionToDispatch = schemaAction ??
        <String, dynamic>{'type': normalized, 'value': normalized};

    await dispatchAction(
      actionToDispatch,
      context: context,
      parameters: parameters,
    );
  }

  Map<String, dynamic>? lookupActionMap(String actionId) {
    final schemaActions = _schema['actions'];
    final extActions = _schema['extensions'] is Map
        ? (_schema['extensions'] as Map)['universalUi']
        : null;
    final uActions = extActions is Map ? extActions['actions'] : null;
    final candidates = <dynamic>[
      schemaActions is Map ? schemaActions[actionId] : null,
      uActions is Map ? uActions[actionId] : null,
    ];

    for (final raw in candidates) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final nested = map['action'];
      if (nested is Map &&
          (map['type'] == null ||
              map['event'] != null ||
              map.containsKey('action'))) {
        final nestedMap = Map<String, dynamic>.from(nested);
        if (nestedMap['payload'] == null && map['payload'] != null) {
          nestedMap['payload'] = map['payload'];
        }
        return nestedMap;
      }
      return map;
    }
    return null;
  }

  int _apiTimeoutMs(Map<String, dynamic> action) {
    final contractId =
        action['contract']?.toString() ?? action['apiContract']?.toString();
    final contracts = schema['apiContracts'] as Map? ?? const {};
    final contract = contractId == null ? null : contracts[contractId];
    final value = contract is Map
        ? contract['timeoutMs'] ?? contract['requestTimeoutMs']
        : null;
    return (value as num?)?.toInt() ?? 30000;
  }

  Future<void> dispatchAction(
    Map<String, dynamic> action, {
    BuildContext? context,
    Map<String, dynamic>? parameters,
  }) async {
    final type = action['type']?.toString();
    final value = action['value']?.toString();

    final isScanner = type == 'openScanner' ||
        value == 'openScanner' ||
        action['id']?.toString() == 'openScanner' ||
        (type == 'native' && value == 'openScanner');

    if (isScanner) {
      await _runOpenScanner(context, <String, dynamic>{
        ...action,
        'type': 'native',
        'value': 'openScanner',
      });
      return;
    }

    final isWifi = type == 'openWifiConfig' ||
        value == 'openWifiConfig' ||
        type == 'ui.wifi' ||
        value == 'ui.wifi' ||
        action['id']?.toString() == 'openWifiConfig';

    if (isWifi) {
      await _runOpenWifiConfig(context, action);
      return;
    }

    final isInfo = type == 'openDeviceInfo' ||
        type == 'openInfo' ||
        type == 'ui.info' ||
        value == 'openDeviceInfo' ||
        value == 'openInfo' ||
        value == 'ui.info';

    if (isInfo) {
      await _runOpenInfo(context, action);
      return;
    }

    final isCheckConnectivity = type == 'checkLocalConnectivity' ||
        value == 'checkLocalConnectivity' ||
        type == 'refreshConnectivity' ||
        value == 'refreshConnectivity';

    if (isCheckConnectivity) {
      await checkLocalConnectivity();
      return;
    }

    await ActionRegistry.instance.dispatch(
      context: context,
      state: this,
      action: action,
      parameters: parameters,
    );
  }

  Future<void> _runOpenScanner(
    BuildContext? context,
    Map<String, dynamic> action,
  ) async {
    final handler = onOpenScanner;
    if (context == null || handler == null) {
      logDebug(
        '[SDUI] openScanner requires BuildContext and onOpenScanner handler.',
      );
      return;
    }
    await handler(context, this, action);
  }

  Future<void> _runOpenWifiConfig(
    BuildContext? context,
    Map<String, dynamic> action,
  ) async {
    final handler = onOpenWifiConfig;
    if (context == null || handler == null) {
      logDebug(
        '[SDUI] openWifiConfig requires BuildContext and onOpenWifiConfig handler.',
      );
      return;
    }
    await handler(context, this, action);
  }

  Future<void> _runOpenInfo(
    BuildContext? context,
    Map<String, dynamic> action,
  ) async {
    final handler = onOpenInfo;
    if (context == null || handler == null) {
      logDebug(
        '[SDUI] openInfo requires BuildContext and onOpenInfo handler.',
      );
      return;
    }
    await handler(context, this, action);
  }

  /// Resolves the Device Info datasource URL only from the live schema.
  ///
  /// No model-specific URL or public-host replacement is invented here. The
  /// schema may declare the URL directly on the action, under its infoPage
  /// datasource, via infoPage.dataUrl, or through meta.links.deviceInfo.
  Uri? resolveDeviceInfoUri(Map<String, dynamic> action) {
    Map<String, dynamic>? asMap(dynamic value) {
      if (value is Map) {
        return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
      }
      return null;
    }

    dynamic readPath(dynamic root, String path) {
      dynamic current = root;
      final tokenPattern = RegExp(r'([^\.\[\]]+)|\[(\d+)\]');
      for (final match in tokenPattern.allMatches(path)) {
        final key = match.group(1);
        final indexText = match.group(2);
        if (key != null) {
          if (current is! Map || !current.containsKey(key)) return null;
          current = current[key];
        } else if (indexText != null) {
          final index = int.tryParse(indexText);
          if (index == null || current is! List || index >= current.length) {
            return null;
          }
          current = current[index];
        }
      }
      return current;
    }

    String? firstText(List<dynamic> values) {
      for (final value in values) {
        final text = value?.toString().trim();
        if (text != null && text.isNotEmpty) return text;
      }
      return null;
    }

    final metaInfo = asMap(asMap(_schema['meta'])?['infoPage']);
    final schemaPath = firstText(<dynamic>[
      action['schemaPath'],
      metaInfo?['entry'],
    ]);

    final infoPage = asMap(
          schemaPath == null
              ? _schema['infoPage']
              : readPath(_schema, schemaPath),
        ) ??
        asMap(_schema['infoPage']) ??
        asMap(readPath(_schema, 'extensions.serverDrivenUi.infoPage')) ??
        asMap(readPath(_schema, 'extensions.universalUi.infoPage'));

    final dataSourceId = firstText(<dynamic>[
      action['load'],
      action['dataSource'],
      infoPage?['dataSource'],
      metaInfo?['dataSource'],
    ]);
    final dataSource = dataSourceId == null
        ? null
        : asMap(asMap(_schema['dataSources'])?[dataSourceId]);
    final links = asMap(asMap(_schema['meta'])?['links']);

    final candidates = <dynamic>[
      action['url'],
      action['dataUrl'],
      action['value'],
      dataSource?['url'],
      infoPage?['dataUrl'],
      links?['deviceInfo'],
    ];

    for (final candidate in candidates) {
      final text = candidate?.toString().trim();
      if (text == null || text.isEmpty) continue;
      final uri = Uri.tryParse(text);
      if (uri != null &&
          uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host != 'localhost' &&
          uri.host != '127.0.0.1' &&
          uri.host != '::1') {
        return uri;
      }
    }
    return null;
  }

  /// Rewrites localhost Studio URLs to the public efactor.tech host.
  static String? rewritePublicApiUrl(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;

    if (uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host.isEmpty) {
      return uri
          .replace(scheme: 'http', host: 'efactor.tech', port: null)
          .toString();
    }
    return trimmed;
  }

  String? _resolveScanApiUrl() {
    final apiContracts = _schema['apiContracts'] as Map?;
    final scanContract = apiContracts?['scan'];
    final scanResultContract = apiContracts?['scanResult'];
    final wifiUpdateContract = apiContracts?['wifiConnectionUpdate'];

    final candidates = <dynamic>[
      wifiUpdateContract is Map ? wifiUpdateContract['url'] : null,
      scanContract is Map ? scanContract['url'] : null,
      scanResultContract is Map ? scanResultContract['url'] : null,
      _schema['meta']?['links']?['scan'],
      _schema['_clientConnection']?['scanUrl'],
    ];

    for (final candidate in candidates) {
      final value = candidate?.toString().trim();

      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  /// Posts only scanner information to the dedicated scan resource.
  ///
  /// Endpoint:
  ///   POST /api/device-ui-scan/{modelId}/{nodeId}/scan
  ///
  /// The exact URL is read dynamically from apiContracts.scan.url,
  /// meta.links.scan or _clientConnection.scanUrl.
  ///
  /// The public method keeps returning a Boolean so existing scanner UI code
  /// does not need to change.
  Future<bool> postScanResult({
    required String value,
    required String format,
    required String scannedAt,
    String feature = 'qrBarcodeScan',
    Map<String, dynamic>? extra,
  }) async {
    final connection = Map<String, dynamic>.from(
      _schema['_clientConnection'] as Map? ?? {},
    );
    final modelId = connection['modelId']?.toString() ??
        _schema['meta']?['app']?['modelNo']?.toString();
    final nodeId = connection['nodeId']?.toString();

    if (modelId == null ||
        modelId.trim().isEmpty ||
        nodeId == null ||
        nodeId.trim().isEmpty) {
      logDebug('[SDUI] Cannot post scan: modelId/nodeId missing.');
      return false;
    }

    final normalizedValue = value.trim();
    final normalizedFormat = format.trim();

    if (normalizedValue.isEmpty || normalizedFormat.isEmpty) {
      logDebug('[SDUI] Cannot post scan: value/format missing.');
      return false;
    }

    final parsedScannedAt =
        DateTime.tryParse(scannedAt)?.toUtc() ?? DateTime.now().toUtc();

    final scanId = _createScanId(
      modelId: modelId.trim(),
      nodeId: nodeId.trim(),
      value: normalizedValue,
      scannedAt: parsedScannedAt,
    );

    _pendingBindings.add('state.scanResult.value');
    notifyListeners();

    try {
      final result = await _scanRepository.postScan(
        modelId: modelId.trim(),
        nodeId: nodeId.trim(),
        scanId: scanId,
        value: normalizedValue,
        format: normalizedFormat,
        scannedAt: parsedScannedAt,
        feature: feature,
        extra: extra,
        endpointOverride: _resolveScanApiUrl(),
      );

      _scanResult
        ..['scanId'] = scanId
        ..['modelId'] = modelId.trim()
        ..['nodeId'] = nodeId.trim()
        ..['deviceId'] = nodeId.trim()
        ..['value'] = normalizedValue
        ..['format'] = normalizedFormat
        ..['scannedAt'] = parsedScannedAt.toIso8601String()
        ..['resourceUri'] = result.resourceUri.toString();

      logDebug(
        '[SDUI] Scan POST success '
        'status=${result.statusCode} '
        'uri=${result.resourceUri}',
      );

      return result.statusCode >= 200 && result.statusCode < 300;
    } on ScanRepositoryException catch (error) {
      logDebug('[SDUI] Scan POST failed: $error');
      return false;
    } finally {
      _pendingBindings.remove('state.scanResult.value');
      notifyListeners();
    }
  }

  bool get _postProvisionRequestsDeviceStateRefresh {
    final postProvision = _schema['wifiProvisioning']?['postProvision'];
    if (postProvision is! Map) return false;

    final refresh = postProvision['refresh'];
    if (refresh is! List) return false;

    for (final item in refresh.whereType<Map>()) {
      final source = item['dataSource']?.toString().trim();
      if (source == 'deviceState') return true;
    }

    return false;
  }

  /// Executes the schema-declared post-provision Device state refresh through
  /// the host Device schema repository. No endpoint is hardcoded here.
  Future<bool> refreshDeviceStateAfterProvisioning() async {
    if (!_postProvisionRequestsDeviceStateRefresh) {
      return true;
    }

    final refresh = onPostProvisionRefresh;
    if (refresh == null) {
      logDebug(
        '[SDUI][WiFi] postProvision requested deviceState refresh, but no '
        'host refresh callback is registered.',
      );
      return false;
    }

    try {
      await refresh();
      logDebug('[SDUI][WiFi] postProvision deviceState refresh completed.');
      return true;
    } catch (error) {
      logDebug(
        '[SDUI][WiFi] postProvision deviceState refresh failed: $error',
      );
      return false;
    }
  }

  /// Posts Wi-Fi details only after native provisioning confirms that
  /// the target device is online. The endpoint is the same schema-provided URL
  /// used by scanner synchronization.
  Future<bool> postWifiConnection({
    required String ssid,
    String? password,
    required String security,
    required bool connected,
    String? deviceIp,
    String? nodeId,
  }) async {
    if (!connected) {
      logDebug(
        '[SDUI] Wi-Fi synchronization skipped: device is not confirmed online.',
      );
      return false;
    }

    final identity = resolveDeviceIdentity();
    final modelId = identity.modelId?.trim();
    final resolvedNodeId = (nodeId != null && nodeId.trim().isNotEmpty)
        ? nodeId.trim()
        : identity.nodeId?.trim();
    final endpoint = rewritePublicApiUrl(_resolveScanApiUrl());

    logDebug('[SDUI][WiFi] POST endpoint=${endpoint ?? 'MISSING'}');

    if (modelId == null ||
        modelId.isEmpty ||
        resolvedNodeId == null ||
        resolvedNodeId.isEmpty ||
        endpoint == null ||
        endpoint.isEmpty ||
        ssid.trim().isEmpty) {
      logDebug(
        '[SDUI] Cannot post Wi-Fi result: URL, model, node or SSID is missing.',
      );
      return false;
    }

    final payload = <String, dynamic>{
      'event_type': 'wifi_connected',
      'model_no': modelId,
      'node_id': resolvedNodeId,
      'device_id': resolvedNodeId,
      'qr_value': _scanResult['value'],
      'wifi': <String, dynamic>{
        'ssid': ssid.trim(),
        'password': password,
        'security': security.trim(),
        'connected': true,
        'device_ip': deviceIp,
      },
    };

    _pendingBindings.add('state.wifiConfig');
    notifyListeners();

    try {
      final response = await _client
          .post(
            Uri.parse(endpoint),
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        logDebug('[SDUI] Wi-Fi POST failed: HTTP ${response.statusCode}.');
        return false;
      }

      final decoded = decodeJsonBody(
        body: response.body,
        contentType: response.headers['content-type'],
        source: 'wifi-config',
      );
      if (decoded is! Map || decoded['status'] != true) {
        logDebug('[SDUI] Wi-Fi POST returned an unsuccessful response.');
        return false;
      }

      final data = decoded['data'];
      final returnedWifi = data is Map ? data['wifi'] : null;
      final wifi = returnedWifi is Map
          ? Map<String, dynamic>.from(returnedWifi)
          : <String, dynamic>{
              'ssid': ssid.trim(),
              'password': null,
              'security': security.trim(),
              'connected': true,
              'device_ip': deviceIp,
            };

      _wifiConfig
        ..clear()
        ..addAll(wifi)
        ..['deviceIp'] = wifi['deviceIp'] ?? wifi['device_ip']
        ..['connected'] = true
        ..['updatedAt'] = data is Map ? data['created_at'] : null;

      _runtimeOnline = true;

      notifyListeners();
      return true;
    } on TimeoutException {
      logDebug('[SDUI] Wi-Fi POST timed out.');
      return false;
    } on FormatException {
      logDebug('[SDUI] Wi-Fi POST returned invalid JSON.');
      return false;
    } catch (error) {
      logDebug('[SDUI] Wi-Fi POST failed: $error');
      return false;
    } finally {
      _pendingBindings.remove('state.wifiConfig');
      notifyListeners();
    }
  }

  /// Accepts the unmodified map returned by WifiProvisioningBridge. Call this
  /// from the existing onOpenWifiConfig host callback after the MethodChannel
  /// completes.
  Future<bool> handleWifiProvisioningResult(Map<String, dynamic> result) async {
    final status = result['status']?.toString().trim().toLowerCase();

    final connected = result['connected'] == true ||
        result['onlineConfirmed'] == true ||
        result['online_confirmed'] == true;

    final ssid = result['ssid']?.toString().trim() ?? '';
    final security = result['security']?.toString().trim() ?? '';
    final deviceIp =
        result['deviceIp']?.toString() ?? result['device_ip']?.toString();
    final nodeId =
        result['nodeId']?.toString() ?? result['node_id']?.toString();

    logDebug(
      '[SDUI][WiFi] Provisioning result: '
      'status=$status, '
      'connected=$connected, '
      'ssidPresent=${ssid.isNotEmpty}, '
      'security=$security, '
      'nodeId=${nodeId ?? 'MISSING'}',
    );

    if (status != 'success' || !connected) {
      logDebug(
        '[SDUI][WiFi] Synchronization skipped because the '
        'native result did not confirm a successful connection.',
      );
      return false;
    }

    // The device is online even if the later server synchronization fails.
    _runtimeOnline = true;
    _wifiConfig
      ..['ssid'] = ssid
      ..['password'] = result['password']?.toString()
      ..['security'] = security
      ..['connected'] = true
      ..['deviceIp'] = deviceIp;
    notifyListeners();

    final synchronized = await postWifiConnection(
      ssid: ssid,
      password: result['password']?.toString(),
      security: security,
      connected: true,
      deviceIp: deviceIp,
      nodeId: nodeId,
    );

    final postProvision =
        _schema['wifiProvisioning']?['postProvision'] as Map? ??
            const <String, dynamic>{};
    final enabled = postProvision['enableTransports'] as List? ?? const [];
    _enabledTransports
      ..clear()
      ..addAll(enabled.map((value) => value.toString()));

    final refresh = postProvision['refresh'] as List? ?? const [];
    final excluded = <String>{};
    for (final item in refresh.whereType<Map>()) {
      final fields = item['excludeFields'] as List? ?? const [];
      excluded.addAll(fields.map((value) => value.toString()));
    }
    if (excluded.contains('password')) {
      _wifiConfig['password'] = null;
    }

    logDebug(
      '[SDUI][WiFi] postProvision online=$_runtimeOnline '
      'enabledTransports=${_enabledTransports.join(",")} '
      'passwordRetained=${_wifiConfig['password'] != null}',
    );
    notifyListeners();
    return synchronized;
  }

  /// Fetches the latest scanner-only record from:
  ///   GET /api/device-ui-scan/{modelId}/{nodeId}/scan
  Future<Map<String, dynamic>?> fetchLatestScanResult() async {
    final connection = Map<String, dynamic>.from(
      _schema['_clientConnection'] as Map? ?? {},
    );
    final modelId = connection['modelId']?.toString() ??
        _schema['meta']?['app']?['modelNo']?.toString();
    final nodeId = connection['nodeId']?.toString();

    if (modelId == null ||
        modelId.trim().isEmpty ||
        nodeId == null ||
        nodeId.trim().isEmpty) {
      return null;
    }

    try {
      final record = await _scanRepository.getLatestScan(
        modelId: modelId.trim(),
        nodeId: nodeId.trim(),
        endpointOverride: _resolveScanApiUrl(),
      );

      if (record == null) return null;

      final data = record.toJson();

      _scanResult
        ..['scanId'] = record.scanId
        ..['modelId'] = record.modelId ?? modelId.trim()
        ..['nodeId'] = record.nodeId ?? nodeId.trim()
        ..['deviceId'] = record.nodeId ?? nodeId.trim()
        ..['resourceUri'] = _resolveScanApiUrl();

      setBinding('state.scanResult.value', record.value, dispatch: false);
      setBinding('state.scanResult.format', record.format, dispatch: false);
      setBinding(
        'state.scanResult.scannedAt',
        record.scannedAt,
        dispatch: false,
      );
      setBinding('state.scanResult.nodeId', nodeId.trim(), dispatch: false);

      _scanResult['scanId'] = record.scanId;

      return data;
    } on ScanRepositoryException catch (error) {
      logDebug('[SDUI] Scan GET failed: $error');
      return null;
    }
  }

  String _createScanId({
    required String modelId,
    required String nodeId,
    required String value,
    required DateTime scannedAt,
  }) {
    final source = '$modelId|$nodeId|$value|${scannedAt.toIso8601String()}';

    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(source)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }

    return 'scan-'
        '${scannedAt.microsecondsSinceEpoch}-'
        '${hash.toRadixString(16).padLeft(16, '0')}';
  }

  String? bindingForUniversalParameter(String? target) {
    if (target == null) return null;
    final extData = _schema['extensions'] is Map
        ? (_schema['extensions'] as Map)['universalUi']
        : null;
    final uData = extData is Map ? extData['data'] : null;
    final parameters = (uData is Map && uData['parameters'] is Map)
        ? uData['parameters'] as Map
        : null;
    final sourceKey = parameters?[target] is Map
        ? parameters![target]['sourceKey']?.toString()
        : null;
    if (sourceKey == null) return null;
    final control = controls.cast<Map<String, dynamic>?>().firstWhere(
          (item) => item?['id']?.toString() == sourceKey,
          orElse: () => null,
        );
    return control?['binding']?.toString();
  }

  // ── Device identity helpers ──────────────────────────────────────────────────

  /// Returns the modelId and nodeId injected by SchemaRepository at load time.
  /// These come from the `_clientConnection` key which SchemaRepository adds,
  /// with fallbacks for node_details, deviceConfig, and meta.
  ({String? modelId, String? nodeId}) resolveDeviceIdentity() {
    List<Map> asMaps(dynamic val) {
      if (val is Map) return [val];
      if (val is List) {
        return val.whereType<Map>().toList();
      }
      return const [];
    }

    Map? asMap(dynamic val) {
      if (val is Map) return val;
      if (val is List) {
        for (final item in val) {
          if (item is Map) return item;
        }
      }
      return null;
    }

    final rawConn = _schema['_clientConnection'];
    final conn = rawConn is Map ? rawConn : const {};

    String? firstId(List<dynamic> values) {
      for (final value in values) {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
      return null;
    }

    String? searchMaps(List<Map> maps, List<String> keys) {
      for (final map in maps) {
        for (final key in keys) {
          final val = map[key]?.toString().trim();
          if (val != null && val.isNotEmpty) return val;
        }
      }
      return null;
    }

    final nodeDetailsList = asMaps(_schema['node_details']);
    final deviceList = asMaps(_schema['device']);
    final meta = asMap(_schema['meta']);
    final metaApp = asMap(meta?['app']);
    final dataSources = asMap(_schema['dataSources']);
    final deviceCommands = asMap(dataSources?['deviceCommands']);
    final deviceConfig = asMap(_schema['deviceConfig']);
    final deviceConfigInfo = asMap(deviceConfig?['info']);
    final stateMap = asMap(_schema['state']);

    final modelId = firstId([
      conn['modelId'],
      searchMaps(nodeDetailsList, ['model_no', 'modelNo', 'modelNumber']),
      searchMaps(deviceList, ['model_no', 'modelNo', 'modelNumber']),
      metaApp?['modelNo'],
      metaApp?['model_id'],
      deviceCommands?['model_no'],
      deviceConfigInfo?['model'],
      _schema['model_no'],
      _schema['modelNo'],
    ]);
    final nodeId = firstId([
      conn['nodeId'],
      searchMaps(nodeDetailsList, ['node_id', 'nodeId', 'id']),
      searchMaps(deviceList, ['node_id', 'nodeId', 'id']),
      metaApp?['nodeId'],
      _schema['node_id'],
      _schema['nodeId'],
      stateMap?['node_id'],
      deviceCommands?['node_id'],
      deviceConfig?['node_id'],
    ]);
    return (modelId: modelId, nodeId: nodeId);
  }

  void _onLocalDevicesChanged() {
    _tickChannel('b:state.online');
    _tickChannel('b:state.online.value');
    _tickChannel('b:state.onlineLabel');
    _tickChannel('b:state.onlinelabel');
    _tickChannel('b:state.isLocal');
    _tickChannel('b:state.islocal');
    _tickChannel('b:state.localOnline');
    _tickChannel('b:state.localonline');
    _tickChannel('b:state.connectivityType');
    _tickChannel('b:state.connectivityMode');
    _tickChannel('b:state.connectivityLabel');
    _tickChannel('b:state.connectivitylabel');
    _tickChannel('b:state.localDeviceIp');
    _tickChannel('b:state.localdeviceip');
    _tickChannel('b:state.deviceconnectivity.online');
    _tickChannel('b:state.deviceconnectivity.label');
    notifyListeners();
  }

  /// Actively probes the local device over LAN (TCP socket) to check if reachable right now.
  /// If reachable, returns true. If unreachable, evicts from local cache and returns false.
  Future<bool> checkLocalConnectivity({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final nodeId = resolveDeviceIdentity().nodeId;
    if (nodeId == null || nodeId.isEmpty) return false;
    final reachable = await EfactorCloudService.instance.probeLocalDevice(nodeId, timeout: timeout);
    _onLocalDevicesChanged();
    return reachable;
  }

  /// Builds a fully populated [DeviceCommandRequest] from a schema control.
  Map<String, dynamic> _deviceCommandsContract() {
    final dataSource = _schema['dataSources']?['deviceCommands'];
    if (dataSource is Map) return Map<String, dynamic>.from(dataSource);
    final apiContract = _schema['apiContracts']?['deviceCommands'];
    if (apiContract is Map) return Map<String, dynamic>.from(apiContract);
    return const <String, dynamic>{};
  }

  /// Resolves the canonical protocol frame declared by the Device schema.
  ///
  /// The transport contract may point at a schema path such as:
  ///   deviceConfig.devices[0].pages
  ///
  /// A frame is then selected by the control's runtime page name and its
  /// declared frame/parameter name. No model, parameter id or protocol byte is
  /// hardcoded here.
  Map<String, dynamic>? _resolveCanonicalDeviceConfigFrame(
    Map<String, dynamic> control,
  ) {
    final contract = _deviceCommandsContract();
    final sourcePath = contract['frameSource']?.toString().trim();

    // Build a list of schema-declared frame sources. This remains completely
    // model/device agnostic:
    //
    // 1) dataSources/apiContracts.deviceCommands.frameSource (authoritative
    //    declaration when present);
    // 2) node_details[].config for the CURRENT runtime node, when backend
    //    publishes the canonical device config there;
    // 3) root deviceConfig as the legacy/current generated projection;
    // 4) state/deviceState config projections as compatibility copies.
    //
    // A source is only useful if a frame can be deterministically matched to
    // the control. We never infer protocol bytes and never treat an unrelated
    // generic frame as the requested control frame.
    final sources = <({dynamic pages, String label})>[];

    void addSource(dynamic pages, String label) {
      if (pages is! Map) return;
      final alreadyAdded = sources.any(
        (entry) => identical(entry.pages, pages),
      );
      if (!alreadyAdded) {
        sources.add((pages: pages, label: label));
      }
    }

    if (sourcePath != null && sourcePath.isNotEmpty) {
      addSource(_resolveSchemaPath(sourcePath), sourcePath);
    }

    // node_details is a server projection of the device configuration. Prefer
    // only the entry whose id exactly matches the runtime-selected node.
    // This prevents a stale/truncated schema node from silently controlling a
    // different physical device.
    final identity = resolveDeviceIdentity();
    final runtimeNodeId = identity.nodeId?.trim();
    final nodeDetails = _schema['node_details'];
    if (nodeDetails is List &&
        runtimeNodeId != null &&
        runtimeNodeId.isNotEmpty) {
      for (final rawNode in nodeDetails.whereType<Map>()) {
        final schemaNodeId = rawNode['id']?.toString().trim();
        if (schemaNodeId != runtimeNodeId) continue;

        final config = rawNode['config'];
        if (config is! Map) continue;
        final devices = config['devices'];
        if (devices is! List) continue;

        for (var i = 0; i < devices.length; i += 1) {
          final rawDevice = devices[i];
          if (rawDevice is! Map) continue;
          addSource(
            rawDevice['pages'],
            'node_details[id="$runtimeNodeId"].config.devices[$i].pages',
          );
        }
      }
    }

    final deviceConfig = _schema['deviceConfig'];
    if (deviceConfig is Map) {
      final devices = deviceConfig['devices'];
      if (devices is List) {
        for (var i = 0; i < devices.length; i += 1) {
          final rawDevice = devices[i];
          if (rawDevice is! Map) continue;
          addSource(rawDevice['pages'], 'deviceConfig.devices[$i].pages');
        }
      }
    }

    final stateDeviceConfig = _schema['state']?['device']?['config'];
    if (stateDeviceConfig is Map) {
      final devices = stateDeviceConfig['devices'];
      if (devices is List) {
        for (var i = 0; i < devices.length; i += 1) {
          final rawDevice = devices[i];
          if (rawDevice is! Map) continue;
          addSource(
            rawDevice['pages'],
            'state.device.config.devices[$i].pages',
          );
        }
      }
    }

    final deviceStateConfig = _schema['deviceState']?['config'];
    if (deviceStateConfig is Map) {
      final devices = deviceStateConfig['devices'];
      if (devices is List) {
        for (var i = 0; i < devices.length; i += 1) {
          final rawDevice = devices[i];
          if (rawDevice is! Map) continue;
          addSource(rawDevice['pages'], 'deviceState.config.devices[$i].pages');
        }
      }
    }

    if (sources.isEmpty) return null;

    final pageCandidates = <String>{
      if (control['pageName']?.toString().trim().isNotEmpty == true)
        control['pageName'].toString().trim(),
      if (activePage['title']?.toString().trim().isNotEmpty == true)
        activePage['title'].toString().trim(),
    };

    final declaredFrame = control['deviceFrame'] as Map?;
    final protocolFrame = control['protocolMeta']?['frame'] as Map?;
    final names = <String>{
      if (declaredFrame?['name']?.toString().trim().isNotEmpty == true)
        declaredFrame!['name'].toString().trim(),
      if (protocolFrame?['name']?.toString().trim().isNotEmpty == true)
        protocolFrame!['name'].toString().trim(),
      if (control['parameterName']?.toString().trim().isNotEmpty == true)
        control['parameterName'].toString().trim(),
      if (control['parameter']?.toString().trim().isNotEmpty == true)
        control['parameter'].toString().trim(),
    };

    for (final source in sources) {
      final frameSource = source.pages;
      if (frameSource is! Map) continue;

      dynamic pageFrames;
      String? selectedPage;
      for (final pageName in pageCandidates) {
        final direct = frameSource[pageName];
        if (direct is List) {
          pageFrames = direct;
          selectedPage = pageName;
          break;
        }

        final insensitive = frameSource.entries.cast<MapEntry>().where(
              (entry) =>
                  entry.key.toString().trim().toLowerCase() ==
                  pageName.toLowerCase(),
            );
        if (insensitive.isNotEmpty && insensitive.first.value is List) {
          pageFrames = insensitive.first.value;
          selectedPage = insensitive.first.key.toString();
          break;
        }
      }

      if (pageFrames is! List) continue;

      for (final rawEntry in pageFrames.whereType<Map>()) {
        final rawFrame =
            rawEntry['frame'] is Map ? rawEntry['frame'] : rawEntry;
        if (rawFrame is! Map) continue;

        final frame = Map<String, dynamic>.from(rawFrame);
        final frameName = frame['name']?.toString().trim();
        if (frameName == null || frameName.isEmpty) continue;

        final matched = names.any(
          (candidate) => candidate.toLowerCase() == frameName.toLowerCase(),
        );
        if (!matched) continue;

        logDebug(
          '[DEVICE FRAME SOURCE] control=${control['id']} '
          'source=${source.label} '
          'page=${selectedPage ?? control['pageName']} frame=$frameName',
        );
        return frame;
      }
    }

    // A config projection may be present while still lacking a deterministically
    // matching frame (for example frame.name="frame" for parameter "power").
    // Returning null intentionally leaves the control's own deviceFrame in
    // place so DeviceFrameBuilder emits the precise missing-schema error rather
    // than Flutter guessing which physical frame to send.
    return null;
  }

  /// Resolves a simple schema path containing dot properties and numeric list
  /// indexes (for example `deviceConfig.devices[0].pages`).
  dynamic _resolveSchemaPath(String rawPath) {
    var current = _schema as dynamic;
    final path = rawPath.trim().replaceFirst(RegExp(r'^\$\.?'), '');
    if (path.isEmpty) return current;

    for (final match in RegExp(r'([^.\[\]]+)|\[(\d+)\]').allMatches(path)) {
      final key = match.group(1);
      final indexText = match.group(2);
      if (key != null) {
        if (current is! Map || !current.containsKey(key)) return null;
        current = current[key];
      } else if (indexText != null) {
        if (current is! List) return null;
        final index = int.tryParse(indexText);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      }
    }
    return current;
  }

  Map<String, dynamic> _effectiveControlForFrameBuild(
    Map<String, dynamic> control,
  ) {
    final canonical = _resolveCanonicalDeviceConfigFrame(control);
    if (canonical == null) return control;

    final merged = _mergeDeviceFrameBytes(canonical, control: control);
    final effective = Map<String, dynamic>.from(control);
    effective['deviceFrame'] = merged;

    // Keep protocolMeta schema-driven as well. When old generated copies leave
    // command_id/function_code blank, derive those metadata fields from the
    // canonical fixed fields only for diagnostics/request metadata. The actual
    // frame builder still consumes the complete canonical commands.
    final meta = Map<String, dynamic>.from(
      control['protocolMeta'] as Map? ?? const <String, dynamic>{},
    );
    for (final raw
        in (canonical['commands'] as List? ?? const []).whereType<Map>()) {
      final name = (raw['default_name'] ?? raw['Field_description'])
          ?.toString()
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      final value = raw['value'];
      if (value == null || value.toString().trim().isEmpty) continue;
      if (name == 'commandid' &&
          (meta['command_id'] == null ||
              meta['command_id'].toString().trim().isEmpty)) {
        meta['command_id'] = value;
      } else if (name == 'functioncode' &&
          (meta['function_code'] == null ||
              meta['function_code'].toString().trim().isEmpty)) {
        meta['function_code'] = value;
      }
    }
    meta['frame'] = merged;
    effective['protocolMeta'] = meta;
    return effective;
  }

  /// Copies missing byte geometry / values from the control's own declared
  /// frames. Never invents protocol numbers that the schema did not publish.
  Map<String, dynamic> _mergeDeviceFrameBytes(
    Map<String, dynamic> canonical, {
    required Map<String, dynamic> control,
  }) {
    final donors = <Map<String, dynamic>>[
      if (control['deviceFrame'] is Map)
        Map<String, dynamic>.from(
          (control['deviceFrame'] as Map).cast<dynamic, dynamic>(),
        ),
      if (control['protocolMeta'] is Map &&
          (control['protocolMeta'] as Map)['frame'] is Map)
        Map<String, dynamic>.from(
          ((control['protocolMeta'] as Map)['frame'] as Map)
              .cast<dynamic, dynamic>(),
        ),
    ];
    if (donors.isEmpty) return canonical;

    final commands = <dynamic>[
      ...(canonical['commands'] as List? ?? const <dynamic>[]),
    ];
    var changed = false;

    for (var index = 0; index < commands.length; index++) {
      final raw = commands[index];
      if (raw is! Map) continue;
      final field = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      final hasGeometry =
          _positiveFrameInt(field['byte_start_position']) != null &&
              _positiveFrameInt(field['no_of_bytes']) != null;
      if (hasGeometry) continue;

      final name = (field['default_name'] ?? field['Field_description'])
          ?.toString()
          .trim()
          .toLowerCase();
      Map<String, dynamic>? donor;
      for (final source in donors) {
        final list = source['commands'];
        if (list is! List) continue;
        if (name != null && name.isNotEmpty) {
          for (final item in list.whereType<Map>()) {
            final itemName = (item['default_name'] ?? item['Field_description'])
                ?.toString()
                .trim()
                .toLowerCase();
            if (itemName == name) {
              donor = Map<String, dynamic>.from(item.cast<dynamic, dynamic>());
              break;
            }
          }
        }
        if (donor == null && index < list.length && list[index] is Map) {
          donor = Map<String, dynamic>.from(
            (list[index] as Map).cast<dynamic, dynamic>(),
          );
        }
        if (donor != null) break;
      }
      if (donor == null) continue;

      for (final key in const <String>[
        'byte_start_position',
        'no_of_bytes',
        'value',
      ]) {
        final current = field[key]?.toString().trim() ?? '';
        final incoming = donor[key];
        if (current.isEmpty &&
            incoming != null &&
            incoming.toString().trim().isNotEmpty) {
          field[key] = incoming;
          changed = true;
        }
      }
      commands[index] = field;
    }

    if (!changed) return canonical;
    return <String, dynamic>{...canonical, 'commands': commands};
  }

  static int? _positiveFrameInt(dynamic raw) {
    final value =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString().trim() ?? '');
    return value != null && value > 0 ? value : null;
  }

  DeviceCommandRequest? _buildCommandRequest({
    required Map<String, dynamic> control,
    required String binding,
    required dynamic value,
  }) {
    final identity = resolveDeviceIdentity();
    final modelId = identity.modelId;
    final nodeId = identity.nodeId;
    final controlId = control['id']?.toString() ?? 'unknown';

    if (modelId == null || nodeId == null) {
      _showCommandError(
        '[Device Command] Cannot send command: runtime modelId or nodeId is missing.\n'
        'Control: $controlId',
      );
      return null;
    }
    if (!_isControlWritable(control)) {
      _showCommandError(
        '[Device Command] Write blocked by schema access contract.\n'
        'Control: $controlId\nAccess: ${_controlAccess(control) ?? "unspecified"}',
      );
      return null;
    }

    final effectiveControl = _effectiveControlForFrameBuild(control);
    final deviceFrame = Map<String, dynamic>.from(
      effectiveControl['deviceFrame'] as Map? ?? const <String, dynamic>{},
    );
    final protocolMeta = Map<String, dynamic>.from(
      effectiveControl['protocolMeta'] as Map? ?? const <String, dynamic>{},
    );
    final mappedProtocolValue = DeviceFrameBuilder.resolveProtocolValue(
      effectiveControl,
      value,
    );
    logDebug(
      '[DEVICE MAP] control=$controlId binding=$binding '
      'appValue=$value protocolValue=${mappedProtocolValue ?? "<unmapped>"}',
    );

    final frameBuild = DeviceFrameBuilder.build(
      control: effectiveControl,
      runtimeValue: value,
    );
    if (!frameBuild.ok) {
      _showCommandError(
        '[Device Command] Schema frame is incomplete/invalid.\n'
        'Control: $controlId\n${frameBuild.error}',
      );
      return null;
    }

    final contract = _deviceCommandsContract();
    final adapter = contract['adapter']?.toString().trim();
    final protocol = contract['protocol']?.toString().trim();
    final type = contract['type']?.toString().trim().toLowerCase();
    final usesDeviceApi = adapter?.toLowerCase() == 'deviceapi';

    String? endpoint;
    if (!usesDeviceApi) {
      final rawEndpoint = contract['url']?.toString() ??
          _schema['meta']?['links']?['parameters']?.toString();
      endpoint = rewritePublicApiUrl(rawEndpoint);
      final isRest = type == 'rest' ||
          protocol?.toLowerCase() == 'http' ||
          protocol?.toLowerCase() == 'https' ||
          (adapter == null && endpoint != null);
      if (isRest && (endpoint == null || endpoint.isEmpty)) {
        _showCommandError(
          '[Device Command] REST command transport has no endpoint.\n'
          'Control: $controlId',
        );
        return null;
      }
    }

    final request = DeviceCommandRequest(
      modelId: modelId,
      nodeId: nodeId,
      parameter: control['parameterName']?.toString() ??
          control['parameter']?.toString() ??
          '',
      parameterKey: control['parameterKey']?.toString() ?? '',
      value: value,
      endpointUrl: endpoint,
      accessToken: _accessToken.isNotEmpty ? _accessToken : null,
      commands: List<dynamic>.from(
        deviceFrame['commands'] as List? ?? const [],
      ),
      frameName: deviceFrame['name']?.toString(),
      commandId: protocolMeta['command_id'],
      functionCode: protocolMeta['function_code'],
      actionId: protocolMeta['action_id'],
      multipleUi: List<dynamic>.from(
        deviceFrame['multiple_ui'] as List? ?? const [],
      ),
      triggerUi: List<dynamic>.from(
        deviceFrame['trigger_ui'] as List? ?? const [],
      ),
      binding: binding,
      controlId: controlId,
      transportAdapter: adapter,
      protocol: protocol,
      pageName: control['pageName']?.toString(),
      finalFrame: frameBuild.frameHex,
      protocolValue: frameBuild.protocolValue,
      numericValue: frameBuild.numericValue,
      responseFrame: List<dynamic>.from(
        deviceFrame['response'] as List? ?? const [],
      ),
      errorFrame: List<dynamic>.from(deviceFrame['error'] as List? ?? const []),
    );

    logDebug(
      '[DEVICE FRAME] control=$controlId binding=$binding '
      'appValue=$value protocolValue=${request.protocolValue} '
      'frame=${request.finalFrame} adapter=${adapter ?? "legacy"} '
      'protocol=${protocol ?? "unspecified"}',
    );
    return request;
  }

  Future<DeviceCommandResult> _sendDeviceCommand(DeviceCommandRequest request) async {
    if (_transportWasInjected) return _transport.send(request);
    final adapter = request.transportAdapter?.trim().toLowerCase();
    final isLocal = EfactorCloudService.instance.isNodeLocal(request.nodeId);
    if (adapter == 'deviceapi' || isLocal) {
      final res = await _deviceApiTransport.send(request);
      if (res.status == DeviceCommandStatus.delivered) {
        return res;
      }
      if (adapter != 'deviceapi') {
        logDebug(
          '[DEVICE TRANSPORT] Local deviceApi returned ${res.status} (${res.message}). '
          'Falling back to cloud transport.',
        );
        if (res.status == DeviceCommandStatus.offline ||
            res.status == DeviceCommandStatus.timeout) {
          unawaited(checkLocalConnectivity());
        }
        return _transport.send(request);
      }
      return res;
    }
    return _transport.send(request);
  }

  void _applyDeviceCommandResult(DeviceCommandResult result) {
    if (result.bindingUpdates.isEmpty) return;
    for (final entry in result.bindingUpdates.entries) {
      if (entry.key.startsWith('device.parameters.') ||
          entry.key.startsWith('state.parameters.') ||
          entry.key.startsWith('parameters.')) {
        setBinding(entry.key, entry.value, dispatch: false);
      }
    }
    if (_logGateIsOn()) {
      for (final entry in result.bindingUpdates.entries) {
        final key = parameterKeyForBinding(entry.key);
        if (key.isEmpty || _isTerminalKey(key)) continue;
        final control = controlForBinding(entry.key);
        final name = control != null ? resolveControlDisplayName(control) : key;
        final val = entry.value;
        if (name.isNotEmpty && !isUnsetTelemetryValue(val)) {
          _appendTerminalLine('$name=$val');
        }
      }
    }
  }

  /// Shows a persistent error message in the nearest [ScaffoldMessenger].
  void _showCommandError(String message) {
    logDebug('[SDUI ERROR] $message');
    final messengerState = _messengerKey?.currentState;
    if (messengerState == null) return;
    final scheme = Theme.of(messengerState.context).colorScheme;
    messengerState.hideCurrentSnackBar();
    messengerState.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.error,
        content: SingleChildScrollView(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onError,
              fontFamily: 'monospace',
            ),
          ),
        ),
        action: SnackBarAction(
          label: 'DISMISS',
          textColor: scheme.onError,
          onPressed: () => messengerState.hideCurrentSnackBar(),
        ),
      ),
    );
  }

  /// Rolls back a binding to its previous value after a failed command.
  void _rollbackBinding(String binding, dynamic previous) {
    if (!binding.startsWith('device.parameters.')) return;
    final key = binding.substring('device.parameters.'.length);
    _parameters[key] = previous;
    // The command failed, so this client no longer owns the value and the next
    // server snapshot must be allowed to correct it.
    _locallyChangedAt.remove(binding);
    notifyListeners();
    logDebug(
      '[SDUI] Rolled back $binding to $previous after command failure.',
    );
  }

  // ── Send / dataOperation public API ─────────────────────────────────────────

  Future<void> sendBinding(String binding) async {
    if (binding.isEmpty) return;
    final control = controlForBinding(binding);
    if (control == null) return;
    if (!_isControlWritable(control)) {
      logDebug('[DEVICE ACCESS] send blocked for read-only binding=$binding');
      return;
    }

    final value = resolveBinding(binding);
    final hadOptimisticPrevious = _optimisticPrevious.containsKey(binding);
    final previous = _optimisticPrevious.remove(binding);
    final isAccordionToggle = AppState.frameRevealsResponseRows(control) ||
        control['revealsResponse'] == true;
    final request = _buildCommandRequest(
      control: control,
      binding: binding,
      value: value,
    );
    if (request == null) {
      if (hadOptimisticPrevious && !isAccordionToggle) {
        _rollbackBinding(binding, previous);
      }
      return;
    }

    _pendingBindings.add(binding);
    notifyListeners();

    try {
      final result = await _sendDeviceCommand(request);
      if (!result.accepted) {
        if (!isAccordionToggle) {
          _showCommandError(result.message ?? '[Device Command] Unknown error.');
        }
        if (result.status == DeviceCommandStatus.authFailure) {
          await _notifyAuthenticationFailure();
        }
        if (hadOptimisticPrevious && !isAccordionToggle) {
          _rollbackBinding(binding, previous);
        }
      } else {
        _applyDeviceCommandResult(result);
        logDebug(
          '[DEVICE RESULT] control=${control['id']} binding=$binding '
          'status=${result.status} response=${result.responseBody ?? result.rawResponse ?? "<none>"}',
        );
      }
    } finally {
      _pendingBindings.remove(binding);
      notifyListeners();
    }
  }

  Future<void> executeDataOperation(Map<String, dynamic> action) async {
    final input = Map<String, dynamic>.from(
      action['input'] as Map? ?? const {},
    );

    if (action['dataSource']?.toString() == 'deviceCommands') {
      final declaredBinding = _bindingForActionInput(input);
      Map<String, dynamic>? control =
          declaredBinding == null ? null : controlForBinding(declaredBinding);

      if (control == null) {
        final parameter = input['parameter']?.toString().trim();
        final frameName = input['frameName']?.toString().trim();
        for (final candidate in controls) {
          final candidateParameter =
              (candidate['parameterName'] ?? candidate['parameter'])
                  ?.toString()
                  .trim();
          final candidateFrame =
              candidate['deviceFrame']?['name']?.toString().trim();
          if ((parameter != null &&
                  parameter.isNotEmpty &&
                  candidateParameter == parameter) ||
              (frameName != null &&
                  frameName.isNotEmpty &&
                  candidateFrame == frameName)) {
            control = candidate;
            break;
          }
        }
      }

      final binding = control?['binding']?.toString() ?? '';
      if (control != null && binding.isNotEmpty) {
        await sendBinding(binding);
        return;
      }

      _showCommandError(
        '[Device Command] deviceCommands dataOperation cannot be matched to a '
        'schema control/binding. Flutter will not infer a parameter target.',
      );
      return;
    }
    final resolved = <String, dynamic>{};
    for (final entry in input.entries) {
      resolved[entry.key] = _resolveTemplateValue(entry.value);
    }

    final binding = _bindingForActionInput(input);
    final rawEndpoint = action['endpoint']?.toString() ??
        _schema['meta']?['links']?['parameters']?.toString();
    final endpoint = rewritePublicApiUrl(rawEndpoint);

    if (endpoint == null || endpoint.isEmpty) {
      _showCommandError(
        '[Device Command] dataOperation has no resolvable endpoint.\n'
        'Action type: ${action['type']}\n'
        'Ensure meta.links.parameters exists in the schema.',
      );
      return;
    }

    // Resolve device identity for auth and error reporting.
    final identity = resolveDeviceIdentity();
    if (identity.modelId == null || identity.nodeId == null) {
      _showCommandError(
        '[Device Command] dataOperation: modelId or nodeId missing.\n'
        'Ensure the schema contains _clientConnection.modelId and nodeId.',
      );
      return;
    }

    // Inject node_id into the resolved payload so the API can route correctly.
    resolved['node_id'] = identity.nodeId;

    final previous = binding == null ? null : resolveBinding(binding);
    if (binding != null) {
      _pendingBindings.add(binding);
      notifyListeners();
    }

    try {
      final result = await _sendDeviceCommand(
        DeviceCommandRequest(
          modelId: identity.modelId!,
          nodeId: identity.nodeId!,
          parameter: resolved['parameter']?.toString() ?? '',
          parameterKey: resolved['parameterKey']?.toString() ?? '',
          value: resolved['value'],
          endpointUrl: endpoint,
          accessToken: _accessToken.isNotEmpty ? _accessToken : null,
          commands: List<dynamic>.from(
            resolved['commands'] as List? ?? const [],
          ),
          frameName: resolved['frameName']?.toString(),
          commandId: resolved['commandId'],
          functionCode: resolved['functionCode'],
          actionId: resolved['actionId'],
          multipleUi: List<dynamic>.from(
            resolved['multipleUi'] as List? ?? const [],
          ),
          triggerUi: List<dynamic>.from(
            resolved['triggerUi'] as List? ?? const [],
          ),
          binding: binding,
        ),
      );

      if (!result.accepted) {
        _showCommandError(result.message ?? '[Device Command] Unknown error.');
        if (result.status == DeviceCommandStatus.authFailure) {
          await _notifyAuthenticationFailure();
        }
        if (binding != null && previous != null) {
          _rollbackBinding(binding, previous);
        }
      } else {
        logDebug('[DEVICE SEND] dataOperation → ${result.status}');
      }
    } finally {
      if (binding != null) {
        _pendingBindings.remove(binding);
        notifyListeners();
      }
    }
  }

  String? _bindingForActionInput(Map<String, dynamic> input) {
    final raw = input['value']?.toString();
    if (raw == null) return null;
    if (raw.startsWith(r'$device.parameters.')) {
      return raw.substring(1);
    }
    return null;
  }

  dynamic _resolveTemplateValue(dynamic value) {
    if (value is! String) return value;
    if (value == r'$app.modelNo') {
      return _schema['meta']?['app']?['modelNo'];
    }
    if (value.startsWith(r'$device.parameters.')) {
      return resolveBinding(value.substring(1));
    }
    return value;
  }

  bool _isTrustedEfactorUri(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    return host == 'efactor.tech' || host.endsWith('.efactor.tech');
  }

  Future<void> executeApi(Map<String, dynamic> action) async {
    final rawUrl = rewritePublicApiUrl(
      action['value']?.toString() ?? action['url']?.toString(),
    );
    if (rawUrl == null) return;
    final method = action['method']?.toString().toUpperCase() ?? 'POST';
    final payload = Map<String, dynamic>.from(
      action['payload'] as Map? ?? const {},
    );

    if (method == 'GET') {
      final uri = Uri.parse(rawUrl);
      final headers = <String, String>{'Accept': 'application/json'};
      if (_accessToken.isNotEmpty && _isTrustedEfactorUri(uri)) {
        headers['Authorization'] = 'Bearer $_accessToken';
      }
      final response = await _client
          .get(uri, headers: headers)
          .timeout(Duration(milliseconds: _apiTimeoutMs(action)));
      if (response.statusCode == 401 || response.statusCode == 403) {
        await _notifyAuthenticationFailure();
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('API action failed: ${response.statusCode}');
      }
      return;
    }
    await _postJson(Uri.parse(rawUrl), payload, null, action: action);
  }

  Future<bool> _postJson(
    Uri uri,
    Map<String, dynamic> payload,
    String? binding, {
    Map<String, dynamic>? action,
  }) async {
    final previous = binding == null ? null : resolveBinding(binding);
    if (binding != null) {
      _pendingBindings.add(binding);
      notifyListeners();
    }

    // Build headers with Authorization if an access token is available.
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (_accessToken.isNotEmpty && _isTrustedEfactorUri(uri)) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }

    try {
      final response = await _client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(
            Duration(
              milliseconds: _apiTimeoutMs(action ?? const <String, dynamic>{}),
            ),
          );

      if (response.statusCode == 401 || response.statusCode == 403) {
        _showCommandError(
          '[Device Command] Authentication failed (HTTP ${response.statusCode}).\n'
          'The access token may be expired or missing.',
        );
        if (binding != null && previous != null) {
          _rollbackBinding(binding, previous);
        }
        await _notifyAuthenticationFailure();
        return false;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _showCommandError(
          '[Device Command] Server rejected request (HTTP ${response.statusCode}).\n'
          'Binding: ${binding ?? "N/A"}\n'
          'URL: $uri\n'
          'Response: ${response.body}',
        );
        if (binding != null && previous != null) {
          _rollbackBinding(binding, previous);
        }
        return false;
      }
      return true;
    } catch (error) {
      _showCommandError(
        '[Device Command] Request failed: $error\nBinding: ${binding ?? "N/A"}',
      );
      if (binding != null && previous != null) {
        _rollbackBinding(binding, previous);
      }
      return false;
    } finally {
      if (binding != null) {
        _pendingBindings.remove(binding);
        notifyListeners();
      }
    }
  }

  void runExpression(String expression) {
    final parts = expression.split('=');
    if (parts.length != 2) return;
    final target = parts[0].trim();
    final value = _evalNum(parts[1].trim());
    if (value == null) return;
    if (target == 'activePageIndex') activePageIndex = value.toInt();
  }

  num? _evalNum(String input) {
    final value = input.trim();

    final minMatch = RegExp(r'^min\((.+),(.+)\)$').firstMatch(value);
    if (minMatch != null) {
      final a = _evalNum(minMatch.group(1)!);
      final b = _evalNum(minMatch.group(2)!);
      return a == null || b == null ? null : math.min(a, b);
    }

    final maxMatch = RegExp(r'^max\((.+),(.+)\)$').firstMatch(value);
    if (maxMatch != null) {
      final a = _evalNum(maxMatch.group(1)!);
      final b = _evalNum(maxMatch.group(2)!);
      return a == null || b == null ? null : math.max(a, b);
    }

    final operators = RegExp(r'(?<=.)([+\-])').allMatches(value).toList();
    if (operators.isNotEmpty) {
      final match = operators.last;
      final left = _evalNum(value.substring(0, match.start));
      final right = _evalNum(value.substring(match.end));
      if (left == null || right == null) return null;
      return match.group(1) == '+' ? left + right : left - right;
    }

    switch (value) {
      case 'activePageIndex':
        return _activePageIndex;
      case 'pages.length':
        return pages.length;
      default:
        return num.tryParse(value);
    }
  }

  @override
  void dispose() {
    EfactorCloudService.instance.localDevices.removeListener(_onLocalDevicesChanged);
    _parameterPersistTimer?.cancel();
    // Flush any pending parameter write so the last toggle/slider isn't lost.
    unawaited(_persistParametersNow());
    for (final timer in _sendDebounce.values) {
      timer.cancel();
    }
    for (final tick in _bindingTicks.values) {
      tick.dispose();
    }
    _bindingTicks.clear();
    _navigationTick.dispose();
    _schemaStructureTick.dispose();
    _scanRepository.dispose();
    _client.close();
    super.dispose();
  }
}

class _BindingTick extends ChangeNotifier {
  void ping() => notifyListeners();
}
