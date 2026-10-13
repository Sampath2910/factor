import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  group('Remote and Cloud Parameter Synchronization Tests', () {
    test('applyRemoteParameter updates direct and prefixed/suffixed bindings', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '1:Speed',
            'binding': 'device.parameters.1_speed_command_2_slider',
            'componentType': 'slider',
            'valueType': 'number',
            'initialValue': 1,
          },
          {
            'id': '1:Buzzer',
            'binding': 'device.parameters.1_buzzer',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      });

      expect(state.resolveBinding('device.parameters.1_power'), false);
      expect(state.resolveBinding('device.parameters.1_speed_command_2_slider'), 1);
      expect(state.resolveBinding('device.parameters.1_buzzer'), false);

      state.applyRemoteParameter('power', 'true');
      expect(state.resolveBinding('device.parameters.1_power'), true);

      state.applyRemoteParameter('Speed', 5);
      expect(state.resolveBinding('device.parameters.1_speed_command_2_slider'), 5);

      state.applyRemoteParameter('Buzzer', 'true');
      expect(state.resolveBinding('device.parameters.1_buzzer'), true);

      state.applyRemoteParameter('power', 'false');
      expect(state.resolveBinding('device.parameters.1_power'), false);

      state.applyRemoteParameter('Buzzer', '0');
      expect(state.resolveBinding('device.parameters.1_buzzer'), false);
    });

    test('Nested telemetry map with empty key "" or "parameters" unpacks all parameters', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '1:Speed',
            'binding': 'device.parameters.1_speed',
            'componentType': 'slider',
            'valueType': 'number',
            'initialValue': 1,
          },
          {
            'id': '1:Voltage',
            'binding': 'device.parameters.1_voltage',
            'componentType': 'value',
            'valueType': 'number',
            'initialValue': 0,
          },
        ],
      });

      final telemetry = {
        'node_id': 'FFFFFFFFFFFFFFFF7EC2000000049200',
        '': {
          'power': 'true',
          'Speed': 3,
          'Voltage': 25.19,
        },
      };

      void extractAndApply(dynamic data) {
        if (data is! Map) return;
        for (final entry in data.entries) {
          final k = entry.key.toString().trim();
          final v = entry.value;
          if (v is Map) {
            extractAndApply(v);
            continue;
          }
          if (k.isEmpty || k == 'node_id') continue;
          if (v is! List) {
            state.applyRemoteParameter(k, v);
          }
        }
      }

      extractAndApply(telemetry);

      expect(state.resolveBinding('device.parameters.1_power'), true);
      expect(state.resolveBinding('device.parameters.1_speed'), 3);
      expect(state.resolveBinding('device.parameters.1_voltage'), 25.19);
    });

    test('auto_get_nodes_params device alias map updates voltage/current/rpm/name', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '2_name_command_0_text': '--',
              '2_voltage_command_0_text': '--',
              '2_current_command_0_text': '--',
              '2_rpm_command_0_text': '--',
              '2_buzzer_command_2_toggle_switch': false,
              '2_direction_command_2_trigger': '--',
              '2_speed_command_2_slider': 1,
              '2_power_command_2_toggle_switch': false,
            },
          },
        },
        'controls': [
          {
            'id': '2:name',
            'binding': 'device.parameters.2_name_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:Voltage',
            'binding': 'device.parameters.2_voltage_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:Current',
            'binding': 'device.parameters.2_current_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:rpm',
            'binding': 'device.parameters.2_rpm_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:Buzzer',
            'binding': 'device.parameters.2_buzzer_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
          },
          {
            'id': '2:Direction',
            'binding': 'device.parameters.2_direction_command_2_trigger',
            'componentType': 'elevatedButton',
            'valueType': 'string',
          },
          {
            'id': '2:Speed',
            'binding': 'device.parameters.2_speed_command_2_slider',
            'componentType': 'slider',
            'valueType': 'number',
          },
          {
            'id': '2:power',
            'binding': 'device.parameters.2_power_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
          },
        ],
      });

      final payload = {
        'node_id': 'FFFFFFFFFFFFFFFF7EC2000000040300',
        'action': 'auto_get_nodes_params',
        'fan_7E000403': {
          'power': 'true',
          'Speed': 6,
          'Direction': '00',
          'Buzzer': 'true',
          'rpm': 255,
          'Current': 1.36,
          'Voltage': 28.82,
          'name': 'fan_403',
        },
      };

      void extractAndApply(dynamic data) {
        if (data is List) {
          for (final item in data) {
            extractAndApply(item);
          }
          return;
        }
        if (data is! Map) return;
        for (final entry in data.entries) {
          final k = entry.key.toString().trim();
          final v = entry.value;
          if (k == 'action' || k == 'node_id' || k == 'frame') continue;
          if (v is Map || v is List) {
            extractAndApply(v);
            continue;
          }
          if (k.isEmpty) continue;
          state.applyRemoteParameter(k, v);
        }
      }

      extractAndApply(payload);

      expect(
        state.resolveBinding('device.parameters.2_power_command_2_toggle_switch'),
        true,
      );
      expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 6);
      expect(
        state.resolveBinding('device.parameters.2_direction_command_2_trigger'),
        '00',
      );
      expect(
        state.resolveBinding('device.parameters.2_buzzer_command_2_toggle_switch'),
        true,
      );
      expect(state.resolveBinding('device.parameters.2_rpm_command_0_text'), '255');
      expect(
        state.resolveBinding('device.parameters.2_current_command_0_text'),
        '1.36',
      );
      expect(
        state.resolveBinding('device.parameters.2_voltage_command_0_text'),
        '28.82',
      );
      expect(
        state.resolveBinding('device.parameters.2_name_command_0_text'),
        'fan_403',
      );
    });

    test('schema parameter and control-id aliases match every telemetry field', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '3_name': '--',
              '3_voltage': '--',
              '3_current': '--',
              '3_rpm': '--',
              '3_buzzer': false,
              '3_direction': '--',
              '3_speed': 0,
            },
          },
        },
        'controls': [
          {
            'id': 'name-row',
            'parameter': 'name',
            'binding': 'device.parameters.3_name',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '3:Voltage',
            'binding': 'device.parameters.3_voltage',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '3:Current',
            'binding': 'device.parameters.3_current',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '3:rpm',
            'binding': 'device.parameters.3_rpm',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '3:Buzzer',
            'binding': 'device.parameters.3_buzzer',
            'componentType': 'switch',
            'valueType': 'boolean',
          },
          {
            'id': '3:Direction',
            'binding': 'device.parameters.3_direction',
            'componentType': 'elevatedButton',
            'valueType': 'string',
          },
          {
            'id': '3:Speed',
            'binding': 'device.parameters.3_speed',
            'componentType': 'slider',
            'valueType': 'number',
          },
        ],
      });

      state.applyRemoteParameter('name', 'Pump A');
      state.applyRemoteParameter('Voltage', 230.5);
      state.applyRemoteParameter('Current', 4.2);
      state.applyRemoteParameter('rpm', 1480);
      state.applyRemoteParameter('Buzzer', 'true');
      state.applyRemoteParameter('Direction', 'CW');
      state.applyRemoteParameter('Speed', 9);

      expect(state.resolveBinding('device.parameters.3_name'), 'Pump A');
      expect(state.resolveBinding('device.parameters.3_voltage'), '230.5');
      expect(state.resolveBinding('device.parameters.3_current'), '4.2');
      expect(state.resolveBinding('device.parameters.3_rpm'), '1480');
      expect(state.resolveBinding('device.parameters.3_buzzer'), true);
      expect(state.resolveBinding('device.parameters.3_direction'), 'CW');
      expect(state.resolveBinding('device.parameters.3_speed'), 9);

      state.applyRemoteParameter('Voltage', 231);
      expect(state.resolveBinding('device.parameters.3_voltage'), '231');
    });

    test('nested cloud value objects update voltage current and rpm', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '2_voltage': '--',
              '2_current': '--',
              '2_rpm': '--',
            },
          },
        },
        'controls': [
          {
            'id': '2:Voltage',
            'parameter': 'Voltage',
            'binding': 'device.parameters.2_voltage',
            'componentType': 'textField',
            'valueType': 'string',
            'initialValue': '--',
          },
          {
            'id': '2:Current',
            'parameter': 'Current',
            'binding': 'device.parameters.2_current',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:rpm',
            'parameter': 'rpm',
            'binding': 'device.parameters.2_rpm',
            'componentType': 'textField',
            'valueType': 'string',
          },
        ],
      });

      expect(state.resolveBinding('device.parameters.2_voltage'), '--');

      state.applyRemoteParameter('Voltage', {'value': 28.82, 'unit': 'V'});
      state.applyRemoteParameter('Current', {'value': '1.36'});
      state.applyRemoteParameter('rpm', {'value': 255});

      expect(state.resolveBinding('device.parameters.2_voltage'), '28.82');
      expect(state.resolveBinding('device.parameters.2_current'), '1.36');
      expect(state.resolveBinding('device.parameters.2_rpm'), '255');
    });

    test('schema deviceFrame asperui_value is shown and identical cloud values do not rewrite it', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '2_voltage': '--',
              '2_current': '--',
              '2_rpm': '--',
              '2_speed': '--',
            },
          },
        },
        'controls': [
          {
            'id': '2:Voltage',
            'parameter': 'Voltage',
            'binding': 'device.parameters.2_voltage',
            'componentType': 'textField',
            'valueType': 'string',
            'deviceFrame': {
              'name': 'Voltage',
              'commands': [
                {
                  'Field_description': 'Data',
                  'asperui_value': '25.379999',
                  'ui_type': 'Text',
                },
              ],
            },
          },
          {
            'id': '2:Current',
            'parameter': 'Current',
            'binding': 'device.parameters.2_current',
            'componentType': 'textField',
            'valueType': 'string',
            'deviceFrame': {
              'name': 'Current',
              'commands': [
                {
                  'Field_description': 'Data',
                  'asperui_value': '-2.046000',
                },
              ],
            },
          },
          {
            'id': '2:rpm',
            'parameter': 'rpm',
            'binding': 'device.parameters.2_rpm',
            'componentType': 'textField',
            'valueType': 'string',
            'deviceFrame': {
              'name': 'rpm',
              'commands': [
                {
                  'Field_description': 'Data',
                  'asperui_value': 312,
                },
              ],
            },
          },
          {
            'id': '2:Speed',
            'parameter': 'Speed',
            'binding': 'device.parameters.2_speed',
            'componentType': 'slider',
            'valueType': 'number',
            'deviceFrame': {
              'name': 'Speed',
              'commands': [
                {
                  'Field_description': 'Data',
                  'asperui_value': 6,
                },
              ],
            },
          },
        ],
      });

      expect(state.resolveBinding('device.parameters.2_voltage'), '25.379999');
      expect(state.resolveBinding('device.parameters.2_current'), '-2.046000');
      expect(state.resolveBinding('device.parameters.2_rpm'), '312');
      expect(state.resolveBinding('device.parameters.2_speed'), 6);

      state.applyRemoteParameter('Voltage', '25.379999');
      expect(state.resolveBinding('device.parameters.2_voltage'), '25.379999');

      state.applyRemoteParameter('Voltage', '26.1');
      expect(state.resolveBinding('device.parameters.2_voltage'), '26.1');

      state.applyRemoteParameter('Speed', 6);
      expect(state.resolveBinding('device.parameters.2_speed'), 6);

      state.applyRemoteParameter('Speed', 2);
      expect(state.resolveBinding('device.parameters.2_speed'), 2);
    });

    test('schema placeholder -- does not wipe live auto_get_nodes_params values', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '2_voltage_command_0_text': '--',
              '2_speed_command_2_slider': 1,
            },
          },
        },
        'controls': [
          {
            'id': '2:Voltage',
            'binding': 'device.parameters.2_voltage_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
          },
          {
            'id': '2:Speed',
            'binding': 'device.parameters.2_speed_command_2_slider',
            'componentType': 'slider',
            'valueType': 'number',
          },
        ],
        'pages': [
          {'id': 'page-1', 'root': <String, dynamic>{}},
        ],
      });

      state.applyRemoteParameter('Voltage', 28.82);
      state.applyRemoteParameter('Speed', 6);
      expect(
        state.resolveBinding('device.parameters.2_voltage_command_0_text'),
        '28.82',
      );
      expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 6);

      state.replaceSchema(
        {
          'schemaVersion': '4.1.1',
          'state': {
            'device': {
              'parameters': {
                '2_voltage_command_0_text': '--',
                '2_speed_command_2_slider': '--',
              },
            },
          },
          'controls': [
            {
              'id': '2:Voltage',
              'binding': 'device.parameters.2_voltage_command_0_text',
              'componentType': 'textField',
              'valueType': 'string',
            },
            {
              'id': '2:Speed',
              'binding': 'device.parameters.2_speed_command_2_slider',
              'componentType': 'slider',
              'valueType': 'number',
            },
          ],
          'pages': [
            {
              'id': 'page-1',
              'root': <String, dynamic>{'type': 'column'},
            },
          ],
        },
        preserveValues: true,
        preservePage: true,
      );

      expect(
        state.resolveBinding('device.parameters.2_voltage_command_0_text'),
        '28.82',
      );
      expect(state.resolveBinding('device.parameters.2_speed_command_2_slider'), 6);
    });

    test('unset remote values are ignored', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'controls': [
          {
            'id': '2:Voltage',
            'binding': 'device.parameters.2_voltage',
            'componentType': 'textField',
            'valueType': 'string',
            'initialValue': '28.82',
          },
        ],
      });

      state.applyRemoteParameter('Voltage', '--');
      expect(state.resolveBinding('device.parameters.2_voltage'), '28.82');
    });

    test('wrapped cloud readings update speed and the terminal log appends', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'meta': {
          'links': {
            'schema':
                'https://efactor.tech/v8/api_schema.php?model_no=EF&node_id=NODE1',
          },
        },
        'dataSources': {
          'deviceCommands': {'node_id': 'NODE1'},
        },
        'controls': [
          {
            'id': '1:Speed',
            'parameter': 'Speed',
            'binding': 'device.parameters.1_speed_command_2_slider',
            'componentType': 'slider',
            'valueType': 'number',
            'initialValue': 1,
          },
          {
            'id': '1:rpm',
            'parameter': 'rpm',
            'binding': 'device.parameters.1_rpm_command_0_text',
            'componentType': 'textField',
            'valueType': 'string',
            'initialValue': 'rpm',
          },
          {
            'id': '1:Direction',
            'parameter': 'Direction',
            'binding': 'device.parameters.1_direction_command_2_trigger',
            'componentType': 'segmented',
            'valueType': 'string',
            'initialValue': '0',
          },
          {
            'id': '3:Display Log',
            'parameter': 'Display Log',
            'binding': 'device.parameters.3_display_log_command_0_button',
            'componentType': 'button',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '3:Display',
            'parameter': 'Display',
            'binding': 'device.parameters.3_display_command_0_console',
            'componentType': 'textField',
            'valueType': 'string',
            'value': 'Display',
            'component': {
              'props': {
                'variant': 'terminal',
                'promptSymbol': '>',
              },
            },
          },
        ],
      });

      state.ingestCloudPayload({
        'node_id': 'NODE1',
        'action': 'auto_get_nodes_params',
        'fan': {
          'Speed': {'value': 6, 'unit': ''},
          'Direction': {'asperui_value': '01'},
        },
      }, nodeId: 'NODE1');

      expect(
        state.resolveBinding('device.parameters.1_speed_command_2_slider'),
        6,
      );
      expect(
        state.resolveBinding('device.parameters.1_direction_command_2_trigger'),
        '01',
      );

      state.applyRemoteParameter('Display Log', true);
      state.ingestCloudPayload({
        'node_id': 'NODE1',
        'log': 'frame A1 06',
        'rpm': 310,
      }, nodeId: 'NODE1');

      expect(
        state.resolveBinding('device.parameters.3_display_command_0_console'),
        '> Speed=6\n> Direction=01\n> frame A1 06\n> rpm=310',
      );
    });

    test('response row takes the cloud reading and the console stays blank while the log is off', () {
      final response = List<Map<String, dynamic>>.generate(
        12,
        (index) => <String, dynamic>{'default_name': 'unused', 'value': '00'},
      );
      response[11] = <String, dynamic>{
        'default_name': 'rpm',
        'ui_type': 'Text',
        'value': '0136',
      };
      final state = AppState({
        'schemaVersion': '4.0.0',
        'state': {
          'device': {
            'parameters': {
              '3_command_get_status_response_11_text': 'OFF',
              '3_display_command_0_console': '00',
              '3_display_log_command_0_button': 'OFF',
              '1_power_command_2_toggle_switch': false,
            },
          },
        },
        'controls': [
          {
            'id': '3:command_get_status:command-3-button',
            'parameter': 'Command Get Status',
            'binding': 'device.parameters.3_command_get_status_command_3_button',
            'componentType': 'button',
            'valueType': 'trigger',
            'value': 'OFF',
            'deviceFrame': {
              'name': 'Command Get Status',
              'trigger_ui': [true, false, false],
              'response': response,
            },
          },
          {
            'id': '3:command_get_status:response-11-text',
            'parameter': 'Command Get Status',
            'label': 'Data',
            'value': 'OFF',
            'binding': 'device.parameters.3_command_get_status_response_11_text',
            'componentType': 'textField',
            'valueType': 'string',
            'deviceFrame': {
              'name': 'Command Get Status',
              'trigger_ui': [true, false, false],
              'response': response,
            },
          },
          {
            'id': '1:power:command-2-toggle-switch',
            'parameter': 'power',
            'binding': 'device.parameters.1_power_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
            'value': 'OFF',
          },
          {
            'id': '3:Display',
            'parameter': 'Display',
            'binding': 'device.parameters.3_display_command_0_console',
            'value': '00',
            'componentType': 'textField',
            'component': {
              'props': {
                'variant': 'terminal',
                'promptSymbol': '>',
              },
            },
          },
          {
            'id': '3:Display Log',
            'parameter': 'Display Log',
            'binding': 'device.parameters.3_display_log_command_0_button',
            'value': 'OFF',
            'componentType': 'button',
            'valueType': 'boolean',
          },
        ],
      });

      final row = state.controls.firstWhere(
        (control) => control['id'] == '3:command_get_status:response-11-text',
      );
      final console = state.controls.firstWhere(
        (control) => control['id'] == '3:Display',
      );
      final trigger = state.controls.firstWhere(
        (control) => control['id'] == '3:command_get_status:command-3-button',
      );

      expect(AppState.frameRevealsResponseRows(trigger), isTrue);
      expect(AppState.isResponseControl(row), isTrue);
      expect(state.presentedFieldText(row, 'OFF'), '');
      expect(state.presentedFieldText(console, '00'), '');

      state.ingestCloudPayload({
        'node_id': 'N',
        'rpm': 310,
        'power': true,
      }, nodeId: 'N');

      expect(
        state.resolveBinding(
          'device.parameters.3_command_get_status_response_11_text',
        ),
        '310',
      );
      expect(
        state.resolveBinding('device.parameters.1_power_command_2_toggle_switch'),
        true,
      );
      expect(state.presentedFieldText(row, '310'), '310');
      expect(state.presentedFieldText(console, '00'), '');

      state.applyRemoteParameter('Display Log', true);
      expect(
        state.presentedFieldText(
          console,
          state
              .resolveBinding('device.parameters.3_display_command_0_console')
              .toString(),
        ),
        contains('rpm=310'),
      );
    });

    test('multi-field tuning and remote pairing seed asperui and accept cloud field names', () {
      Map<String, dynamic> dataField(String name, dynamic asperui) => {
            'default_name': name,
            'Field_description': 'Data',
            'asperui_value': asperui,
            'ui_type': 'Text',
          };

      final tuningCommands = <Map<String, dynamic>>[
        {'default_name': 'CommandId', 'Field_description': 'Command'},
        {'default_name': 'Function Code', 'Field_description': 'Command'},
        dataField('Resistance', '2.300000'),
        dataField('Imin', '3.100000'),
        dataField('Imax', '3.500000'),
      ];
      final remoteCommands = <Map<String, dynamic>>[
        {'default_name': 'CommandId', 'Field_description': 'Command'},
        {'default_name': 'Function Code', 'Field_description': 'Command'},
        dataField('Remote Address', 5063168),
        dataField('Remote Power OFF', 0),
        dataField('Remote Power ON', 1),
      ];

      final state = AppState({
        'schemaVersion': '4.1.0',
        'state': {
          'device': {
            'parameters': {
              '2_tuning_command_2_text': 'Resistance',
              '2_tuning_command_3_text': 'Imin',
              '2_tuning_command_4_text': 'Imax',
              '4_remote_pairing_command_2_text': 'Remote Address',
              '4_remote_pairing_command_3_text': 'Remote Power OFF',
              '4_remote_pairing_command_4_text': 'Remote Power ON',
            },
          },
        },
        'controls': [
          {
            'id': '2:tuning:command-2-text',
            'parameter': 'tuning',
            'label': 'Data',
            'binding': 'device.parameters.2_tuning_command_2_text',
            'componentType': 'textField',
            'deviceFrame': {'name': 'tuning', 'commands': tuningCommands},
          },
          {
            'id': '2:tuning:command-3-text',
            'parameter': 'tuning',
            'label': 'Data',
            'binding': 'device.parameters.2_tuning_command_3_text',
            'componentType': 'textField',
            'deviceFrame': {'name': 'tuning', 'commands': tuningCommands},
          },
          {
            'id': '2:tuning:command-4-text',
            'parameter': 'tuning',
            'label': 'Data',
            'binding': 'device.parameters.2_tuning_command_4_text',
            'componentType': 'textField',
            'deviceFrame': {'name': 'tuning', 'commands': tuningCommands},
          },
          {
            'id': '4:remote_pairing:command-2-text',
            'parameter': 'Remote Pairing',
            'label': 'Data',
            'binding': 'device.parameters.4_remote_pairing_command_2_text',
            'componentType': 'textField',
            'deviceFrame': {
              'name': 'Remote Pairing',
              'commands': remoteCommands,
            },
          },
          {
            'id': '4:remote_pairing:command-3-text',
            'parameter': 'Remote Pairing',
            'label': 'Data',
            'binding': 'device.parameters.4_remote_pairing_command_3_text',
            'componentType': 'textField',
            'deviceFrame': {
              'name': 'Remote Pairing',
              'commands': remoteCommands,
            },
          },
          {
            'id': '4:remote_pairing:command-4-text',
            'parameter': 'Remote Pairing',
            'label': 'Data',
            'binding': 'device.parameters.4_remote_pairing_command_4_text',
            'componentType': 'textField',
            'deviceFrame': {
              'name': 'Remote Pairing',
              'commands': remoteCommands,
            },
          },
        ],
      });

      expect(
        state.resolveBinding('device.parameters.2_tuning_command_2_text'),
        '2.300000',
      );
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_3_text'),
        '3.100000',
      );
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_4_text'),
        '3.500000',
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_2_text',
          ),
          5063168,
        ),
        isTrue,
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_3_text',
          ),
          0,
        ),
        isTrue,
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_4_text',
          ),
          1,
        ),
        isTrue,
      );

      // Shared frame parameter must not overwrite every row.
      state.applyRemoteParameter('tuning', '99');
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_2_text'),
        '2.300000',
      );
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_3_text'),
        '3.100000',
      );

      state.applyRemoteParameter('Resistance', '2.75');
      state.applyRemoteParameter('Imin', '3.2');
      state.applyRemoteParameter('Remote Address', 5064000);
      state.applyRemoteParameter('Remote Power ON', 7);

      expect(
        state.resolveBinding('device.parameters.2_tuning_command_2_text'),
        '2.75',
      );
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_3_text'),
        '3.2',
      );
      expect(
        state.resolveBinding('device.parameters.2_tuning_command_4_text'),
        '3.500000',
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_2_text',
          ),
          5064000,
        ),
        isTrue,
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_4_text',
          ),
          7,
        ),
        isTrue,
      );

      // Real auto_get_nodes_params shape (nested under "" / device alias).
      state.ingestCloudPayload({
        'node_id': 'N1',
        'action': 'auto_get_nodes_params',
        '': {
          'Resistance': '2.9',
          'Remote_Address': 5065000,
          'Remote Power OFF': 2,
        },
      }, nodeId: 'N1');

      expect(
        state.resolveBinding('device.parameters.2_tuning_command_2_text'),
        '2.9',
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_2_text',
          ),
          5065000,
        ),
        isTrue,
      );
      expect(
        AppState.readingsAreEqual(
          state.resolveBinding(
            'device.parameters.4_remote_pairing_command_3_text',
          ),
          2,
        ),
        isTrue,
      );
    });

    test('multi-page structural replaceSchema preserves existing parameters from prior pages and seeds new controls', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'pages': [
          {'id': 'p1', 'title': 'Page 1'},
        ],
        'state': {
          'device': {
            'parameters': {'1_power': false},
          },
        },
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      });

      // Update Page 1 parameter via remote
      state.applyRemoteParameter('1_power', true);
      expect(state.resolveBinding('device.parameters.1_power'), true);

      // Now simulate merging Page 2 into the schema
      // In server schemas, state.device.parameters only has Page 1 parameters!
      state.replaceSchema({
        'schemaVersion': '4.1.0',
        'pages': [
          {'id': 'p1', 'title': 'Page 1'},
          {'id': 'p2', 'title': 'Page 2'},
        ],
        'state': {
          'device': {
            'parameters': {'1_power': false}, // Server snapshot has false/placeholder
          },
        },
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '2:power',
            'binding': 'device.parameters.2_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      }, preserveValues: true);

      // Page 1 power MUST still be true (not wiped by structural replace)
      expect(state.resolveBinding('device.parameters.1_power'), true);
      // Page 2 control was seeded
      expect(state.resolveBinding('device.parameters.2_power'), false);

      // Ingest Page 2 value
      state.applyRemoteParameter('2_power', true);
      expect(state.resolveBinding('device.parameters.2_power'), true);

      // Merge Page 3
      state.replaceSchema({
        'schemaVersion': '4.1.0',
        'pages': [
          {'id': 'p1', 'title': 'Page 1'},
          {'id': 'p2', 'title': 'Page 2'},
          {'id': 'p3', 'title': 'Page 3'},
        ],
        'state': {
          'device': {
            'parameters': {'1_power': false},
          },
        },
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '2:power',
            'binding': 'device.parameters.2_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '3:power',
            'binding': 'device.parameters.3_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      }, preserveValues: true);

      // Both Page 1 and Page 2 values must be preserved!
      expect(state.resolveBinding('device.parameters.1_power'), true);
      expect(state.resolveBinding('device.parameters.2_power'), true);
      expect(state.resolveBinding('device.parameters.3_power'), false);
    });

    test('unmatched telemetry for Page 2 buffers and auto-drains when Page 2 is merged', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'pages': [
          {'id': 'p1', 'title': 'Page 1'},
        ],
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      });

      // WebSocket delivers Page 2 readings before Page 2 schema is loaded
      state.ingestCloudPayload({
        'Voltage': 230,
        'Speed': 1400,
        'power_2': true,
      });

      // Page 2 was not in schema yet, so values are buffered
      expect(state.resolveBinding('device.parameters.2_power'), null);

      // Now Page 2 finishes loading and is merged into schema
      state.replaceSchema({
        'schemaVersion': '4.1.0',
        'pages': [
          {'id': 'p1', 'title': 'Page 1'},
          {'id': 'p2', 'title': 'Page 2'},
        ],
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '2:power_command_2_toggle_switch',
            'binding': 'device.parameters.2_power_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '2:response-0-Voltage (V)',
            'binding': 'device.parameters.2_voltage_response',
            'componentType': 'text',
            'valueType': 'string',
            'initialValue': '--',
            'deviceFrame': {
              'response': [
                {
                  'default_name': 'Voltage (V)',
                  'Field_description': 'Data',
                }
              ]
            }
          },
          {
            'id': '2:response-1-Speed',
            'binding': 'device.parameters.2_speed_response',
            'componentType': 'text',
            'valueType': 'number',
            'initialValue': 0,
            'deviceFrame': {
              'response': [
                {
                  'default_name': 'Speed (RPM)',
                  'Field_description': 'Data',
                }
              ]
            }
          },
        ],
      }, preserveValues: true);

      // replaceSchema auto-drained the buffer!
      expect(state.resolveBinding('device.parameters.2_power_command_2_toggle_switch'), true);
      expect(AppState.readingsAreEqual(state.resolveBinding('device.parameters.2_voltage_response'), 230), isTrue);
      expect(state.resolveBinding('device.parameters.2_speed_response'), 1400);
    });

    test('unit suffix normalization in aliases matches Voltage (V), Current (A), Power (W), Speed (RPM)', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'controls': [
          {
            'id': '2:response-0-Voltage (V)',
            'binding': 'device.parameters.2_voltage_read',
            'componentType': 'text',
            'valueType': 'number',
            'initialValue': 0,
            'deviceFrame': {
              'response': [
                {
                  'default_name': 'Voltage (V)',
                  'Field_description': 'Data',
                }
              ]
            }
          },
          {
            'id': '2:response-1-Current (A)',
            'binding': 'device.parameters.2_current_read',
            'componentType': 'text',
            'valueType': 'number',
            'initialValue': 0,
            'deviceFrame': {
              'response': [
                {
                  'default_name': 'Current (A)',
                  'Field_description': 'Data',
                }
              ]
            }
          },
          {
            'id': '2:response-2-Speed (RPM)',
            'binding': 'device.parameters.2_rpm_read',
            'componentType': 'text',
            'valueType': 'number',
            'initialValue': 0,
            'deviceFrame': {
              'response': [
                {
                  'default_name': 'Speed (RPM)',
                  'Field_description': 'Data',
                }
              ]
            }
          },
        ],
      });

      // Remote sends plain keys "voltage", "current", "rpm"
      state.ingestCloudPayload({
        'voltage': 228.5,
        'current': 1.45,
        'rpm': 1150,
      });

      expect(state.resolveBinding('device.parameters.2_voltage_read'), 228.5);
      expect(state.resolveBinding('device.parameters.2_current_read'), 1.45);
      expect(state.resolveBinding('device.parameters.2_rpm_read'), 1150);

      // Remote sends uppercase keys with unit "Voltage(V)", "Current (A)"
      state.ingestCloudPayload({
        'Voltage(V)': 235.0,
        'Current (A)': 2.1,
      });
      expect(state.resolveBinding('device.parameters.2_voltage_read'), 235.0);
      expect(state.resolveBinding('device.parameters.2_current_read'), 2.1);
    });

    test('multi-gang devices payload in all_nodes scopes power and switch across Page 1 and Page 2 without collision', () {
      final state = AppState({
        'schemaVersion': '4.1.0',
        'controls': [
          {
            'id': '1:power',
            'binding': 'device.parameters.1_power_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
          {
            'id': '2:power',
            'binding': 'device.parameters.2_power_command_2_toggle_switch',
            'componentType': 'switch',
            'valueType': 'boolean',
            'initialValue': false,
          },
        ],
      });

      // Cloud sends all_nodes containing devices array with page_name
      state.ingestCloudPayload({
        'all_nodes': [
          {
            'node_id': 'DEVICE_001',
            'config': {
              'devices': [
                {
                  'page_name': 'Page1.Operation',
                  'power': true,
                },
                {
                  'page_name': 'Page2.Operation',
                  'power': false,
                },
              ],
            },
          },
        ],
      }, nodeId: 'DEVICE_001');

      expect(state.resolveBinding('device.parameters.1_power_command_2_toggle_switch'), true);
      expect(state.resolveBinding('device.parameters.2_power_command_2_toggle_switch'), false);

      // Ingest channel-suffixed telemetry "switch_2: true"
      state.ingestCloudPayload({
        'switch_2': true,
        'switch_1': false,
      });
      expect(state.resolveBinding('device.parameters.2_power_command_2_toggle_switch'), true);
      expect(state.resolveBinding('device.parameters.1_power_command_2_toggle_switch'), false);
    });
  });
}
