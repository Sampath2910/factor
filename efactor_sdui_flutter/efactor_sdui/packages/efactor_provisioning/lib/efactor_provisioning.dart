library efactor_provisioning;

import 'dart:typed_data';

import 'src/efactor_cloud_models.dart';
import 'src/efactor_discovery_models.dart';
import 'src/efactor_provisioning_models.dart';
import 'src/efactor_data_models.dart';
import 'src/efactor_logger.dart';
import 'src/efactor_models.dart';
import 'src/efactor_platform_interface.dart';

// Re-export the public surface so app code needs a single import.
export 'src/efactor_logger.dart' show EfLog, EfLogLevel, EfLogRecord;
export 'src/efactor_models.dart';
export 'src/efactor_cloud_models.dart';
export 'src/efactor_discovery_models.dart';
export 'src/efactor_provisioning_models.dart';
export 'src/efactor_data_models.dart';

/// The one library your app talks to. Identical API on Android and iOS.
///
/// Typical flow:
/// ```dart
/// EfactorProvisioning.logLevel = EfLogLevel.debug;
/// EfactorProvisioning.instance.stateStream.listen(print);
///
/// await EfactorProvisioning.instance.connect(
///   deviceName: 'PROV_1234',
///   security: EfSecurity.sec1,
///   pop: 'abcd1234',
/// );
/// final nets = await EfactorProvisioning.instance.scanNetworks();
/// await EfactorProvisioning.instance.provision(
///   ssid: 'home', passphrase: 'secret',
/// );
/// final resp = await EfactorProvisioning.instance.sendCustomData(
///   endpoint: 'efactor-custom', payload: myProtoBytes,
/// );
/// ```
class EfactorProvisioning {
  EfactorProvisioning._();

  static final EfactorProvisioning instance = EfactorProvisioning._();

  static const String _tag = 'API';

  EfactorPlatform get _platform => EfactorPlatform.instance;

  /// Convenience passthrough to control plugin-wide log verbosity.
  static set logLevel(EfLogLevel level) => EfLog.level = level;
  static EfLogLevel get logLevel => EfLog.level;

  /// Attach a sink to receive every log record (e.g. an on-screen console).
  static set onLog(void Function(EfLogRecord)? sink) => EfLog.onRecord = sink;

  /// State changes emitted during a flow (native + Dart driven).
  Stream<EfProvState> get stateStream => _platform.stateStream;

  Future<String?> platformVersion() {
    EfLog.i(_tag, 'platformVersion()');
    return _platform.platformVersion();
  }

  /// Native library version (mirrors the Android LIB_VERSION build flag).
  Future<String?> libVersion() {
    EfLog.i(_tag, 'libVersion()');
    return _platform.libVersion();
  }

  /// Connect to the device's SoftAP and establish a secured session.
  Future<void> connect({
    required String deviceName,
    EfTransport transport = EfTransport.softap,
    EfSecurity security = EfSecurity.sec1,
    String? pop,
    String? username,
  }) {
    EfLog.i(_tag, 'connect(device=$deviceName, sec=${security.name})');
    return _platform.connect(
      deviceName: deviceName,
      transport: transport,
      security: security,
      pop: pop,
      username: username,
    );
  }

  /// Ask the device to scan for nearby Wi-Fi networks.
  Future<List<EfWifiNetwork>> scanNetworks() {
    EfLog.i(_tag, 'scanNetworks()');
    return _platform.scanNetworks();
  }

  /// Send Wi-Fi credentials to the device and apply them.
  Future<void> provision({
    required String ssid,
    required String passphrase,
  }) {
    EfLog.i(_tag, 'provision(ssid=$ssid)');
    return _platform.provision(ssid: ssid, passphrase: passphrase);
  }

  /// Your efactorprotov2 custom layer: send raw protobuf bytes to a custom
  /// endpoint on the device and get the raw response bytes back.
  Future<EfCustomResponse> sendCustomData({
    required String endpoint,
    required Uint8List payload,
  }) {
    EfLog.i(_tag, 'sendCustomData(endpoint=$endpoint, ${payload.length}B)');
    return _platform.sendCustomData(endpoint: endpoint, payload: payload);
  }

  /// Tear down the session / disconnect from the SoftAP.
  Future<void> disconnect() {
    EfLog.i(_tag, 'disconnect()');
    return _platform.disconnect();
  }
}

/// Cloud WebSocket API. Mirrors EfactorLibraryManager's cloud path.
///
/// Typical flow:
/// ```dart
/// EfactorCloud.instance.events.listen(print);
/// await EfactorCloud.instance.initialize(apiKey: myKey);   // connects socket
/// await EfactorCloud.instance.getAllNodes(apiKey: myKey);  // request
/// // responses arrive as EfCloudEvent(message) on the events stream
/// await EfactorCloud.instance.disconnect();
/// ```
class EfactorCloud {
  EfactorCloud._();

  static final EfactorCloud instance = EfactorCloud._();

  static const String _tag = 'CloudAPI';

  EfactorPlatform get _platform => EfactorPlatform.instance;

  /// Stream of cloud events: connected, message, disconnected, error.
  Stream<EfCloudEvent> get events => _platform.cloudEvents;

  /// Connect the WebSocket and set the access token. Call once at startup.
  Future<void> initialize({required String apiKey}) {
    EfLog.i(_tag, 'initialize()');
    return _platform.cloudInitialize(apiKey: apiKey);
  }

