import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_patch.dart';


class IotSduiState extends ChangeNotifier {
  IotSduiState({
    required this.schema,
    required this.accessToken,
    this.apiBaseUri,
    http.Client? client,
  }) : _client = client ?? http.Client() {
    _initSearchFromSchema();
    EfactorCloudService.instance.localDevices.addListener(_onLocalDevicesChanged);
    EfactorCloudService.instance.liveNodes.addListener(_onLiveNodesChanged);
    if (EfactorCloudService.instance.liveNodes.value.isNotEmpty) {
      applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
    }
  }

  void _onLocalDevicesChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  void _onLiveNodesChanged() {
    if (_disposed) return;
    applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
  }

  Map<String, dynamic> schema;
  final String accessToken;
  final Uri? apiBaseUri;
  final http.Client _client;

  Future<void> Function()? reloadHandler;
  Future<dynamic> Function(Map<String, dynamic> action)? hostActionHandler;

  /// Host-owned bridge to the existing Device SDUI.
  ///
  /// modelId/nodeId are resolved only from the selected live device record and
  /// the schema datasource metadata. No product/model/node value is embedded
  /// in Flutter.
  Future<dynamic> Function({
    required String modelId,
    required String nodeId,
    required Map<String, dynamic> device,
  })?
  deviceOpenHandler;

  String? _lastError;
  bool _busy = false;
  bool _disposed = false;
  bool _notifyScheduled = false;
  static final Map<String, Future<dynamic>> _sharedGets =
      <String, Future<dynamic>>{};
  static final Map<String, _SharedGetResult> _sharedGetResults =
      <String, _SharedGetResult>{};
  final Map<String, Future<dynamic>> _inFlightSources =
      <String, Future<dynamic>>{};
  final Map<String, dynamic> _runtime = <String, dynamic>{};
  List<Map<String, dynamic>>? _liveDevices;
  bool _searchVisible = false;
  String _searchQuery = '';

  bool get isSearchVisible => _searchVisible;
  String get searchQuery => _searchQuery;

  void _initSearchFromSchema() {
    final search = _map(page['header']?['search']);
    if (search != null && search['initiallyVisible'] == true) {
      _searchVisible = true;
    }
  }

  bool isRuntimeActive(String target) {
    if (target == 'page.header.search' || target == 'search') {
      return _searchVisible;
    }
    final val = readBinding(target);
    if (val is bool) return val;
    if (val is String) {
      final t = val.trim().toLowerCase();
      return t == 'true' || t == '1' || t == 'yes' || t == 'on';
    }
    return val != null && val != 0;
  }

  void toggleRuntimeTarget(String target) {
    final current = isRuntimeActive(target);
    final next = !current;
    writeRuntime(target, next);
    if (target == 'page.header.search' || target == 'search') {
      _searchVisible = next;
      if (!next) {
        _searchQuery = '';
      }
    }
    notifyListeners();
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
  }

  void clearSearchQuery() {
    if (_searchQuery.isEmpty) return;
    _searchQuery = '';
    notifyListeners();
  }

  Future<SchemaPatchResult> replaceSchema(Map<String, dynamic> incoming) async {
    if (_disposed) {
      return SchemaPatchResult(
        unchanged: true,
        structural: false,
        changedNodeIds: const <String>{},
        schema: schema,
      );
    }
    final previousSources = SchemaPatch.nodeFingerprint(
      schema['dataSources'] ?? page['dataSources'],
    );
    final patch = SchemaPatch.merge(schema, incoming);
    if (patch.unchanged) return patch;

    schema = patch.schema;
    if (_searchQuery.isEmpty) {
      _initSearchFromSchema();
    }
    final nextSources = SchemaPatch.nodeFingerprint(
      schema['dataSources'] ?? page['dataSources'],
    );
    final reloadData = previousSources != nextSources || patch.dataSourcesChanged;
    if (reloadData) {
      _liveDevices = null;
    }
    notifyListeners();
    if (reloadData) {
      await loadInitialData();
    }
    return patch;
  }

  String? get lastError => _lastError;
  bool get busy => _busy;

  Map<String, dynamic> get page =>
      _map(schema['page']) ?? const <String, dynamic>{};

  Map<String, dynamic> get theme =>
      _map(schema['theme']) ?? _map(page['theme']) ?? const <String, dynamic>{};

  Map<String, dynamic> get typography =>
      _map(schema['typography']) ?? const <String, dynamic>{};

  Map<String, dynamic> get icons =>
      _map(schema['icons']) ?? const <String, dynamic>{};

  Map<String, dynamic> get dataSources =>
      _map(schema['dataSources']) ??
      _map(page['dataSources']) ??
      const <String, dynamic>{};

  List<dynamic> get components {
    final value = schema['components'] ?? page['components'];
    return value is List ? value : const <dynamic>[];
  }

  Map<String, dynamic>? componentByType(String type) {
    for (final raw in components) {
      final component = _map(raw);
      if (component?['type']?.toString() == type) {
        return component;
      }
    }
    return null;
  }

  Map<String, dynamic>? componentById(String id) {
    for (final raw in components) {
      final component = _map(raw);
      if (component?['id']?.toString() == id) {
        return component;
      }
    }
    return null;
  }

  Map<String, dynamic>? get deviceGrid => componentByType('deviceGrid');

