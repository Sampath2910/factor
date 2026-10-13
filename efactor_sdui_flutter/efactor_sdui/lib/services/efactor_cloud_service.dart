import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'package:flutter/foundation.dart';

import '../wifi_sdui/wifi_native_service.dart';
import 'schema_invalidation_event.dart';

enum EfactorCloudUiStatus { idle, connected, error }

/// Single Flutter owner of the Efactor cloud session.
///
/// Mirrors the full capabilities of the native Cloud WebSocket:
/// - Connects to the cloud socket with the authenticated access token.
/// - Streams raw events (`cloudEvents`) and decoded JSON payloads (`cloudMessages`).
/// - Auto-queries node statuses (`getAllNodesStatus`) upon connection.
/// - Caches and updates live node status in `liveNodes`.
/// - Dispatches schema invalidation events without dropping non-schema messages.
class EfactorCloudService {
  EfactorCloudService._();

  static final EfactorCloudService instance = EfactorCloudService._();

  final EfactorCloud _cloud = EfactorCloud.instance;

  final StreamController<SchemaInvalidationEvent> _schemaInvalidations =
      StreamController<SchemaInvalidationEvent>.broadcast(sync: true);
  final StreamController<bool> _connectionChanges =
      StreamController<bool>.broadcast(sync: true);
  final StreamController<EfCloudEvent> _cloudEventsController =
      StreamController<EfCloudEvent>.broadcast(sync: true);
  final StreamController<String> _rawMessagesController =
      StreamController<String>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _cloudMessagesController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _nodeStatusUpdatesController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  StreamSubscription<EfCloudEvent>? _subscription;
  StreamSubscription<EfDiscoveryEvent>? _discoverySubscription;

  bool _libraryInitialized = false;
  bool _cloudConnected = false;
  bool _discoveryStarted = false;
  bool _logsConfigured = false;
  String? _sessionUsername;
  String? _activeAccessToken;
  final Set<String> _discoveredNodeIds = <String>{};
  final Map<String, EfLocalDevice> _localDevices = <String, EfLocalDevice>{};

  final ValueNotifier<EfactorCloudUiStatus> uiStatus =
      ValueNotifier<EfactorCloudUiStatus>(EfactorCloudUiStatus.idle);
  final ValueNotifier<String> cloudStatusText =
      ValueNotifier<String>('idle');
  final ValueNotifier<List<String>> discoveredNodeIds =
      ValueNotifier<List<String>>(const <String>[]);
  final ValueNotifier<Map<String, EfLocalDevice>> localDevices =
      ValueNotifier<Map<String, EfLocalDevice>>(const <String, EfLocalDevice>{});
  final ValueNotifier<Map<String, dynamic>> liveNodes =
      ValueNotifier<Map<String, dynamic>>(const <String, dynamic>{});

  /// Returns true if the device is currently detected directly on the local LAN.
  bool isNodeLocal(String? nodeId) {
    if (nodeId == null || nodeId.trim().isEmpty) return false;
    final clean = nodeId.trim();
    return _localDevices.containsKey(clean) ||
        localDevices.value.containsKey(clean);
  }

  /// Returns the local device info (including IP and port) if present on local LAN.
  EfLocalDevice? getLocalDevice(String? nodeId) {
    if (nodeId == null || nodeId.trim().isEmpty) return null;
    final clean = nodeId.trim();
    return _localDevices[clean] ?? localDevices.value[clean];
  }

  /// Registers or unregisters a local device (from mDNS, probe, or testing).
  void setLocalDevice(EfLocalDevice device, {bool found = true}) {
    final clean = device.nodeId.trim();
    if (clean.isEmpty) return;
    if (found) {
      _discoveredNodeIds.add(clean);
      _localDevices[clean] = device;
    } else {
      _discoveredNodeIds.remove(clean);
      _localDevices.remove(clean);
    }
    _publishDiscovered();
  }

  /// Clears all discovered local devices.
  void clearLocalDevices() {
    _discoveredNodeIds.clear();
    _localDevices.clear();
    _publishDiscovered();
  }

