import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'efactor_cloud_models.dart';
import 'efactor_discovery_models.dart';
import 'efactor_provisioning_models.dart';
import 'efactor_data_models.dart';
import 'efactor_logger.dart';
import 'efactor_models.dart';
import 'efactor_platform_interface.dart';

/// Default implementation that talks to native over a [MethodChannel], and
/// receives native-side state + log events over [EventChannel]s.
///
/// Every call is logged on the way out and on the way back, so during testing
/// you can see the exact sequence of native invocations and their timing.
class MethodChannelEfactor extends EfactorPlatform {
  static const _tag = 'MethodChannel';

  final MethodChannel _methods =
      const MethodChannel('efactor_provisioning/methods');

  final EventChannel _stateEvents =
      const EventChannel('efactor_provisioning/state');

  final EventChannel _logEvents =
      const EventChannel('efactor_provisioning/logs');

  final EventChannel _cloudEvents =
      const EventChannel('efactor_provisioning/cloud_events');

  final EventChannel _discoveryEvents =
      const EventChannel('efactor_provisioning/discovery_events');

  final EventChannel _provisioningEvents =
      const EventChannel('efactor_provisioning/provisioning_events');

  Stream<EfProvState>? _stateStream;
  Stream<EfCloudEvent>? _cloudStream;
  Stream<EfDiscoveryEvent>? _discoveryStream;
  Stream<EfProvisioningEvent>? _provisioningStream;
  bool _nativeLogsBridged = false;

  /// Wraps a native invocation with timing + error logging.
  Future<T> _invoke<T>(
    String method, [
    Map<String, dynamic>? args,
    EfProvState? step,
  ]) async {
    final sw = Stopwatch()..start();
    EfLog.d(_tag, '→ $method(${_fmtArgs(args)})');
    try {
      final result = await _methods.invokeMethod<T>(method, args);
      EfLog.d(_tag, '← $method ok in ${sw.elapsedMilliseconds}ms');
      return result as T;
    } on PlatformException catch (e) {
      EfLog.e(_tag, '✗ $method failed: ${e.code} ${e.message}', e);
      throw EfProvisioningException(
        e.code,
        e.message ?? 'native error',
        step: step,
        details: e.details,
      );
    }
  }

  String _fmtArgs(Map<String, dynamic>? args) {
    if (args == null) return '';
    // Avoid dumping large byte payloads; show sizes instead.
    return args.entries.map((e) {
      final v = e.value;
      if (v is Uint8List) return '${e.key}=<${v.length}B>';
     // if (e.key == 'passphrase' || e.key == 'pop') return '${e.key}=***';
      if (e.key == 'passphrase' || e.key == 'pop' ||
          e.key == 'apiKey' || e.key == 'accessToken') return '${e.key}=***';
      return '${e.key}=$v';
    }).join(', ');
  }

  @override
  Future<String?> platformVersion() =>
      _invoke<String?>('platformVersion');

  @override
  Future<String?> libVersion() => _invoke<String?>('libVersion');

  @override
  Future<void> connect({
    required String deviceName,
    required EfTransport transport,
    required EfSecurity security,
    String? pop,
    String? username,
  }) =>
      _invoke<void>('connect', {
        'deviceName': deviceName,
        'transport': transport.name,
        'security': security.name,
        'pop': pop,
        'username': username,
      }, EfProvState.connecting);

  @override
  Future<List<EfWifiNetwork>> scanNetworks() async {
    final raw = await _invoke<List<dynamic>>(
      'scanNetworks',
      null,
      EfProvState.scanning,
    );
    final list = raw
        .map((e) => EfWifiNetwork.fromMap(e as Map<dynamic, dynamic>))
        .toList();
    EfLog.i(_tag, 'scan found ${list.length} networks');
    return list;
  }

  @override
  Future<void> provision({
    required String ssid,
    required String passphrase,
  }) =>
      _invoke<void>('provision', {
        'ssid': ssid,
        'passphrase': passphrase,
      }, EfProvState.sendingCredentials);

  @override
  Future<EfCustomResponse> sendCustomData({
    required String endpoint,
    required Uint8List payload,
  }) async {
    final raw = await _invoke<Map<dynamic, dynamic>>(
      'sendCustomData',
      {'endpoint': endpoint, 'payload': payload},
      EfProvState.sendingCustomData,
    );
    return EfCustomResponse.fromMap(raw);
  }

  @override
  Future<void> disconnect() => _invoke<void>('disconnect');

  @override
  Stream<EfProvState> get stateStream {
    _bridgeNativeLogs();
    _stateStream ??= _stateEvents.receiveBroadcastStream().map((event) {
      final name = event as String;
      final state = EfProvState.values.firstWhere(
        (s) => s.name == name,
        orElse: () => EfProvState.idle,
      );
      EfLog.d(_tag, 'state → ${state.name}');
      return state;
    });
    return _stateStream!;
  }