  List<Map<String, dynamic>> get devices {
    if (_liveDevices != null) {
      return List<Map<String, dynamic>>.unmodifiable(_liveDevices!);
    }

    final root = schema['devices'];
    if (root is List) {
      return _mapList(root);
    }

    final items = deviceGrid?['items'];
    if (items is List) {
      return _mapList(items);
    }

    return const <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> get filteredDevices {
    final all = devices;
    if (!_searchVisible || _searchQuery.trim().isEmpty) {
      return all;
    }

    final query = _searchQuery.trim().toLowerCase();
    final headerSearch = _map(page['header']?['search']);
    final matchField = headerSearch?['matchField']?.toString().trim();

    return all.where((device) {
      if (matchField != null && matchField.isNotEmpty) {
        final val = device[matchField]?.toString().toLowerCase() ?? '';
        if (val.contains(query)) return true;
      }
      final productName =
          device['product_name']?.toString().toLowerCase() ?? '';
      final name = device['name']?.toString().toLowerCase() ?? '';
      final deviceName =
          device['device_name']?.toString().toLowerCase() ?? '';
      final nodeId = device['node_id']?.toString().toLowerCase() ?? '';
      final model = device['model']?.toString().toLowerCase() ?? '';
      final brand = device['brand_name']?.toString().toLowerCase() ?? '';

      return productName.contains(query) ||
          name.contains(query) ||
          deviceName.contains(query) ||
          nodeId.contains(query) ||
          model.contains(query) ||
          brand.contains(query);
    }).toList();
  }

  Future<void> loadInitialData() async {
    final sources = <String>[];
    final secondarySources = <String>{};
    final primarySources = <String>{};

    void addSource(dynamic raw, {required bool secondary}) {
      final id = raw?.toString().trim() ?? '';
      if (id.isEmpty) return;
      if (!sources.contains(id)) sources.add(id);
      if (secondary) {
        secondarySources.add(id);
      } else {
        primarySources.add(id);
      }
    }

    for (final raw in components) {
      final component = _map(raw);
      addSource(component?['dataSource'], secondary: false);
      addSource(component?['liveStatusSource'], secondary: true);

      final refreshWith = component?['refreshWith'];
      if (refreshWith is List) {
        for (final id in refreshWith) {
          // refreshWith is an orchestration list. A datasource that is also
          // declared as dataSource remains primary; a datasource declared as
          // liveStatusSource remains secondary. Unknown entries stay primary
          // so schema/configuration failures are not silently hidden.
          final text = id?.toString().trim() ?? '';
          if (text.isEmpty) continue;
          addSource(
            text,
            secondary:
                secondarySources.contains(text) &&
                !primarySources.contains(text),
          );
        }
      }
    }

    // Primary datasources provide the data required for the first useful
    // render, so wait for them. Secondary/live-status datasources must never
    // block the first visible IoT page: start those after the primary data is
    // available and let them enrich the state asynchronously.
    for (final sourceId in sources) {
      if (!_dataSourceExecutable(sourceId)) continue;

      final isSecondary =
          secondarySources.contains(sourceId) &&
          !primarySources.contains(sourceId);
      if (isSecondary) continue;

      try {
        await callDataSource(sourceId, reportError: true);
      } catch (error) {
        logDebug(
          '[IOT_SDUI][INITIAL_DATA] "$sourceId" failed: ${_redact(error.toString())}',
        );
      }
    }

    for (final sourceId in sources) {
      if (!_dataSourceExecutable(sourceId)) continue;

      final isSecondary =
          secondarySources.contains(sourceId) &&
          !primarySources.contains(sourceId);
      if (!isSecondary) continue;

      unawaited(_loadSecondarySource(sourceId));
    }
  }

  Future<void> _loadSecondarySource(String sourceId) async {
    if (_disposed) return;
    try {
      await callDataSource(sourceId, reportError: false);
    } catch (error) {
      // A secondary status/enrichment request is never allowed to replace a
      // usable IoT page. Network errors are logged safely and the current
      // primary device data remains visible.
      _softFail(
        'Secondary datasource "$sourceId" failed: ${_redact(error.toString())}',
      );
    }
  }

  Future<void> refreshDeviceGrid() async {
    final grid = deviceGrid;
    if (grid == null) return;

    final ids = <String>[];
    final primaryId = grid['dataSource']?.toString().trim() ?? '';
    final liveStatusId = grid['liveStatusSource']?.toString().trim() ?? '';

    final refreshWith = grid['refreshWith'];
    if (refreshWith is List) {
      for (final raw in refreshWith) {
        final id = raw?.toString().trim() ?? '';
        if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
    }
    if (ids.isEmpty) {
      for (final raw in <dynamic>[
        grid['dataSource'],
        grid['liveStatusSource'],
      ]) {
        final id = raw?.toString().trim() ?? '';
        if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
    }

    for (final id in ids) {
      if (!_dataSourceExecutable(id)) continue;
      final isSecondaryStatus =
          id == liveStatusId && (primaryId.isEmpty || id != primaryId);
      await callDataSource(id, reportError: !isSecondaryStatus);
    }
  }

  Map<String, dynamic>? typographyStyle(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    return _map(typography[name.trim()]);
  }

  dynamic readBinding(
    String path, {
    Map<String, dynamic>? device,
    Map<String, dynamic>? event,
  }) {
    final normalized = path.trim();
    if (normalized.isEmpty) return null;

    if (normalized.startsWith('device.')) {
      return _readPath(device, normalized.substring(7));
    }
    if (normalized.startsWith('event.')) {
      return _readPath(event, normalized.substring(6));
    }
    if (normalized.startsWith('theme.')) {
      return _readPath(theme, normalized.substring(6));
    }
    if (normalized.startsWith('page.summary.')) {
      final key = normalized.substring('page.summary.'.length);
      if (key == 'total') return devices.length;
      if (key == 'online') return devices.where(_deviceOnline).length;
      if (key == 'offline') {
        return devices.where((d) => !_deviceOnline(d)).length;
      }
    }
    if (normalized.startsWith('page.')) {
      return _readPath(page, normalized.substring(5));
    }
    if (normalized.startsWith('runtime.')) {
      return _readPath(_runtime, normalized.substring(8));
    }

    // Workflow variables such as `scan.node_id` and `location.latitude` are
    // runtime values declared by the server schema. They deliberately do not
    // live in the published schema itself. Resolve them before falling back to
    // schema data so overlay/data-source templates can stay fully dynamic.
    final runtimeValue = _readPath(_runtime, normalized);
    if (runtimeValue != null) return runtimeValue;

    return _readPath(schema, normalized);
  }

  dynamic resolveTemplate(
    dynamic value, {
    Map<String, dynamic>? device,
    Map<String, dynamic>? event,
  }) {
    return _resolveTemplate(value, device: device, event: event);
  }

  bool resolveCondition(
    dynamic condition, {
    Map<String, dynamic>? device,
    Map<String, dynamic>? event,
    bool fallback = true,
  }) {
    final resolved = _resolveTemplate(condition, device: device, event: event);

    if (resolved is bool) return resolved;
    if (resolved is num) return resolved != 0;
    if (resolved is String) {
      final text = resolved.trim().toLowerCase();
      if (<String>{'true', '1', 'yes', 'on'}.contains(text)) return true;
      if (<String>{'false', '0', 'no', 'off', ''}.contains(text)) {
        return false;
      }
    }

    return fallback;
  }

  void writeRuntime(String path, dynamic value) {
    final parts = path.split('.').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return;

    Map<String, dynamic> current = _runtime;
    for (var i = 0; i < parts.length - 1; i++) {
      final key = parts[i];
      final child = current[key];
      if (child is Map<String, dynamic>) {
        current = child;
      } else if (child is Map) {
        final converted = Map<String, dynamic>.from(
          child.cast<dynamic, dynamic>(),
        );
        current[key] = converted;
        current = converted;
      } else {
        final created = <String, dynamic>{};
        current[key] = created;
        current = created;
      }
    }

    current[parts.last] = value;
    notifyListeners();
  }

  bool canExecuteAction(
    Map<String, dynamic> action, {
    Map<String, dynamic>? device,
  }) {
    final type = (action['action'] ?? action['type'])?.toString().trim();

    if (type == 'navigate') {
      return action['route']?.toString().trim().isNotEmpty == true &&
          hostActionHandler != null;
    }

    if (type == 'api') {
      final source = (action['dataSource'] ?? action['source'])
          ?.toString()
          .trim();
      return source != null &&
          source.isNotEmpty &&
          _dataSourceExecutable(source, device: device);
    }

    if (type == 'callApi') {
      final source = action['source']?.toString().trim();
      return source != null &&
          source.isNotEmpty &&
          _dataSourceExecutable(source, device: device);
    }

    if (type == 'hostAction' || type == 'openOverlay') {
      if (type == 'openOverlay' &&
          action['overlayId']?.toString().trim().isNotEmpty != true) {
        return false;
      }
      return hostActionHandler != null;
    }

    if (type == 'sequence') {
      final rawActions = action['actions'] ?? action['steps'];
      if (rawActions is! List || rawActions.isEmpty) return false;
      for (final raw in rawActions) {
        final child = _map(raw);
        if (child == null || !canExecuteAction(child, device: device)) {
          return false;
        }
      }
      return true;
    }

    if (type == 'openDevice' || type == 'open-device') {
      return device != null && canOpenDevice(device);
    }

    if (type == 'reloadSchema') {
      return reloadHandler != null;
    }

    if (type == 'toggle') {
      final target =
          (action['target'] ?? action['property'])?.toString().trim();
      return target != null && target.isNotEmpty;
    }

    if (type == 'set' || type == 'setValue') {
      final target =
          (action['target'] ?? action['property'])?.toString().trim();
      return target != null && target.isNotEmpty;
    }

    if ((type == null || type.isEmpty) &&
        action['method'] != null &&
        action['url'] != null) {
      return _urlExecutable(action['url'], device: device);
    }

    return false;
  }

  Future<dynamic> executeAction(
    Map<String, dynamic> action, {
    Map<String, dynamic>? device,
    Map<String, dynamic>? event,
  }) async {
    final type = (action['action'] ?? action['type'])?.toString().trim();

    try {
      _lastError = null;

      if (type == 'navigate') {
        final handler = hostActionHandler;
        if (handler == null) {
          return _fail('No navigation host handler is registered.');
        }
        return handler(action);
      }

      if (type == 'api') {
        final source = (action['dataSource'] ?? action['source'])
            ?.toString()
            .trim();
        if (source == null || source.isEmpty) {
          return _fail('API action is missing dataSource/source.');
        }
        return callDataSource(source, device: device, event: event);
      }

      if (type == 'callApi') {
        final source = action['source']?.toString().trim();
        if (source == null || source.isEmpty) {
          return _fail('callApi action is missing source.');
        }
        return callDataSource(source, device: device, event: event);
      }

      if (type == 'sequence') {
        final rawActions = action['actions'] ?? action['steps'];
        if (rawActions is! List) {
          return _fail('sequence action requires actions[] or steps[].');
        }
        dynamic result;
        for (final raw in rawActions) {
          final child = _map(raw);
          if (child == null) continue;
          result = await executeAction(child, device: device, event: event);
        }
        return result;
      }

      if (type == 'openDevice' || type == 'open-device') {
        if (device == null) {
          return _fail('openDevice action requires the selected device item.');
        }
        return openDevice(device);
      }

      if (type == 'reloadSchema') {
        final handler = reloadHandler;
        if (handler == null) {
          return _fail('No reloadSchema handler is registered.');
        }
        await handler();
        return null;
      }

      if (type == 'hostAction' || type == 'openOverlay') {
        final handler = hostActionHandler;
        if (handler == null) {
          return _fail('No IoT host action handler is registered.');
        }
        return handler(action);
      }

      if (type == 'toggle') {
        final target =
            (action['target'] ?? action['property'])?.toString().trim();
        if (target == null || target.isEmpty) {
          return _fail('toggle action is missing target/property.');
        }
        toggleRuntimeTarget(target);
        return isRuntimeActive(target);
      }

      if (type == 'set' || type == 'setValue') {
        final target =
            (action['target'] ?? action['property'])?.toString().trim();
        if (target == null || target.isEmpty) {
          return _fail('set action is missing target/property.');
        }
        final val = action.containsKey('value') ? action['value'] : null;
        writeRuntime(target, val);
        notifyListeners();
        return val;
      }

      if ((type == null || type.isEmpty) &&
          action['method'] != null &&
          action['url'] != null) {
        return _callHttp(
          action,
          sourceName: 'inlineAction',
          device: device,
          event: event,
          applyResponse: false,
        );
      }

      return _fail(
        'Unsupported IoT action contract: ${action['type'] ?? action['action']}',
      );
    } catch (error) {
      return _fail(_redact(error.toString()));
    }
  }

  bool actionRequestsOpenDevice(Map<String, dynamic> action) {
    final type = (action['action'] ?? action['type'])?.toString().trim();
    if (type == 'openDevice' || type == 'open-device') return true;

    if (type == 'hostAction') {
      final name = action['name']?.toString().trim();
      if (name == 'openDevice' || name == 'open-device') return true;
    }

    if (type == 'sequence') {
      final raw = action['actions'] ?? action['steps'];
      if (raw is List) {
        for (final childRaw in raw) {
          final child = _map(childRaw);
          if (child != null && actionRequestsOpenDevice(child)) return true;
        }
      }
    }
    return false;
  }

  bool canOpenDevice(Map<String, dynamic> device) {
    return deviceOpenHandler != null && _resolveDeviceIdentity(device) != null;
  }

  Future<dynamic> openDevice(Map<String, dynamic> device) async {
    final handler = deviceOpenHandler;
    if (handler == null) {
      return _fail('No Device SDUI host callback is registered.');
    }

    final identity = _resolveDeviceIdentity(device);
    if (identity == null) {
      final sourceId = deviceGrid?['dataSource']?.toString().trim();
      final response = sourceId == null || sourceId.isEmpty
          ? null
          : _map(_map(dataSources[sourceId])?['response']);
      final configuredModelField = response?['modelNoField']?.toString().trim();

      return _fail(
        'Selected IoT device does not provide both node id and model number. '
        'Backend must return the node field declared by '
        'dataSources.$sourceId.response.idField and a model field declared by '
        'dataSources.$sourceId.response.modelNoField'
        '${configuredModelField == null || configuredModelField.isEmpty ? ' '
                  '(recommended: modelNumber)' : ' ($configuredModelField)'}.',
      );
    }

    final modelId = identity['modelId']!;
    final nodeId = identity['nodeId']!;

    logDebug(
      '[IOT_SDUI][OPEN_DEVICE] '
      'modelId=$modelId nodeId=$nodeId',
    );

    return handler(modelId: modelId, nodeId: nodeId, device: device);
  }

  Map<String, String>? _resolveDeviceIdentity(Map<String, dynamic> device) {
    final sourceId = deviceGrid?['dataSource']?.toString().trim();

    final source = sourceId == null || sourceId.isEmpty
        ? null
        : _map(dataSources[sourceId]);

    final response = _map(source?['response']);

    final configuredControlField = response?['controlIdField']
        ?.toString()
        .trim();
    final configuredNodeField = response?['idField']?.toString().trim();
    final configuredModelField = response?['modelNoField']?.toString().trim();

    final nodeId = _firstDeviceValue(device, <String>[
      if (configuredControlField != null && configuredControlField.isNotEmpty)
        configuredControlField,
      'node_id',
      'nodeId',
      if (configuredNodeField != null && configuredNodeField.isNotEmpty)
        configuredNodeField,
    ]);

    final modelId = _firstDeviceValue(device, <String>[
      if (configuredModelField != null && configuredModelField.isNotEmpty)
        configuredModelField,
      // Backward-compatible aliases used by existing Efactor device payloads.
      // These are field names only; no model value is hardcoded.
      'modelNumber',
      'model_no',
      'modelNo',
      'model_id',
      'modelId',
      'modelName',
    ]);

    if (nodeId == null || modelId == null) {
      logDebug(
        '[IOT_SDUI][OPEN_DEVICE] identity incomplete '
        'nodeField=${configuredNodeField ?? '-'} '
        'modelField=${configuredModelField ?? '-'} '
        'hasNode=${nodeId != null} hasModel=${modelId != null}',
      );
      return null;
    }

    return <String, String>{'modelId': modelId, 'nodeId': nodeId};
  }

  String? _firstDeviceValue(Map<String, dynamic> device, List<String> keys) {
    final seen = <String>{};

    for (final key in keys) {
      final normalized = key.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }

      final value = _readPath(device, normalized);
      final text = value?.toString().trim();

      if (text != null && text.isNotEmpty) {
        return text;
      }
    }

    return null;
  }

  Future<dynamic> callDataSource(
    String sourceId, {
    Map<String, dynamic>? device,
    Map<String, dynamic>? event,
    bool reportError = true,
  }) async {
    if (_disposed) return null;
    final source = _map(dataSources[sourceId]);
    if (source == null) {
      return reportError
          ? _fail('Schema datasource "$sourceId" is missing.')
          : _softFail('Schema datasource "$sourceId" is missing.');
    }

    final contract = _effectiveDataSourceContract(source);
    final coalesce = device == null && event == null;
    if (coalesce) {
      final existing = _inFlightSources[sourceId];
      if (existing != null) return existing;
    }

    final pending = _callHttp(
      contract,
      sourceName: sourceId,
      device: device,
      event: event,
      applyResponse: true,
      reportError: reportError,
    );
    if (coalesce) {
      _inFlightSources[sourceId] = pending.whenComplete(() {
        _inFlightSources.remove(sourceId);
      });
      return _inFlightSources[sourceId];
    }
    return pending;
  }

  /// Selects the transport contract declared by the server for this platform.
  ///
  /// IoT schemas can publish a web/session transport at the datasource
  /// root and a mobile transport under `nativeApi`. Android and iOS use the
  /// nested mobile transport when present. Web keeps the existing top-level
  /// contract. No endpoint, action, token, node, model or protocol value is
  /// embedded in Flutter here.
  Map<String, dynamic> _effectiveDataSourceContract(
    Map<String, dynamic> source,
  ) {
    if (!_useSchemaNativeApi) return source;

    final native = _map(source['nativeApi']);
    final nativeUrl = native?['url']?.toString().trim() ?? '';
    if (native == null || nativeUrl.isEmpty) return source;

    final effective = Map<String, dynamic>.from(source);

    // Override only fields explicitly published by nativeApi. Common response
    // and orchestration metadata remains inherited from the datasource root.
    const transportKeys = <String>{
      'url',
      'method',
      'query',
      'headers',
      'body',
      'response',
      'onSuccess',
    };

    for (final key in transportKeys) {
      if (native.containsKey(key)) {
        effective[key] = native[key];
      }
    }

    // A top-level `auth: session` contract belongs to the web proxy. Do not
    // carry it into Android/iOS. Native auth is used when explicitly declared;
    // otherwise _callHttp falls back to schema.auth and its secure-state token
    // binding.
    if (native.containsKey('auth')) {
      effective['auth'] = native['auth'];
    } else {
      effective.remove('auth');
    }

    return effective;
  }

  bool get _useSchemaNativeApi {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<dynamic> _callHttp(
    Map<String, dynamic> contract, {
    required String sourceName,
    required Map<String, dynamic>? device,
    required Map<String, dynamic>? event,
    required bool applyResponse,
    bool reportError = true,
  }) async {
    if (_disposed) return null;
    final rawUrl = contract['url']?.toString().trim() ?? '';
    if (rawUrl.isEmpty) {
      return reportError
          ? _fail('Datasource "$sourceName" is missing url.')
          : _softFail('Datasource "$sourceName" is missing url.');
    }

    final resolvedUrl =
        _resolveTemplate(rawUrl, device: device, event: event)?.toString() ??
        '';

    if (RegExp(r'\{\{[^}]+\}\}').hasMatch(resolvedUrl)) {
      return reportError
          ? _fail(
              'Datasource "$sourceName" contains an unresolved URL template.',
            )
          : _softFail(
              'Datasource "$sourceName" contains an unresolved URL template.',
            );
    }

    final resolvedUri = resolveUrl(resolvedUrl);
    if (resolvedUri == null) {
      return reportError
          ? _fail('Cannot resolve datasource URL for "$sourceName".')
          : _softFail('Cannot resolve datasource URL for "$sourceName".');
    }
    var uri = resolvedUri;

    if (_isLoopback(uri)) {
      return reportError
          ? _fail(
              'Datasource "$sourceName" uses loopback host "${uri.host}". '
              'The backend schema must provide the real server URL for mobile.',
            )
          : _softFail(
              'Datasource "$sourceName" uses loopback host "${uri.host}".',
            );
    }

    // New IoT schemas declare query parameters separately from the base URL.
    // Resolve those values at runtime instead of requiring action/token to be
    // embedded in the URL.
    final declaredQuery = _map(contract['query']);
    if (declaredQuery != null && declaredQuery.isNotEmpty) {
      final query = <String, String>{...uri.queryParameters};
      for (final entry in declaredQuery.entries) {
        final resolved = _resolveTemplate(
          entry.value,
          device: device,
          event: event,
        );
        final text = resolved?.toString().trim() ?? '';
        if (text.isNotEmpty) query[entry.key] = text;
      }
      uri = uri.replace(queryParameters: query);
    }

    final headers = <String, String>{'Accept': 'application/json'};

    // Apply headers declared by the active datasource/nativeApi contract.
    // Header values can themselves use SDUI templates or secure-state
    // bindings, so resolve them using the same runtime resolver as query/body.
    final declaredHeaders = _map(contract['headers']);
    if (declaredHeaders != null && declaredHeaders.isNotEmpty) {
      for (final entry in declaredHeaders.entries) {
        final name = entry.key.trim();
        if (name.isEmpty) continue;

        final resolved = _resolveTemplate(
          entry.value,
          device: device,
          event: event,
        );
        final text = resolved?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          headers[name] = _normalizeRuntimeAuthorizationHeader(name, text);
        }
      }
    }

    final schemaAuth = _map(schema['auth']);
    final sourceAuth = _map(contract['auth']);

    final authType =
        sourceAuth?['type']?.toString() ?? schemaAuth?['type']?.toString();
    final headerName =
        sourceAuth?['headerName']?.toString() ??
        schemaAuth?['headerName']?.toString();
    final queryParam =
        sourceAuth?['param']?.toString() ??
        sourceAuth?['queryParam']?.toString() ??
        schemaAuth?['queryParam']?.toString();

    final token = accessToken.trim();
    if (token.isNotEmpty) {
      if ((authType == 'header' || headerName != null) &&
          headerName != null &&
          headerName.trim().isNotEmpty) {
        final resolvedHeaderName = headerName.trim();
        headers[resolvedHeaderName] = _normalizeRuntimeAuthorizationHeader(
          resolvedHeaderName,
          token,
        );
      }

      if ((authType == 'query' || queryParam != null) &&
          queryParam != null &&
          queryParam.trim().isNotEmpty) {
        uri = uri.replace(
          queryParameters: <String, String>{
            ...uri.queryParameters,
            queryParam.trim(): token,
          },
        );
      }
    }

    final method = contract['method']?.toString().trim().toUpperCase() ?? 'GET';
    final body = _resolveTemplate(
      contract['body'],
      device: device,
      event: event,
    );

    final shareKey = method == 'GET' && device == null && event == null
        ? '$method|$uri'
        : null;
    if (shareKey != null) {
      final cached = _sharedGetResults[shareKey];
      if (cached != null &&
          DateTime.now().difference(cached.at) < const Duration(seconds: 8)) {
        if (applyResponse) {
          _applyResponse(contract, cached.value);
          _lastError = null;
          notifyListeners();
        }
        return cached.value;
      }
      final existing = _sharedGets[shareKey];
      if (existing != null) {
        final decoded = await existing;
        if (_disposed) return null;
        if (applyResponse && decoded != null) {
          _applyResponse(contract, decoded);
          _lastError = null;
          notifyListeners();
        }
        return decoded;
      }
    }

    Completer<dynamic>? shareCompleter;
    if (shareKey != null) {
      shareCompleter = Completer<dynamic>();
      _sharedGets[shareKey] = shareCompleter.future;
    }

    _busy = true;
    if (!_disposed) notifyListeners();

    try {
      final result = await () async {
      Future<http.Response> sendRequest() async {
        switch (method) {
          case 'GET':
            return _client
                .get(uri, headers: headers)
                .timeout(const Duration(seconds: 30));
          case 'POST':
            headers['Content-Type'] = 'application/json';
            return _client
                .post(
                  uri,
                  headers: headers,
                  body: jsonEncode(body ?? const <String, dynamic>{}),
                )
                .timeout(const Duration(seconds: 30));
          default:
            throw UnsupportedError(
              'Unsupported HTTP method "$method" for "$sourceName".',
            );
        }
      }

      late http.Response response;
      try {
        response = await sendRequest();
      } catch (error) {
        if (method == 'GET') {
          final cached = await _readDatasourceCache(sourceName);
          if (cached != null && applyResponse) {
            logDebug(
              '[IOT_SDUI][DATASOURCE] OFFLINE FALLBACK source=$sourceName',
            );
            _applyResponse(contract, cached);
            _lastError = null;
            notifyListeners();
            return cached;
          }
        }
        if (method == 'GET' && !reportError) {
          // Secondary GETs are safe to retry once. This covers transient
          // connection-refused / DNS / timeout failures without making the
          // user press a page-level Retry button.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          try {
            response = await sendRequest();
          } catch (retryError) {
            return _softFail(
              'IoT API "$sourceName" is temporarily unavailable: '
              '${_redact(retryError.toString())}',
            );
          }
        } else if (method == 'GET' && applyResponse) {
          return reportError
              ? _fail(
                  'IoT API "$sourceName" is unavailable offline and no saved '
                  'device list exists yet. Open this page once while online.',
                )
              : _softFail(_redact(error.toString()));
        } else {
          rethrow;
        }
      }

      if (response.statusCode >= 500 &&
          response.statusCode <= 599 &&
          method == 'GET' &&
          !reportError) {
        // Retry only non-blocking secondary GET enrichment/status requests.
        // Mutations (power toggle, check/add device, etc.) must never be
        // replayed automatically because the server may have applied the
        // command even when its response failed.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        try {
          response = await sendRequest();
        } catch (retryError) {
          return _softFail(
            'IoT API "$sourceName" is temporarily unavailable: '
            '${_redact(retryError.toString())}',
          );
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (method == 'GET' &&
            applyResponse &&
            _isTransientStatusCode(response.statusCode)) {
          final cached = await _readDatasourceCache(sourceName);
          if (cached != null) {
            logDebug(
              '[IOT_SDUI][DATASOURCE] STALE FALLBACK '
              'source=$sourceName http=${response.statusCode}',
            );
            _applyResponse(contract, cached);
            _lastError = null;
            notifyListeners();
            return cached;
          }
        }
        final backendMessage = _httpFailureMessage(response);
        final message = backendMessage == null
            ? 'IoT API "$sourceName" failed with HTTP ${response.statusCode}.'
            : 'IoT API "$sourceName" failed with HTTP '
                  '${response.statusCode}: $backendMessage';
        return reportError ? _fail(message) : _softFail(message);
      }

      dynamic decoded;
      if (response.body.trim().isNotEmpty) {
        try {
          decoded = decodeJsonBody(
            body: response.body,
            contentType: response.headers['content-type'],
            source: sourceName,
          );
        } on FormatException {
          decoded = response.body;
        }
      }

      // HTTP 2xx only confirms transport-level success. Evaluate the
      // schema-declared response contract as well as legacy success/status
      // fields so an HTTP-200 error payload is never mistaken for a completed
      // mutation. No endpoint-specific value is hardcoded here.
      final applicationFailure = _applicationFailure(
        contract,
        decoded,
        sourceName: sourceName,
      );
      if (applicationFailure != null) {
        return reportError
            ? _fail(applicationFailure)
            : _softFail(applicationFailure);
      }

      _logDataSourceResult(
        sourceName: sourceName,
        statusCode: response.statusCode,
        contract: contract,
        decoded: decoded,
      );

      if (applyResponse) {
        _applyResponse(contract, decoded);
        if (method == 'GET') {
          await _writeDatasourceCache(sourceName, decoded);
        }
      }

      final onSuccess = _map(contract['onSuccess']);
      if (onSuccess != null) {
        await executeAction(onSuccess, device: device, event: event);
      }

      _lastError = null;
      notifyListeners();
      return decoded;
      }();
      if (shareCompleter != null && !shareCompleter.isCompleted) {
        shareCompleter.complete(result);
        if (shareKey != null && result != null) {
          _sharedGetResults[shareKey] = _SharedGetResult(result);
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (shareCompleter != null && !shareCompleter.isCompleted) {
        shareCompleter.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
      if (shareKey != null &&
          identical(_sharedGets[shareKey], shareCompleter?.future)) {
        _sharedGets.remove(shareKey);
      }
    }
  }

  String? _httpFailureMessage(http.Response response) {
    final raw = response.body.trim();
    if (raw.isEmpty || raw.startsWith('<')) return null;

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }

    final map = _map(decoded);
    if (map == null) return null;
    final errorMap = _map(map['error']);

    for (final value in <dynamic>[
      map['message'],
      map['description'],
      map['Description'],
      errorMap?['message'],
      errorMap?['description'],
      map['error'] is String ? map['error'] : null,
    ]) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return _redact(text);
    }
    return null;
  }

  String? _applicationFailure(
    Map<String, dynamic> contract,
    dynamic decoded, {
    required String sourceName,
  }) {
    final decodedMap = _map(decoded);
    if (decodedMap == null) return null;

    final response = _map(contract['response']);
    final successField = response?['successField']?.toString().trim();
    final statusField = response?['statusField']?.toString().trim();
    final messageField = response?['messageField']?.toString().trim();
    final errorField = response?['errorField']?.toString().trim();

    dynamic readDeclared(String? path, String fallback) {
      if (path != null && path.isNotEmpty) {
        return _readDynamicPath(decodedMap, path);
      }
      return decodedMap[fallback];
    }

    final successValue = readDeclared(successField, 'success');
    final okValue = decodedMap['ok'];
    final statusValue = readDeclared(statusField, 'status');

    final successOutcome = _asOutcomeBool(successValue);
    final okOutcome = _asOutcomeBool(okValue);
    final statusOutcome = _asOutcomeBool(statusValue);

    final explicitSuccess =
        successOutcome == true || okOutcome == true || statusOutcome == true;
    final explicitFailure =
        successOutcome == false || okOutcome == false || statusOutcome == false;

    final declaredError = errorField != null && errorField.isNotEmpty
        ? _readDynamicPath(decodedMap, errorField)?.toString().trim() ?? ''
        : '';
    final legacyError = decodedMap['error']?.toString().trim() ?? '';
    final hasErrorPayload = declaredError.isNotEmpty || legacyError.isNotEmpty;

    // Some legacy APIs return HTTP 200 with only {"error":"..."}. Treat that
    // as failure unless the same payload also carries an explicit success
    // indicator. This prevents scanner/add-device flows from advancing to the
    // visibility check after an authentication or validation failure.
    if (!explicitFailure && (!hasErrorPayload || explicitSuccess)) {
      return null;
    }

    String readMessage(String? path) {
      if (path == null || path.isEmpty) return '';
      return _readDynamicPath(decodedMap, path)?.toString().trim() ?? '';
    }

    final declaredMessage = readMessage(messageField);
    final message = declaredMessage.isNotEmpty
        ? declaredMessage
        : (decodedMap['message']?.toString().trim() ?? '').isNotEmpty
        ? decodedMap['message'].toString().trim()
        : (decodedMap['description']?.toString().trim() ?? '').isNotEmpty
        ? decodedMap['description'].toString().trim()
        : declaredError.isNotEmpty
        ? declaredError
        : legacyError.isNotEmpty
        ? legacyError
        : 'IoT API "$sourceName" returned an application-level failure.';

    logDebug(
      '[IOT_SDUI][API_FAILURE] '
      'source=$sourceName '
      'http=2xx '
      'successType=${successValue?.runtimeType ?? '-'} '
      'statusType=${statusValue?.runtimeType ?? '-'} '
      'hasError=${hasErrorPayload ? 'true' : 'false'} '
      'message=${_redact(message)}',
    );

    return message;
  }

  bool? _asOutcomeBool(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;

    final text = value.toString().trim().toLowerCase();
    if (text.isEmpty) return null;

    if (<String>{
      'true',
      '1',
      'yes',
      'ok',
      'success',
      'successful',
      'succeeded',
    }.contains(text)) {
      return true;
    }

    if (<String>{
      'false',
      '0',
      'no',
      'error',
      'failed',
      'failure',
      'invalid',
      'denied',
      'unauthorized',
    }.contains(text)) {
      return false;
    }

    return null;
  }

  void _logDataSourceResult({
    required String sourceName,
    required int statusCode,
    required Map<String, dynamic> contract,
    required dynamic decoded,
  }) {
    final response = _map(contract['response']);
    final root = response?['root']?.toString().trim();
    final rootValue = root == null || root.isEmpty
        ? null
        : _readDynamicPath(decoded, root);
    final rootCount = rootValue is List ? rootValue.length : null;
    final keys = decoded is Map
        ? decoded.keys.map((key) => key.toString()).take(12).join(',')
        : '';

    logDebug(
      '[IOT_SDUI][DATASOURCE][RESULT] '
      'source=$sourceName '
      'http=$statusCode '
      'type=${decoded?.runtimeType ?? '-'} '
      'keys=${keys.isEmpty ? '-' : keys} '
      'root=${root ?? '-'} '
      'rootCount=${rootCount ?? '-'}',
    );
  }

  void _applyResponse(Map<String, dynamic> source, dynamic decoded) {
    final response = _map(source['response']);
    final root = response?['root']?.toString().trim();
    if (root == null || root.isEmpty) return;

    final value = _readDynamicPath(decoded, root);
    if (value is! List) return;

    if (response?['mergeInto']?.toString() == 'devices') {
      _mergeNodeStatus(response!, _mapList(value));
    } else {
      _liveDevices = _mapList(value);
    }
    notifyListeners();
  }

  void _mergeNodeStatus(
    Map<String, dynamic> response,
    List<Map<String, dynamic>> nodes,
  ) {
    final current = _liveDevices;
    if (current == null || current.isEmpty) return;

    final nodeIdField = response['nodeIdField']?.toString().trim() ?? 'node_id';
    final connectivityPath =
        response['connectivityPath']?.toString().trim() ??
        'status.connectivity.connected';
    final devicesPath = response['devicesPath']?.toString().trim() ?? 'devices';
    final deviceIdField = response['deviceIdField']?.toString().trim() ?? 'id';
    final powerField =
        response['devicePowerField']?.toString().trim() ?? 'power';

    final gridSourceId = deviceGrid?['dataSource']?.toString().trim();
    final gridResponse = gridSourceId == null
        ? null
        : _map(_map(dataSources[gridSourceId])?['response']);
    final controlIdField =
        gridResponse?['controlIdField']?.toString().trim() ?? 'node_id';

    final byNode = <String, Map<String, dynamic>>{};
    for (final node in nodes) {
      final id = _readPath(node, nodeIdField)?.toString().trim() ?? '';
      if (id.isNotEmpty) byNode[id] = node;
    }

    _liveDevices = current
        .map((device) {
          final merged = Map<String, dynamic>.from(device);
          final controlId =
              _readPath(device, controlIdField)?.toString().trim() ?? '';
          if (controlId.isEmpty) return merged;

          Map<String, dynamic>? node = byNode[controlId];
          Map<String, dynamic>? child;

          if (node == null) {
            // Some status payloads use a gateway node containing child devices.
            for (final candidate in nodes) {
              final children = _readPath(candidate, devicesPath);
              if (children is! List) continue;
              for (final raw in children) {
                final item = _map(raw);
                if (item == null) continue;
                if (_readPath(item, deviceIdField)?.toString().trim() ==
                    controlId) {
                  node = candidate;
                  child = item;
                  break;
                }
              }
              if (child != null) break;
            }
          } else {
            final children = _readPath(node, devicesPath);
            if (children is List) {
              for (final raw in children) {
                final item = _map(raw);
                if (item != null &&
                    _readPath(item, deviceIdField)?.toString().trim() ==
                        controlId) {
                  child = item;
                  break;
                }
              }
            }
          }

          if (node != null) {
            final connected = _asBool(_readPath(node, connectivityPath));
            if (connected != null) {
              merged['online'] = connected;
              merged['status'] = connected ? 'Online' : 'Offline';
            }
          }
          if (child != null) {
            final power = _asBool(_readPath(child, powerField));
            if (power != null) merged['power'] = power;
          }
          return merged;
        })
        .toList(growable: false);
  }

  void applyLiveNodes(Map<String, dynamic> liveNodes) {
    if (_disposed || liveNodes.isEmpty) return;

    final current = _liveDevices ?? devices;
    if (current.isEmpty) return;

    var modified = false;
    final updated = current.map((device) {
      final merged = Map<String, dynamic>.from(device);
      final nodeId = (device['node_id'] ??
              device['nodeId'] ??
              device['id'] ??
              device['deviceId'])
          ?.toString()
          .trim();

      if (nodeId == null || nodeId.isEmpty) return merged;

      Map<String, dynamic>? nodeData;
      if (liveNodes.containsKey(nodeId)) {
        final raw = liveNodes[nodeId];
        if (raw is Map) nodeData = Map<String, dynamic>.from(raw);
      } else {
        for (final entry in liveNodes.values) {
          if (entry is! Map) continue;
          final entryId = (entry['node_id'] ?? entry['nodeId'] ?? entry['id'])?.toString().trim();
          if (entryId == nodeId) {
            nodeData = Map<String, dynamic>.from(entry);
            break;
          }
          final childDevices = entry['devices'];
          if (childDevices is List) {
            for (final d in childDevices) {
              if (d is Map &&
                  (d['id']?.toString().trim() == nodeId ||
                      d['node_id']?.toString().trim() == nodeId)) {
                nodeData = Map<String, dynamic>.from(entry);
                break;
              }
            }
          }
          if (nodeData != null) break;
        }
      }

      if (nodeData != null) {
        final status = nodeData['status'];
        bool? connected;
        if (status is Map) {
          final conn = status['connectivity'];
          if (conn is Map) {
            connected = _asBool(conn['connected']);
          } else {
            connected = _asBool(status['connected']);
          }
        }
        connected ??= _asBool(nodeData['online']) ?? _asBool(nodeData['connected']);

        if (connected != null) {
          if (merged['online'] != connected ||
              merged['status'] != (connected ? 'Online' : 'Offline')) {
            merged['online'] = connected;
            merged['status'] = connected ? 'Online' : 'Offline';
            modified = true;
          }
        }

        dynamic powerVal = nodeData['power'];
        if (status is Map && status.containsKey('power')) {
          powerVal = status['power'];
        }
        final power = _asBool(powerVal);
        if (power != null && merged['power'] != power) {
          merged['power'] = power;
          modified = true;
        }

        final params = nodeData['params'] ??
            nodeData['parameters'] ??
            (status is Map ? status['parameters'] : null);
        if (params is Map) {
          final existingParams = Map<String, dynamic>.from(
            merged['parameters'] as Map? ?? {},
          );
          for (final e in params.entries) {
            existingParams[e.key.toString()] = e.value;
          }
          merged['parameters'] = existingParams;
          modified = true;
        }
      }

      return merged;
    }).toList(growable: false);

    if (modified || _liveDevices == null) {
      _liveDevices = updated;
      notifyListeners();
    }
  }

  bool _deviceOnline(Map<String, dynamic> device) {
    final nodeId = (device['node_id'] ?? device['nodeId'] ?? device['id'])?.toString();
    if (EfactorCloudService.instance.isNodeLocal(nodeId)) {
      return true;
    }
    return _asBool(device['online']) ??
        device['status']?.toString().trim().toLowerCase() == 'online';
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

  Uri? resolveUrl(String rawUrl) {
    final parsed = Uri.tryParse(rawUrl);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return parsed;
    }

    final base = apiBaseUri;
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      return null;
    }

    return base.resolve(rawUrl);
  }

