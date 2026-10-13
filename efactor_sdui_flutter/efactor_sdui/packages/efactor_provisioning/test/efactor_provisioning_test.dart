import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'package:efactor_provisioning/src/efactor_platform_interface.dart';

/// A fake platform so the Dart API can be tested with no native side.
class FakePlatform extends EfactorPlatform {
  final List<String> calls = [];

  @override
  Future<String?> libVersion() async {
    calls.add('libVersion');
    return 'v-test';
  }

  @override
  Future<void> connect({
    required String deviceName,
    required EfTransport transport,
    required EfSecurity security,
    String? pop,
    String? username,
  }) async {
    calls.add('connect:$deviceName');
  }

  @override
  Future<List<EfWifiNetwork>> scanNetworks() async {
    calls.add('scan');
    return [EfWifiNetwork(ssid: 'net', rssi: -40, auth: 3)];
  }

  @override
  Future<void> provision({
    required String ssid,
    required String passphrase,
  }) async {
    calls.add('provision:$ssid');
  }

  @override
  Future<EfCustomResponse> sendCustomData({
    required String endpoint,
    required Uint8List payload,
  }) async {
    calls.add('custom:$endpoint');
    return EfCustomResponse(bytes: Uint8List.fromList([9, 9]));
  }

  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform();
    EfactorPlatform.instance = fake;
  });

  test('libVersion routes to platform', () async {
    final v = await EfactorProvisioning.instance.libVersion();
    expect(v, 'v-test');
    expect(fake.calls, contains('libVersion'));
  });

  test('full flow records ordered calls', () async {
    final api = EfactorProvisioning.instance;
    await api.connect(deviceName: 'D1');
    await api.scanNetworks();
    await api.provision(ssid: 'home', passphrase: 'pw');
    await api.sendCustomData(
        endpoint: 'ep', payload: Uint8List.fromList([1]));
    await api.disconnect();

    expect(fake.calls, [
      'connect:D1',
      'scan',
      'provision:home',
      'custom:ep',
      'disconnect',
    ]);
  });

  test('scan parses networks', () async {
    final nets = await EfactorProvisioning.instance.scanNetworks();
    expect(nets.single.ssid, 'net');
  });
}
