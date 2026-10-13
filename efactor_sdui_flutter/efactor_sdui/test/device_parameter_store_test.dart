import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/services/device_parameter_store.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('DeviceParameterStore writes once and skips unchanged payload', () async {
    final store = DeviceParameterStore(
      modelId: 'EF-003FMN03',
      nodeId: 'NODE-A',
    );

    final first = await store.writeIfChanged(<String, dynamic>{
      '2_power': true,
      '2_speed': 6,
      '2_voltage': '--', // stripped
    });
    expect(first, isTrue);

    final second = await store.writeIfChanged(<String, dynamic>{
      '2_power': true,
      '2_speed': 6,
    });
    expect(second, isFalse);

    final cached = await store.read();
    expect(cached?['2_power'], true);
    expect(cached?['2_speed'], 6);
    expect(cached?.containsKey('2_voltage'), isFalse);
  });

  test('AppState hydrates cache and only persists on real changes', () async {
    final state = AppState({
      'schemaVersion': '4.1.0',
      'state': {
        'device': {
          'parameters': {
            '2_power_command_2_toggle_switch': false,
            '2_speed_command_2_slider': 1,
            '2_voltage_command_0_text': '--',
          },
        },
      },
      'controls': [
        {
          'id': '2:power',
          'binding': 'device.parameters.2_power_command_2_toggle_switch',
          'componentType': 'switch',
          'valueType': 'boolean',
        },
        {
          'id': '2:Speed',
          'binding': 'device.parameters.2_speed_command_2_slider',
          'componentType': 'slider',
          'valueType': 'number',
        },
        {
          'id': '2:Voltage',
          'binding': 'device.parameters.2_voltage_command_0_text',
          'componentType': 'textField',
          'valueType': 'string',
        },
      ],
    });

    state.attachParameterStore(modelId: 'EF-003', nodeId: 'N1');

    // Seed disk as if a previous session received auto_get_nodes_params.
    final store = DeviceParameterStore(modelId: 'EF-003', nodeId: 'N1');
    await store.writeIfChanged(<String, dynamic>{
      '2_power_command_2_toggle_switch': true,
      '2_speed_command_2_slider': 6,
      '2_voltage_command_0_text': '28.82',
    });

    final hydrated = await state.hydrateParametersFromCache();
    expect(hydrated, greaterThan(0));
    expect(
      state.resolveBinding('device.parameters.2_power_command_2_toggle_switch'),
      true,
    );
    expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 6);
    expect(
      state.resolveBinding('device.parameters.2_voltage_command_0_text'),
      '28.82',
    );

    // Unchanged remote echo must not wipe / force-rewrite.
    state.applyRemoteParameter('Speed', 6);
    expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 6);

    state.applyRemoteParameter('Speed', 7);
    expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 7);

    state.dispose();
  });
}