  /// Actively probes a local device via TCP socket to verify if it is reachable right now.
  /// If reachable, returns true.
  /// If unreachable (timeout or connection refused), removes stale entry from
  /// [_localDevices], publishes update, and returns false.
  Future<bool> probeLocalDevice(
    String? nodeId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final cleanNodeId = nodeId?.trim() ?? '';
    if (cleanNodeId.isEmpty) return false;

    final device = _localDevices[cleanNodeId];
    if (device == null || device.ip.trim().isEmpty || device.port <= 0) {
      return false;
    }

    try {
      final socket = await Socket.connect(
        device.ip.trim(),
        device.port,
        timeout: timeout,
      );
      socket.destroy();
      debugPrint(
        '[EfactorCloud] PROBE_LOCAL_DEVICE_SUCCESS nodeId=$cleanNodeId '
        'ip=${device.ip}:${device.port}',
      );
      return true;
    } catch (error) {
      debugPrint(
        '[EfactorCloud] PROBE_LOCAL_DEVICE_FAILED nodeId=$cleanNodeId '
        'ip=${device.ip}:${device.port} error=$error',
      );
      // Remove stale entry since device did not respond
      _discoveredNodeIds.remove(cleanNodeId);
      _localDevices.remove(cleanNodeId);
      _publishDiscovered();
      return false;
    }
  }

  bool get libraryInitialized => _libraryInitialized;
  bool get cloudConnected => _cloudConnected;
  bool get discoveryStarted => _discoveryStarted;
  String? get sessionUsername => _sessionUsername;
  String? get activeAccessToken => _activeAccessToken;

  Stream<SchemaInvalidationEvent> get schemaInvalidations =>
      _schemaInvalidations.stream;
  Stream<bool> get connectionChanges => _connectionChanges.stream;
  Stream<EfCloudEvent> get cloudEvents => _cloudEventsController.stream;
  Stream<String> get rawMessages => _rawMessagesController.stream;
  Stream<Map<String, dynamic>> get cloudMessages =>
      _cloudMessagesController.stream;
  Stream<Map<String, dynamic>> get nodeStatusUpdates =>
      _nodeStatusUpdatesController.stream;