  bool _dataSourceExecutable(String sourceId, {Map<String, dynamic>? device}) {
    final source = _map(dataSources[sourceId]);
    if (source == null) return false;
    final contract = _effectiveDataSourceContract(source);
    return _urlExecutable(contract['url'], device: device);
  }

  bool _urlExecutable(dynamic raw, {Map<String, dynamic>? device}) {
    final resolved =
        _resolveTemplate(raw, device: device, event: null)?.toString() ?? '';
    if (resolved.isEmpty || RegExp(r'\{\{[^}]+\}\}').hasMatch(resolved)) {
      return false;
    }

    final uri = resolveUrl(resolved);
    return uri != null && !_isLoopback(uri);
  }

  String _normalizeRuntimeAuthorizationHeader(String name, String value) {
    final headerName = name.trim();
    final headerValue = value.trim();
    if (headerName.toLowerCase() != 'authorization' || headerValue.isEmpty) {
      return headerValue;
    }

    // Preserve any schema-provided authorization scheme (Bearer, Basic, etc.).
    // Only add the Efactor mobile Bearer scheme when the resolved header value
    // is the current runtime IoT access token itself. This keeps the behavior
    // generic and prevents changing unrelated/custom Authorization values.
    final firstWhitespace = headerValue.indexOf(RegExp(r'\s'));
    if (firstWhitespace > 0 &&
        headerValue.substring(firstWhitespace).trim().isNotEmpty) {
      return headerValue;
    }

    final runtimeToken = accessToken.trim();
    if (runtimeToken.isNotEmpty && headerValue == runtimeToken) {
      return 'Bearer $headerValue';
    }

    return headerValue;
  }

