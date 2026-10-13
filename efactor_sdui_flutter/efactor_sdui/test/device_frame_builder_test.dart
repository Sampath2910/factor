import 'dart:convert';
import 'dart:io';

import 'package:efactor_sdui/services/device_command_transport.dart';
import 'package:efactor_sdui/services/device_frame_builder.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingTransport implements DeviceCommandTransport {
  _RecordingTransport(this.requests);

  final List<DeviceCommandRequest> requests;

  @override
  Future<DeviceCommandResult> send(DeviceCommandRequest request) async {
    requests.add(request);
    return const DeviceCommandResult(status: DeviceCommandStatus.accepted);
  }
}

Map<String, dynamic> loadFanSchema() {
  final raw = jsonDecode(
    File('test/fixtures/device_frame_schema.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return raw;
}

Map<String, dynamic> controlById(Map<String, dynamic> schema, String id) {
  final controls = schema['controls'] as List;
  return Map<String, dynamic>.from(
    controls.cast<Map>().firstWhere((control) => control['id'] == id),
  );
}

void main() {
  late Map<String, dynamic> schema;

  setUpAll(() {
    schema = loadFanSchema();
  });

  test('new schema identity is published without _clientConnection', () {
    final state = AppState(schema);
    expect(state.resolveDeviceIdentity().modelId, 'EF-003FMN03');
    expect(
      state.resolveDeviceIdentity().nodeId,
      'FFFFFFFFFFFFFFFF7EC200000005E800',
    );
    expect(
      state.isBindingWritable('device.parameters.1_rpm_command_0_text'),
      isFalse,
    );
    expect(
      state.isBindingWritable('device.parameters.1_speed_command_2_slider'),
      isTrue,
    );
  });

  test('buzzer and power frames follow the live boolean mapping', () {
    final buzzer = controlById(schema, '1:Buzzer:command-2-toggle-switch');
    expect(
      DeviceFrameBuilder.build(control: buzzer, runtimeValue: false).frameHex,
      'A1BB000A',
    );
    expect(
      DeviceFrameBuilder.build(control: buzzer, runtimeValue: true).frameHex,
      'A1BB010A',
    );

    final power = controlById(schema, '1:power:command-2-toggle-switch');
    expect(
      DeviceFrameBuilder.build(control: power, runtimeValue: false).frameHex,
      'A1C2000A',
    );
    expect(
      DeviceFrameBuilder.build(control: power, runtimeValue: true).frameHex,
      'A1C2010A',
    );
  });

  test('speed slider encodes 1-7 instead of the stale 06 snapshot', () {
    final speed = controlById(schema, '1:Speed:command-2-slider');
    expect(
      DeviceFrameBuilder.build(control: speed, runtimeValue: 1).frameHex,
      'A1C0010A',
    );
    expect(
      DeviceFrameBuilder.build(control: speed, runtimeValue: 4.0).frameHex,
      'A1C0040A',
    );
    expect(
      DeviceFrameBuilder.build(control: speed, runtimeValue: 7).frameHex,
      'A1C0070A',
    );
  });

  test('direction trigger sends mapped 08, not the stale 01 snapshot', () {
    final direction = controlById(schema, '1:Direction:command-2-trigger');
    expect(
      DeviceFrameBuilder.build(control: direction, runtimeValue: 'Command')
          .frameHex,
      'A1C0080A',
    );
    expect(
      DeviceFrameBuilder.build(control: direction, runtimeValue: '0').frameHex,
      'A1C0080A',
    );
    expect(
      DeviceFrameBuilder.build(control: direction, runtimeValue: '08').frameHex,
      'A1C0080A',
    );
  });

  test('rpm status frame stays a 2-byte read snapshot', () {
    final rpm = controlById(schema, '1:rpm:command-0-text');
    final built = DeviceFrameBuilder.build(
      control: rpm,
      runtimeValue: 'Command',
    );
    expect(built.ok, isTrue);
    expect(built.frameHex, '013D');
  });

  testWidgets(
    'speed slider commit still sends after onChanged already stored the value',
    (tester) async {
      final requests = <DeviceCommandRequest>[];
      final state = AppState(
        schema,
        transport: _RecordingTransport(requests),
        accessToken: 'test-token',
      );
      addTearDown(state.dispose);
      const binding = 'device.parameters.1_speed_command_2_slider';

      state.setBinding(binding, 4.0, dispatch: false);
      expect(requests, isEmpty);

      state.setBinding(binding, 4.0);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(requests, isNotEmpty);
      expect(requests.last.finalFrame, 'A1C0040A');
      expect(requests.last.nodeId, 'FFFFFFFFFFFFFFFF7EC200000005E800');
      expect(requests.last.value, 4.0);
    },
  );
}