  Future<void> initialize({
    required String accessToken,
    String? username,
  }) async {
    final token = accessToken.trim();
    final identity = username?.trim() ?? '';

    if (token.isEmpty) {
      _libraryInitialized = false;
      _setCloudConnected(false);
      _sessionUsername = null;
      _activeAccessToken = null;
      debugPrint('[EfactorCloud] INITIALIZATION_SKIPPED: access token missing');
      return;
    }

    _activeAccessToken = token;
    _sessionUsername = identity.isEmpty ? null : identity;
    configureLogs();
    await _ensureEventSubscription();

    try {
      final version = await EfactorProvisioning.instance.libVersion();
      _libraryInitialized = version != null && version.trim().isNotEmpty;

      debugPrint(
        '[EfactorCloud] LIBRARY_INITIALIZED=$_libraryInitialized '
        'version=${version ?? "unknown"}',
      );

      await _cloud.initialize(apiKey: token);
    } catch (error, stackTrace) {
      _libraryInitialized = false;
      _setCloudConnected(false, error: true);
      debugPrint('[EfactorCloud] LIBRARY_INITIALIZATION_FAILED $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    // Local mDNS is independent of the cloud socket. Start it so sendData can
    // prefer LAN routing when the node is on the same network.
    await ensureDiscoveryStarted();
  }

  /// Plugin logs go to debug output and are forwarded to any active log sinks.
  void configureLogs() {
    if (_logsConfigured) return;
    _logsConfigured = true;
    EfactorProvisioning.logLevel = EfLogLevel.debug;
    EfactorProvisioning.onLog = (record) {
      // ignore: avoid_print
      print('[EfLog][${record.tag}] ${record.message}');
    };
  }

  Future<void> _ensureEventSubscription() async {
    if (_subscription != null) return;

    _subscription = _cloud.events.listen(
      (event) {
        if (!_cloudEventsController.isClosed) {
          _cloudEventsController.add(event);
        }

        switch (event.type) {
          case EfCloudEventType.connected:
            _setCloudConnected(true);
            cloudStatusText.value = 'connected';
            // ignore: avoid_print
            print('[EfactorCloud] CLOUD_EVENT=connected (WebSocket open)');
            // Automatically query node statuses immediately upon connection,
            // matching the behavior in efactor_aar_test.
            unawaited(_autoQueryOnConnect());
            return;
          case EfCloudEventType.disconnected:
            _setCloudConnected(false);
            cloudStatusText.value = 'disconnected';
            // ignore: avoid_print
            print('[EfactorCloud] CLOUD_EVENT=disconnected');
            return;
          case EfCloudEventType.error:
            _setCloudConnected(false, error: true);
            cloudStatusText.value = 'error: ${event.message ?? ""}';
            // ignore: avoid_print
            print('[EfactorCloud] CLOUD_EVENT=error: ${event.message ?? ""}');
            return;
          case EfCloudEventType.message:
            _handleCloudMessage(event.message);
            return;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _setCloudConnected(false, error: true);
        cloudStatusText.value = 'error: $error';
        // ignore: avoid_print
        print('[EfactorCloud] CLOUD_STREAM_ERROR=$error');
      },
    );
  }

  Future<void> _autoQueryOnConnect() async {
    final token = _activeAccessToken;
    if (token == null || token.isEmpty) return;

    try {
      debugPrint('[EfactorCloud] Auto-querying all nodes status upon connection...');
      await _cloud.getAllNodesStatus(apiKey: token);
    } catch (e) {
      debugPrint('[EfactorCloud] Auto getAllNodesStatus failed: $e');
    }
  }

  void _setCloudConnected(bool value, {bool error = false}) {
    if (error) {
      uiStatus.value = EfactorCloudUiStatus.error;
    } else {
      uiStatus.value =
          value ? EfactorCloudUiStatus.connected : EfactorCloudUiStatus.idle;
    }
    if (_cloudConnected == value) return;
    _cloudConnected = value;
    if (!_connectionChanges.isClosed) {
      _connectionChanges.add(value);
    }
  }

  Future<void> ensureDiscoveryStarted() async {
    // On iOS 14+, prime Local Network permission so Bonjour mDNS and socket packets are permitted.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(WifiNativeService.instance.primeLocalNetworkAccess().catchError((_) {}));
    }

    // mDNS local discovery is required on both Android and iOS so sendData
    // can prefer LAN routing when the node is on the same network.
    await _ensureDiscoverySubscription();
    if (_discoveryStarted) return;

    try {
      await EfactorDiscovery.instance.start();
      _discoveryStarted = true;
      debugPrint('[EfactorCloud] DISCOVERY_STARTED');
      final known = await EfactorDiscovery.instance.getDevices();
      var changed = false;
      for (final device in known) {
        final nodeId = device.nodeId.trim();
        if (nodeId.isEmpty) continue;
        _discoveredNodeIds.add(nodeId);
        _localDevices[nodeId] = device;
        changed = true;
      }
      if (changed) _publishDiscovered();
    } catch (error) {
      debugPrint('[EfactorCloud] DISCOVERY_START_FAILED $error');
    }
  }

  Future<void> stopDiscovery() async {
    if (!_discoveryStarted && _discoveredNodeIds.isEmpty && _localDevices.isEmpty) return;
    try {
      await EfactorDiscovery.instance.stop();
    } catch (error) {
      debugPrint('[EfactorCloud] DISCOVERY_STOP_FAILED $error');
    } finally {
      _discoveryStarted = false;
      _discoveredNodeIds.clear();
      _localDevices.clear();
      _publishDiscovered();
    }
  }

  Future<void> _ensureDiscoverySubscription() async {
    if (_discoverySubscription != null) return;

    _discoverySubscription = EfactorDiscovery.instance.events.listen(
      (event) {
        final nodeId = event.nodeId.trim();
        if (nodeId.isEmpty) return;
        if (event.found) {
          _discoveredNodeIds.add(nodeId);
          _localDevices[nodeId] = EfLocalDevice(
            nodeId: nodeId,
            ip: event.ip ?? '',
            port: event.port ?? 0,
          );
        } else {
          _discoveredNodeIds.remove(nodeId);
          _localDevices.remove(nodeId);
        }
        _publishDiscovered();
        debugPrint(
          '[EfactorCloud] DISCOVERY_${event.found ? "FOUND" : "LOST"} '
          'nodeId=$nodeId ip=${event.ip ?? "-"} port=${event.port ?? 0}',
        );
      },
      onError: (Object error) {
        debugPrint('[EfactorCloud] DISCOVERY_STREAM_ERROR=$error');
      },
    );
  }

  void _publishDiscovered() {
    discoveredNodeIds.value = List<String>.unmodifiable(_discoveredNodeIds);
    localDevices.value = Map<String, EfLocalDevice>.unmodifiable(_localDevices);
  }

  void _handleCloudMessage(String? rawMessage) {
    final raw = rawMessage?.trim();
    if (raw == null || raw.isEmpty) return;

    // ignore: avoid_print
    print('[EfactorCloud][WS_RECV] $raw');

    if (!_rawMessagesController.isClosed) {
      _rawMessagesController.add(raw);
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      final jsonStart = raw.indexOf('{');
      if (jsonStart >= 0) {
        try {
          decoded = jsonDecode(raw.substring(jsonStart));
        } catch (_) {
          return;
        }
      } else {
        return;
      }
    }

    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);

      if (!_cloudMessagesController.isClosed) {
        _cloudMessagesController.add(map);
      }

      // Check for node/device data update
      _updateLiveNodeData(map);

      // Check for schema invalidation
      final invalidation = SchemaInvalidationEvent.tryParse(map);
      if (invalidation != null) {
        if (!_schemaInvalidations.isClosed) {
          _schemaInvalidations.add(invalidation);
        }
        debugPrint(
          '[EfactorCloud][SCHEMA_CHANGED] '
          'scope=${invalidation.scope ?? '-'} '
          'schemaId=${invalidation.schemaId} '
          'revision=${invalidation.revision ?? '-'}',
        );
      }
    } else if (decoded is List) {
      // Some server responses return a JSON array of nodes
      for (final item in decoded) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          if (!_cloudMessagesController.isClosed) {
            _cloudMessagesController.add(map);
          }
          _updateLiveNodeData(map);
        }
      }
    }
  }

  void _updateLiveNodeData(Map<String, dynamic> data) {
    final current = Map<String, dynamic>.from(liveNodes.value);
    var updated = false;

    // Direct node structure: {config: {node_id: ...}, status: ...}
    final configRaw = data['config'];
    if (configRaw is Map) {
      final config = Map<String, dynamic>.from(configRaw);
      final nodeId = (config['node_id'] ?? config['nodeId'])?.toString().trim();
      if (nodeId != null && nodeId.isNotEmpty) {
        current[nodeId] = data;
        updated = true;
      }
    }

    // Flat structure: {node_id: ..., status: ...}
    final directNodeId = (data['node_id'] ?? data['nodeId'] ?? data['id'])?.toString().trim();
    if (directNodeId != null && directNodeId.isNotEmpty) {
      current[directNodeId] = data;
      updated = true;
    }

    // Sibling nodes dictionary: {nodes: [{...}, {...}]} or {all_nodes: [{...}, {...}]}
    final nodesList = data['nodes'] ?? data['all_nodes'] ?? data['node_details'];
    if (nodesList is List) {
      for (final item in nodesList) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final id = (m['node_id'] ?? m['nodeId'] ?? m['id'])?.toString().trim();
          if (id != null && id.isNotEmpty) {
            current[id] = m;
            updated = true;
          }
        }
      }
    }

    if (updated) {
      liveNodes.value = Map<String, dynamic>.unmodifiable(current);
      if (!_nodeStatusUpdatesController.isClosed) {
        _nodeStatusUpdatesController.add(data);
      }
      debugPrint(
        '[EfactorCloud][NODES_UPDATED] total known nodes: ${current.length}',
      );
    }
  }

  /// Send getAllNodesStatus over Cloud WebSocket.
  Future<void> getAllNodesStatus({String? apiKey}) async {
    final key = apiKey?.trim() ?? _activeAccessToken?.trim() ?? '';
    if (key.isEmpty) {
      debugPrint('[EfactorCloud] getAllNodesStatus skipped: token missing');
      return;
    }
    debugPrint('[EfactorCloud] getAllNodesStatus() sending...');
    await _cloud.getAllNodesStatus(apiKey: key);
  }

  /// Send getAllNodes over Cloud WebSocket.
  Future<void> getAllNodes({String? apiKey, String? nodeId}) async {
    final key = apiKey?.trim() ?? _activeAccessToken?.trim() ?? '';
    if (key.isEmpty) {
      debugPrint('[EfactorCloud] getAllNodes skipped: token missing');
      return;
    }
    debugPrint('[EfactorCloud] getAllNodes(node=$nodeId) sending...');
    await _cloud.getAllNodes(apiKey: key, nodeId: nodeId);
  }

  /// Send getDevices over Cloud WebSocket.
  Future<void> getDevices({String? apiKey, String? nodeId}) async {
    final key = apiKey?.trim() ?? _activeAccessToken?.trim() ?? '';
    if (key.isEmpty) {
      debugPrint('[EfactorCloud] getDevices skipped: token missing');
      return;
    }
    debugPrint('[EfactorCloud] getDevices(node=$nodeId) sending...');
    await _cloud.getDevices(apiKey: key, nodeId: nodeId);
  }

  /// Reconnect the Cloud WebSocket.
  Future<void> reconnect() async {
    debugPrint('[EfactorCloud] reconnect() requested');
    await _cloud.reconnect();
  }

  Future<bool> refreshLibraryStatus() async {
    try {
      final version = await EfactorProvisioning.instance.libVersion();
      _libraryInitialized = version != null && version.trim().isNotEmpty;
    } catch (_) {
      _libraryInitialized = false;
    }
    return _libraryInitialized;
  }

  Future<bool> refreshCloudStatus() async => _cloudConnected;

  Future<void> disconnect() async {
    await stopDiscovery();
    try {
      await _cloud.disconnect();
    } catch (error) {
      debugPrint('[EfactorCloud] CLOUD_DISCONNECT_FAILED $error');
    } finally {
      _setCloudConnected(false);
      cloudStatusText.value = 'disconnected';
      _sessionUsername = null;
      _activeAccessToken = null;
      liveNodes.value = const <String, dynamic>{};
      discoveredNodeIds.value = const <String>[];
    }
  }

  /// Pause mDNS discovery while SoftAP provisioning runs.
  ///
  /// Does **not** disconnect the cloud WebSocket before `EfactorProvision.start`:
  /// the library must still call getcrds over Cloud HTTP (with cellular
  /// fallback) while the phone is on home Wi‑Fi. Disconnect the socket only
  /// after SoftAP join if needed via [disconnectCloudSocketOnly].
  Future<void> pauseForProvisioning({bool disconnectCloud = false}) async {
    debugPrint(
      '[EfactorCloud] pauseForProvisioning(disconnectCloud=$disconnectCloud)',
    );
    await stopDiscovery();
    try {
      await _cloud.setProvisionStarted(true);
    } catch (error) {
      debugPrint('[EfactorCloud] setProvisionStarted(true) failed: $error');
    }
    if (!disconnectCloud) {
      cloudStatusText.value = 'provisioning';
      return;
    }
    try {
      await _cloud.disconnect();
    } catch (error) {
      debugPrint('[EfactorCloud] CLOUD_DISCONNECT_FAILED $error');
    } finally {
      _setCloudConnected(false);
      cloudStatusText.value = 'provisioning';
    }
  }

  /// Drop the live WebSocket only (keep token). Call after SoftAP join so the
  /// socket does not thrash on a no-internet SoftAP.
  Future<void> disconnectCloudSocketOnly() async {
    try {
      await _cloud.disconnect();
    } catch (error) {
      debugPrint('[EfactorCloud] CLOUD_DISCONNECT_FAILED $error');
    } finally {
      _setCloudConnected(false);
      cloudStatusText.value = 'provisioning';
    }
  }

  /// Restore cloud + discovery after SoftAP provisioning finishes or fails.
  Future<void> resumeAfterProvisioning() async {
    final token = _activeAccessToken?.trim() ?? '';
    if (token.isEmpty) {
      debugPrint('[EfactorCloud] resumeAfterProvisioning skipped: no token');
      return;
    }
    debugPrint('[EfactorCloud] resumeAfterProvisioning()');
    try {
      await _cloud.setProvisionStarted(false);
    } catch (_) {}
    await initialize(
      accessToken: token,
      username: _sessionUsername,
    );
    await ensureDiscoveryStarted();
  }
}