  bool _isLoopback(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  dynamic _resolveTemplate(
    dynamic value, {
    required Map<String, dynamic>? device,
    required Map<String, dynamic>? event,
  }) {
    if (value is String) {
      final exact = RegExp(r'^\{\{(.+)\}\}$').firstMatch(value.trim());
      if (exact != null) {
        return _resolveExpression(
          exact.group(1)!.trim(),
          device: device,
          event: event,
        );
      }

      return value.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) {
        final resolved = _resolveExpression(
          match.group(1)!.trim(),
          device: device,
          event: event,
        );
        return resolved?.toString() ?? '';
      });
    }

    if (value is List) {
      return value
          .map((item) => _resolveTemplate(item, device: device, event: event))
          .toList();
    }

    if (value is Map) {
      final securePath = value[r'$secureState']?.toString().trim();
      if (securePath != null && securePath.isNotEmpty) {
        // IoT state receives the authenticated token from AuthState. The
        // secure-state binding names the slot; the secret itself never lives
        // in the published schema.
        if (securePath == 'session.iotAccessToken' ||
            securePath == 'session.accessToken') {
          return accessToken;
        }
      }
      return value.map(
        (key, item) => MapEntry(
          key.toString(),
          _resolveTemplate(item, device: device, event: event),
        ),
      );
    }