  // ---- Cloud WebSocket ----

  @override
  Future<void> cloudInitialize({required String apiKey}) =>
      _invoke<void>('cloudInitialize', {'apiKey': apiKey});

  @override
  Future<void> cloudGetDevices({required String apiKey, String? nodeId}) =>
      _invoke<void>('cloudGetDevices', {'apiKey': apiKey, 'nodeId': nodeId});

  @override
  Future<void> cloudGetAllNodes({required String apiKey, String? nodeId}) =>
      _invoke<void>('cloudGetAllNodes', {'apiKey': apiKey, 'nodeId': nodeId});

  @override
  Future<void> cloudGetAllNodesStatus({required String apiKey}) =>
      _invoke<void>('cloudGetAllNodesStatus', {'apiKey': apiKey});

  @override
  Future<void> cloudSetProvisionStarted({required bool status}) =>
      _invoke<void>('cloudSetProvisionStarted', {'status': status});

  @override
  Future<void> cloudReconnect() => _invoke<void>('cloudReconnect');

  @override
  Future<void> cloudDisconnect() => _invoke<void>('cloudDisconnect');

  @override
  Stream<EfCloudEvent> get cloudEvents {
    _cloudStream ??= _cloudEvents.receiveBroadcastStream().map((event) {
      final ev = EfCloudEvent.fromMap(event as Map<dynamic, dynamic>);
      EfLog.d(_tag, 'cloud event ← ${ev.type.name}');
      return ev;
    });
    return _cloudStream!;
  }

  // ---- mDNS discovery ----

  @override
  Future<void> discoveryStart() => _invoke<void>('discoveryStart');

  @override
  Future<void> discoveryStop() => _invoke<void>('discoveryStop');

  @override
  Future<List<EfLocalDevice>> discoveryGetDevices() async {
    final raw = await _invoke<List<dynamic>>('discoveryGetDevices');
    return raw
        .map((e) => EfLocalDevice.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  @override
  Stream<EfDiscoveryEvent> get discoveryEvents {
    _discoveryStream ??= _discoveryEvents.receiveBroadcastStream().map((event) {
      final ev = EfDiscoveryEvent.fromMap(event as Map<dynamic, dynamic>);
      EfLog.d(_tag, 'discovery ← $ev');
      return ev;
    });
    return _discoveryStream!;
  }

  // ---- Provisioning ----

  @override
  Future<void> provStart({required String pop, required String apiKey, required String ssid, required String password, required String userName,  String security = 'SEC1'}) =>
      _invoke<void>('provStart', {'pop': pop, 'apiKey': apiKey, 'ssid': ssid, 'password': password,'userName': userName, 'security': security});

  @override
  Future<void> provCancel() => _invoke<void>('provCancel');

  @override
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
  }) async {
    final res = await _methods.invokeMethod<Map<dynamic, dynamic>>('sendData', {
      'apiKey': apiKey,
      'nodeId': nodeId,
      'deviceId': deviceId,
      'pageName': pageName,
      'paramName': paramName,
      'value': value,
      'data': data,
      'latitude': latitude,
      'longitude': longitude,
    });
    return EfSendDataResult.fromMap(res ?? {'ok': false, 'raw': {}});
  }

  @override

  @override
  Stream<EfProvisioningEvent> get provisioningEvents {
    _provisioningStream ??= _provisioningEvents.receiveBroadcastStream().map((event) {
      final ev = EfProvisioningEvent.fromMap(event as Map<dynamic, dynamic>);
      EfLog.d(_tag, 'provisioning ← $ev');
      return ev;
    });
    return _provisioningStream!;
  }

  /// Subscribes to native-emitted log lines and re-emits them through [EfLog],
  /// so Android/iOS internal logs appear in the same unified stream as Dart.
  void _bridgeNativeLogs() {
    if (_nativeLogsBridged) return;
    _nativeLogsBridged = true;
    _logEvents.receiveBroadcastStream().listen(
      (event) {
        final m = event as Map<dynamic, dynamic>;
        final lvl = (m['level'] as String? ?? 'debug');
        final tag = 'native:${m['tag'] ?? '?'}';
        final msg = m['message'] as String? ?? '';
        switch (lvl) {
          case 'error':
            EfLog.e(tag, msg);
            break;
          case 'warn':
            EfLog.w(tag, msg);
            break;
          case 'info':
            EfLog.i(tag, msg);
            break;
          default:
            EfLog.d(tag, msg);
        }
      },
      onError: (Object err) => EfLog.e(_tag, 'native log stream error', err),
    );
  }
}
