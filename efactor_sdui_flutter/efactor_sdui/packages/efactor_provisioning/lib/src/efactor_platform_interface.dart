import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'efactor_cloud_models.dart';
import 'efactor_discovery_models.dart';
import 'efactor_provisioning_models.dart';
import 'efactor_data_models.dart';
import 'efactor_models.dart';
import 'method_channel_efactor.dart';

/// The contract that any platform implementation must satisfy.
///
/// Using `plugin_platform_interface` (the federated-plugin pattern) keeps the
/// public API decoupled from the transport, so later you could add e.g. a
/// mock implementation for widget tests, or split iOS/Android into separate
/// packages, without touching app code.
abstract class EfactorPlatform extends PlatformInterface {
  EfactorPlatform() : super(token: _token);

  static final Object _token = Object();

  static EfactorPlatform _instance = MethodChannelEfactor();
  static EfactorPlatform get instance => _instance;

  static set instance(EfactorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> platformVersion() =>
      throw UnimplementedError('platformVersion() not implemented.');

  Future<String?> libVersion() =>
      throw UnimplementedError('libVersion() not implemented.');

  Future<void> connect({
    required String deviceName,
    required EfTransport transport,
    required EfSecurity security,
    String? pop,
    String? username,
  }) =>
      throw UnimplementedError('connect() not implemented.');

  Future<List<EfWifiNetwork>> scanNetworks() =>
      throw UnimplementedError('scanNetworks() not implemented.');

  Future<void> provision({
    required String ssid,
    required String passphrase,
  }) =>
      throw UnimplementedError('provision() not implemented.');

  Future<EfCustomResponse> sendCustomData({
    required String endpoint,
    required Uint8List payload,
  }) =>
      throw UnimplementedError('sendCustomData() not implemented.');

  Future<void> disconnect() =>
      throw UnimplementedError('disconnect() not implemented.');

  /// Stream of state changes emitted from native during a flow.
  Stream<EfProvState> get stateStream =>
      throw UnimplementedError('stateStream not implemented.');

  // ---- Cloud WebSocket ----

  Future<void> cloudInitialize({required String apiKey}) =>
      throw UnimplementedError('cloudInitialize() not implemented.');

  Future<void> cloudGetDevices({required String apiKey, String? nodeId}) =>
      throw UnimplementedError('cloudGetDevices() not implemented.');

  Future<void> cloudGetAllNodes({required String apiKey, String? nodeId}) =>
      throw UnimplementedError('cloudGetAllNodes() not implemented.');

  Future<void> cloudGetAllNodesStatus({required String apiKey}) =>
      throw UnimplementedError('cloudGetAllNodesStatus() not implemented.');

  Future<void> cloudSetProvisionStarted({required bool status}) =>
      throw UnimplementedError('cloudSetProvisionStarted() not implemented.');

  Future<void> cloudReconnect() =>
      throw UnimplementedError('cloudReconnect() not implemented.');

  Future<void> cloudDisconnect() =>
      throw UnimplementedError('cloudDisconnect() not implemented.');

  /// Stream of cloud events (connected/message/disconnected/error).
  Stream<EfCloudEvent> get cloudEvents =>
      throw UnimplementedError('cloudEvents not implemented.');

  // ---- mDNS discovery ----

  Future<void> discoveryStart() =>
      throw UnimplementedError('discoveryStart() not implemented.');

  Future<void> discoveryStop() =>
      throw UnimplementedError('discoveryStop() not implemented.');

  Future<List<EfLocalDevice>> discoveryGetDevices() =>
      throw UnimplementedError('discoveryGetDevices() not implemented.');

  Stream<EfDiscoveryEvent> get discoveryEvents =>
      throw UnimplementedError('discoveryEvents not implemented.');

  // ---- Provisioning ----

  Future<void> provStart({required String pop, required String apiKey, required String ssid, required String password,required String userName, String security = 'SEC1'}) =>
      throw UnimplementedError('provStart() not implemented.');

  Future<void> provCancel() =>
      throw UnimplementedError('provCancel() not implemented.');

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
  }) =>
      throw UnimplementedError('sendData() not implemented.');

  Stream<EfProvisioningEvent> get provisioningEvents =>
      throw UnimplementedError('provisioningEvents not implemented.');
}
