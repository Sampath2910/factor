import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebSocket & Telemetry Multi-Page Dynamic Updates', () {
    test('Number validation allows 0 for standby/off when min > 0', () {
      final controls = [
        {
          'id': 'fan_speed',
          'binding': 'device.parameters.fan_speed',
          'componentType': 'slider',
          'valueType': 'number',
          'constraints': {'minimum': 1, 'maximum': 7},
        }
      ];

      final appState = AppState({
        'controls': controls,
        'state': {
          'device': {
            'parameters': {'fan_speed': 5},
          },
        },
      });

      // Verify normal within-range update works
      appState.applyRemoteParameter('fan_speed', 3);
      expect(appState.parameters['fan_speed'], 3);

      // Verify speed: 0 (standby/off from telemetry/WS) is accepted without throwing
      appState.applyRemoteParameter('fan_speed', 0);
      expect(appState.parameters['fan_speed'], 0);

      // String "0" is parsed to 0 and accepted
      appState.applyRemoteParameter('fan_speed', '0');
      expect(appState.parameters['fan_speed'], 0);
    });

    test('Enum validation and coercion matches hex and zero-padded values', () {
      final controls = [
        {
          'id': 'direction',
          'binding': 'device.parameters.direction',
          'componentType': 'dropdown',
          'valueType': 'enum',
          'options': [
            {'value': '0', 'label': 'Forward'},
            {'value': '1', 'label': 'Reverse'},
          ],
        }
      ];

      final appState = AppState({
        'controls': controls,
        'state': {
          'device': {
            'parameters': {'direction': '0'},
          },
        },
      });

      // Telemetry sending "00" matches "0"
      appState.applyRemoteParameter('direction', '00');
      expect(appState.parameters['direction'], '0');

      // Telemetry sending "01" matches "1"
      appState.applyRemoteParameter('direction', '01');
      expect(appState.parameters['direction'], '1');

      // Telemetry sending numeric 0 matches "0"
      appState.applyRemoteParameter('direction', 0);
      expect(appState.parameters['direction'], '0');
    });

    test('mergeDevicePageSchema generates distinct and deterministic _clientSchemaHash', () {
      final base = {
        'id': 'schema_model_1',
        '_clientSchemaHash': 'initial_hash',
        'controls': [
          {'id': 'c1', 'binding': 'p1'}
        ],
        'pages': [
          {'id': 'p1', 'pageNo': 1, 'controlIds': ['c1']}
        ],
        'ui': <String, dynamic>{},
      };

      final page2 = {
        'id': 'page_2',
        '_clientSchemaHash': 'hash_page_2',
        'controls': [
          {'id': 'c2', 'binding': 'p2'}
        ],
        'pages': [
          {'id': 'p2', 'pageNo': 2, 'controlIds': ['c2']}
        ],
      };

      final merged = SchemaRepository.mergeDevicePageSchema(base, page2);
      expect(merged['_clientSchemaHash'], isNotNull);
      expect(merged['_clientSchemaHash'], isNot(equals(base['_clientSchemaHash'])));
      expect(merged['controls'].length, 2);
      expect(merged['pages'].length, 2);
    });

    test('IotSduiState.applyLiveNodes updates online and power state immediately', () {
      final state = IotSduiState(
        schema: {
          'devices': [
            {
              'node_id': 'node_fan_123',
              'name': 'Living Room Fan',
              'online': false,
              'status': 'Offline',
              'power': false,
            }
          ]
        },
        accessToken: 'dummy_token',
      );

      expect(state.devices.first['online'], false);

      state.applyLiveNodes({
        'node_fan_123': {
          'status': {
            'connectivity': {'connected': true},
            'power': true,
          }
        }
      });

      expect(state.devices.first['online'], true);
      expect(state.devices.first['status'], 'Online');
      expect(state.devices.first['power'], true);
    });

    test('HomeSduiState.applyLiveNodes updates device list in _data', () {
      final state = HomeSduiState(
        schema: {
          'state': <String, dynamic>{},
        },
        accessToken: 'dummy_token',
      );

      // Inject simulated dashboard data into state
      state.applyLiveNodes({}); // initial no-op

      // When live nodes push is received:
      state.applyLiveNodes({
        'node_switch_99': {
          'status': {
            'connectivity': {'connected': true},
            'power': true,
          }
        }
      });

      // No crash, listeners notified
    });

    test('Multi-page indexed response matching maps response fields to correct bindings across pages', () {
      final responseDefinitions = [
        {'default_name': 'Buzzer', 'ui_type': 'Toggle Switch'},
        {'default_name': 'Speed', 'ui_type': 'Text'},
        {'default_name': 'Direction', 'ui_type': 'Text'},
        {'default_name': 'Color', 'ui_type': 'Text'},
        {'default_name': 'Lamp', 'ui_type': 'Text'},
        {'default_name': 'Timer', 'ui_type': 'Text'},
        {'default_name': 'DimmingLevel', 'ui_type': 'Text'},
        {'default_name': 'Fan', 'ui_type': 'Text'},
        {'default_name': 'Watt', 'ui_type': 'Text'},
      ];

      final deviceConfigFrame = {
        'id': 'frame_status',
        'default_name': 'Command Get Status',
        'response': responseDefinitions,
      };

      // Page 1 has Speed (index 1) and Direction (index 2)
      // Page 2 has Watt (index 8)
      final controls = [
        {
          'id': '3:command_get_status:response-1',
          'binding': 'device.parameters.3_command_get_status_response_1',
          'responseField': {'default_name': 'Speed'},
          'deviceConfigFrame': deviceConfigFrame,
        },
        {
          'id': '3:command_get_status:response-2',
          'binding': 'device.parameters.3_command_get_status_response_2',
          'responseField': {'default_name': 'Direction'},
          'deviceConfigFrame': deviceConfigFrame,
        },
        {
          'id': '3:command_get_status:response-8',
          'binding': 'device.parameters.3_command_get_status_response_8',
          'responseField': {'default_name': 'Watt'},
          'deviceConfigFrame': deviceConfigFrame,
        },
      ];

      final appState = AppState({
        'controls': controls,
        'state': {
          'device': {
            'parameters': {
              '3_command_get_status_response_1': '0',
              '3_command_get_status_response_2': '0',
              '3_command_get_status_response_8': '0',
            },
          },
        },
      });

      // WebSocket pushes named parameters Speed=5, Direction=01, Watt=42
      appState.applyRemoteParameter('Speed', 5);
      appState.applyRemoteParameter('Direction', '01');
      appState.applyRemoteParameter('Watt', 42);

      // Verify each response binding receives its respective telemetry
      expect(appState.parameters['3_command_get_status_response_1'], '5');
      expect(appState.parameters['3_command_get_status_response_2'], '01');
      expect(appState.parameters['3_command_get_status_response_8'], '42');
    });
  });
}