  Future<void> getDevices({required String apiKey, String? nodeId}) {
    EfLog.i(_tag, 'getDevices(node=$nodeId)');
    return _platform.cloudGetDevices(apiKey: apiKey, nodeId: nodeId);
  }

  Future<void> getAllNodes({required String apiKey, String? nodeId}) {
    EfLog.i(_tag, 'getAllNodes(node=$nodeId)');
    return _platform.cloudGetAllNodes(apiKey: apiKey, nodeId: nodeId);
  }

  Future<void> getAllNodesStatus({required String apiKey}) {
    EfLog.i(_tag, 'getAllNodesStatus()');
    return _platform.cloudGetAllNodesStatus(apiKey: apiKey);
  }

  /// Widen the reconnect delay while provisioning is in progress.
  Future<void> setProvisionStarted(bool status) {
    EfLog.i(_tag, 'setProvisionStarted($status)');
    return _platform.cloudSetProvisionStarted(status: status);
  }

  Future<void> reconnect() {
    EfLog.i(_tag, 'reconnect()');
    return _platform.cloudReconnect();
  }

  Future<void> disconnect() {
    EfLog.i(_tag, 'disconnect()');
    return _platform.cloudDisconnect();
  }
}

/// mDNS local-network discovery API. Wraps the native mDNSManager.
///
/// ```dart
/// EfactorDiscovery.instance.events.listen((e) => print(e));
/// await EfactorDiscovery.instance.start();
/// // ... devices arrive on the events stream ...
/// final known = await EfactorDiscovery.instance.getDevices();
/// await EfactorDiscovery.instance.stop();
/// ```
class EfactorDiscovery {
  EfactorDiscovery._();

  static final EfactorDiscovery instance = EfactorDiscovery._();

  static const String _tag = 'DiscoveryAPI';

  EfactorPlatform get _platform => EfactorPlatform.instance;

  /// Stream of found/lost events as devices appear and disappear.
  Stream<EfDiscoveryEvent> get events => _platform.discoveryEvents;

  /// Begin mDNS discovery on the local network.
  Future<void> start() {
    EfLog.i(_tag, 'start()');
    return _platform.discoveryStart();
  }

  /// Stop discovery.
  Future<void> stop() {
    EfLog.i(_tag, 'stop()');
    return _platform.discoveryStop();
  }

  /// Snapshot of currently-known devices.
  Future<List<EfLocalDevice>> getDevices() {
    EfLog.i(_tag, 'getDevices()');
    return _platform.discoveryGetDevices();
  }
}


/// Wi-Fi provisioning API — single-call automatic chain.
///
/// ```dart
/// EfactorProvision.instance.events.listen(print);
/// await EfactorProvision.instance.start(
///   pop: 'abcd1234', apiKey: token, ssid: 'HomeWifi', password: 'pass');
/// // progress + success/failure arrive on events
/// ```
class EfactorProvision {
  EfactorProvision._();
  static final EfactorProvision instance = EfactorProvision._();
  static const String _tag = 'ProvisionAPI';

  EfactorPlatform get _platform => EfactorPlatform.instance;

  /// Stream of provisioning events (connection, scanResult, provision progress).
  Stream<EfProvisioningEvent> get events => _platform.provisioningEvents;

  /// Start the full provisioning chain in one call. Provide everything upfront;
  /// the native side runs create → connect(getcrds) → provision automatically,
  /// streaming progress on [events].
  ///
  /// Precondition: the phone must already be joined to the device's SoftAP
  /// (EWIFI_xxxx) Wi-Fi network.
  Future<void> start({
    required String pop,
    required String apiKey,
    required String ssid,
    required String password,
    required String userName,
    String security = 'SEC1',
  }) {
    EfLog.i(_tag, 'start(ssid=$ssid, sec=$security)');
    return _platform.provStart(pop: pop, apiKey: apiKey, ssid: ssid, password: password, userName: userName, security: security);
  }

  /// Cancel / tear down an in-progress provisioning.
  Future<void> cancel() {
    EfLog.i(_tag, 'cancel()');
    return _platform.provCancel();
  }
}



/// Sends data to a device — LOCALLY if the node is discovered on the LAN,
/// otherwise via the CLOUD (with automatic local→cloud fallback).
///
/// The app supplies the FINAL payload as [data]; the lib only routes + sends
/// and returns the raw response.
///
/// ```dart
/// final res = await EfactorData.instance.sendData(
///   apiKey: token, nodeId: id, deviceId: id,
///   pageName: 'page1', paramName: 'temp', value: 23.5,
///   data: 'A1B2C3', latitude: '17.38', longitude: '78.48',
/// );
/// if (res.ok) { /* use res.raw */ }
/// ```
class EfactorData {
  EfactorData._();
  static final EfactorData instance = EfactorData._();
  static const String _tag = 'DataAPI';

  EfactorPlatform get _platform => EfactorPlatform.instance;

  Future<EfSendDataResult> sendData({
    required String apiKey,
    required String nodeId,
    required String deviceId,
    required String pageName,
    required String paramName,
    required double value,
    required String data,
    required String latitude,
    required String longitude,
  }) {
    EfLog.i(_tag, 'sendData(node=$nodeId, page=$pageName, param=$paramName)');
    return _platform.sendData(
      apiKey: apiKey,
      nodeId: nodeId,
      deviceId: deviceId,
      pageName: pageName,
      paramName: paramName,
      value: value,
      data: data,
      latitude: latitude,
      longitude: longitude,
    );
  }
}