    return value;
  }

  dynamic _resolveExpression(
    String expression, {
    required Map<String, dynamic>? device,
    required Map<String, dynamic>? event,
  }) {
    final notEqual = expression.indexOf('!=');
    if (notEqual >= 0) {
      final left = expression.substring(0, notEqual).trim();
      final right = expression.substring(notEqual + 2).trim();
      return _resolveAtom(left, device: device, event: event) !=
          _resolveAtom(right, device: device, event: event);
    }

    final equal = expression.indexOf('==');
    if (equal >= 0) {
      final left = expression.substring(0, equal).trim();
      final right = expression.substring(equal + 2).trim();
      return _resolveAtom(left, device: device, event: event) ==
          _resolveAtom(right, device: device, event: event);
    }

    final separator = expression.indexOf('|');
    if (separator >= 0) {
      final primaryExpression = expression.substring(0, separator).trim();
      final modifier = expression.substring(separator + 1).trim();
      final primary = _resolveAtom(
        primaryExpression,
        device: device,
        event: event,
      );

      // Schema conditional mapping syntax: {{value|falseValue:trueValue}}.
      // The current IoT schema uses this for
      // {{toggle_next|off:on}} so the command follows the next boolean state.
      final conditionalSeparator = modifier.indexOf(':');
      if (primary is bool && conditionalSeparator >= 0) {
        final falseExpression = modifier
            .substring(0, conditionalSeparator)
            .trim();
        final trueExpression = modifier
            .substring(conditionalSeparator + 1)
            .trim();
        final selected = primary ? trueExpression : falseExpression;
        final resolvedSelected = _resolveAtom(
          selected,
          device: device,
          event: event,
        );
        return resolvedSelected ?? selected;
      }

      if (primary != null && primary.toString().isNotEmpty) {
        return primary;
      }

      final resolvedFallback = _resolveAtom(
        modifier,
        device: device,
        event: event,
      );
      return resolvedFallback ?? modifier;
    }

    return _resolveAtom(expression, device: device, event: event);
  }

  dynamic _resolveAtom(
    String atom, {
    required Map<String, dynamic>? device,
    required Map<String, dynamic>? event,
  }) {
    final text = atom.trim();
    if (text.isEmpty) return null;

    if (text == 'true') return true;
    if (text == 'false') return false;
    if (text == 'null') return null;

    final number = num.tryParse(text);
    if (number != null) return number;

    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'"))) {
      return text.substring(1, text.length - 1);
    }

    // Interaction-local values may be referenced directly by the server
    // schema (for example {{toggle_next}}) without forcing Flutter to
    // hardcode a device/model-specific value.
    if (event != null && event.containsKey(text)) {
      return event[text];
    }

    return readBinding(text, device: device, event: event);
  }

  dynamic _readPath(Map<String, dynamic>? source, String path) {
    dynamic current = source;
    for (final segment in path.split('.')) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return current;
  }

  dynamic _readDynamicPath(dynamic source, String path) {
    dynamic current = source;
    for (final segment in path.split('.')) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return current;
  }

  bool _isTransientStatusCode(int statusCode) {
    return statusCode >= 500 || statusCode == 408 || statusCode == 429;
  }

  String _datasourceCacheKey(String sourceName) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode('$sourceName|${accessToken.trim()}')) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return 'efactor.iot.datasource.v1.${hash.toRadixString(16)}';
  }

  Future<dynamic> _readDatasourceCache(String sourceName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_datasourceCacheKey(sourceName));
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (error) {
      logDebug('[IOT_SDUI][DATASOURCE] CACHE READ FAILED: $error');
      return null;
    }
  }

  Future<void> _writeDatasourceCache(String sourceName, dynamic decoded) async {
    if (decoded == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_datasourceCacheKey(sourceName), jsonEncode(decoded));
    } catch (error) {
      logDebug('[IOT_SDUI][DATASOURCE] CACHE SAVE FAILED: $error');
    }
  }

  /// Clears persisted IoT datasource caches on logout.
  static Future<void> clearUserCache({String? accessToken}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('efactor.iot.datasource.v1.')) {
          await prefs.remove(key);
        }
      }
      logDebug('[IotSduiState] Cleared IoT datasource cache');
    } catch (error) {
      logDebug('[IotSduiState] Failed to clear IoT datasource cache: $error');
    }
  }

  dynamic _softFail(String message) {
    // Secondary enrichment/status sources must not replace a usable IoT page
    // with a page-level error. Keep the last good device data and log the
    // backend failure for diagnostics.
    logDebug('[IOT_SDUI][SECONDARY_SOURCE] ${_redact(message)}');
    return null;
  }

  dynamic _fail(String message) {
    _lastError = _redact(message);
    notifyListeners();
    return null;
  }

  String _redact(String text) {
    var safe = text.replaceAllMapped(
      RegExp(
        r'([?&][^=&\s]*(?:token|key|secret|password|credential)[^=]*=)[^&\s]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}<redacted>',
    );
    safe = safe.replaceAllMapped(
      RegExp(
        r'("(?:access_token|refresh_token|id_token|apiKey|api_key|password|secret|credential)"\s*:\s*")[^"]*(")',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}<redacted>${match.group(2)}',
    );
    safe = safe.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._~+\-/=]+', caseSensitive: false),
      (match) => '${match.group(1)}<redacted>',
    );
    return safe;
  }

  List<Map<String, dynamic>> _mapList(List<dynamic> value) {
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<dynamic, dynamic>()))
        .toList(growable: false);
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      super.notifyListeners();
    });
  }

  @override
  void dispose() {
    EfactorCloudService.instance.localDevices.removeListener(_onLocalDevicesChanged);
    EfactorCloudService.instance.liveNodes.removeListener(_onLiveNodesChanged);
    _disposed = true;
    _inFlightSources.clear();
    _client.close();
    super.dispose();
  }
}

class _SharedGetResult {
  _SharedGetResult(this.value) : at = DateTime.now();

  final dynamic value;
  final DateTime at;
}
