import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  test('Multi-page telemetry retention and cross-page propagation', () {
    final p1Schema = {
      'id': 'page1',
      'name': 'Operation',
      'controls': [
        {
          'id': '1:power:command-2-toggle-switch',
          'binding': 'device.parameters.1_power_command_2_toggle_switch',
          'parameter': 'power',
          'value': 'OFF',
        },
        {
          'id': '1:Speed:command-2-slider',
          'binding': 'device.parameters.1_speed_command_2_slider',
          'parameter': 'Speed',
          'value': 1,
        },
        {
          'id': '1:rpm:command-0-text',
          'binding': 'device.parameters.1_rpm_command_0_text',
          'parameter': 'rpm',
          'value': 'rpm',
        },
        {
          'id': '1:Voltage:command-0-text',
          'binding': 'device.parameters.1_voltage_command_0_text',
          'parameter': 'Voltage',
          'value': 'Voltage',
        },
        {
          'id': '1:Current:command-0-text',
          'binding': 'device.parameters.1_current_command_0_text',
          'parameter': 'Current',
          'value': 'Current',
        },
      ],
      'state': {
        'device': {
          'parameters': {
            '1_power_command_2_toggle_switch': false,
            '1_speed_command_2_slider': 1,
            '1_rpm_command_0_text': 'rpm',
            '1_voltage_command_0_text': 'Voltage',
            '1_current_command_0_text': 'Current',
          }
        }
      }
    };

    final p3Schema = {
      'id': 'page3',
      'name': 'Status',
      'controls': [
        {
          'id': '3:command_get_status:response-3-text',
          'binding': 'device.parameters.3_command_get_status_response_3_text',
          'parameter': 'Command Get Status',
          'value': 'OFF',
          'deviceFrame': {
            'name': 'Command Get Status',
            'commands': [],
            'response': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'power', 'asperui_value': 'true'},
              {'default_name': 'Speed', 'asperui_value': '6'},
              {'default_name': 'Direction', 'asperui_value': '1'},
              {'default_name': 'rpm', 'asperui_value': '310'},
              {'default_name': 'Watt', 'asperui_value': '20.5'},
              {'default_name': 'Current', 'asperui_value': '1.2'},
              {'default_name': 'Voltage', 'asperui_value': '25.29'},
            ]
          }
        },
        {
          'id': '3:command_get_status:response-5-text',
          'binding': 'device.parameters.3_command_get_status_response_5_text',
          'parameter': 'Command Get Status',
          'value': 'OFF',
          'deviceFrame': {
            'name': 'Command Get Status',
            'commands': [],
            'response': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'power', 'asperui_value': 'true'},
              {'default_name': 'Speed', 'asperui_value': '6'},
              {'default_name': 'Direction', 'asperui_value': '1'},
              {'default_name': 'rpm', 'asperui_value': '310'},
              {'default_name': 'Watt', 'asperui_value': '20.5'},
              {'default_name': 'Current', 'asperui_value': '1.2'},
              {'default_name': 'Voltage', 'asperui_value': '25.29'},
            ]
          }
        },
        {
          'id': '3:command_get_status:response-7-text',
          'binding': 'device.parameters.3_command_get_status_response_7_text',
          'parameter': 'Command Get Status',
          'value': 'OFF',
          'deviceFrame': {
            'name': 'Command Get Status',
            'commands': [],
            'response': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'power', 'asperui_value': 'true'},
              {'default_name': 'Speed', 'asperui_value': '6'},
              {'default_name': 'Direction', 'asperui_value': '1'},
              {'default_name': 'rpm', 'asperui_value': '310'},
              {'default_name': 'Watt', 'asperui_value': '20.5'},
              {'default_name': 'Current', 'asperui_value': '1.2'},
              {'default_name': 'Voltage', 'asperui_value': '25.29'},
            ]
          }
        },
        {
          'id': '3:command_get_status:response-8-text',
          'binding': 'device.parameters.3_command_get_status_response_8_text',
          'parameter': 'Command Get Status',
          'value': 'OFF',
          'deviceFrame': {
            'name': 'Command Get Status',
            'commands': [],
            'response': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'power', 'asperui_value': 'true'},
              {'default_name': 'Speed', 'asperui_value': '6'},
              {'default_name': 'Direction', 'asperui_value': '1'},
              {'default_name': 'rpm', 'asperui_value': '310'},
              {'default_name': 'Watt', 'asperui_value': '20.5'},
              {'default_name': 'Current', 'asperui_value': '1.2'},
              {'default_name': 'Voltage', 'asperui_value': '25.29'},
            ]
          }
        },
      ],
      'state': {
        'device': {
          'parameters': {
            '3_command_get_status_response_3_text': 'OFF',
            '3_command_get_status_response_5_text': 'OFF',
            '3_command_get_status_response_7_text': 'OFF',
            '3_command_get_status_response_8_text': 'OFF',
          }
        }
      }
    };

    final state = AppState(p1Schema);

    // Ingest telemetry on Page 1
    state.ingestCloudPayload({
      'node_id': 'TEST_NODE',
      'action': 'auto_get_nodes_params',
      'fan_test': {
        'Speed': 4,
        'rpm': 236,
        'Current': 1.17,
        'Voltage': 25.35,
      }
    });

    // Check Page 1 bindings
    expect(state.resolveBinding('device.parameters.1_speed_command_2_slider').toString(), '4');
    expect(state.resolveBinding('device.parameters.1_rpm_command_0_text').toString(), '236');
    expect(state.resolveBinding('device.parameters.1_current_command_0_text').toString(), '1.17');
    expect(state.resolveBinding('device.parameters.1_voltage_command_0_text').toString(), '25.35');

    // Verify latest telemetry is preserved in cache
    expect(state.latestCloudTelemetry['Speed'], 4);
    expect(state.latestCloudTelemetry['rpm'], 236);
    expect(state.latestCloudTelemetry['Current'], 1.17);
    expect(state.latestCloudTelemetry['Voltage'], 25.35);

    // Now merge Page 3
    final merged = SchemaRepository.mergeDevicePageSchema(p1Schema, p3Schema);
    state.replaceSchema(merged, preserveValues: true, preservePage: true);

    // Assert that Page 3 controls are populated with live readings and NOT showing field names
    expect(state.resolveBinding('device.parameters.3_command_get_status_response_3_text').toString(), '4');
    expect(state.resolveBinding('device.parameters.3_command_get_status_response_5_text').toString(), '236');
    expect(state.resolveBinding('device.parameters.3_command_get_status_response_7_text').toString(), '1.17');
    expect(state.resolveBinding('device.parameters.3_command_get_status_response_8_text').toString(), '25.35');

    // Assert presentedFieldText displays live readings, never field names
    final speedCtrl = state.controlById('3:command_get_status:response-3-text')!;
    final rpmCtrl = state.controlById('3:command_get_status:response-5-text')!;
    final currentCtrl = state.controlById('3:command_get_status:response-7-text')!;
    final voltageCtrl = state.controlById('3:command_get_status:response-8-text')!;

    expect(state.presentedFieldText(speedCtrl, '4'), '4');
    expect(state.presentedFieldText(rpmCtrl, '236'), '236');
    expect(state.presentedFieldText(currentCtrl, '1.17'), '1.17');
    expect(state.presentedFieldText(voltageCtrl, '25.35'), '25.35');
  });

  test('Page 2 Tuning and multi-field parameter frame seeding rejects field name placeholders', () {
    final p2Schema = {
      'id': 'page2',
      'name': 'Configure.Config',
      'controls': [
        {
          'id': '2:tuning:command-2-text',
          'binding': 'device.parameters.2_tuning_command_2_text',
          'parameter': 'tuning',
          'value': '--',
          'deviceFrame': {
            'name': 'tuning',
            'commands': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'Resistance', 'asperui_value': '2.300000'},
              {'default_name': 'Imin', 'asperui_value': '3.100000'},
              {'default_name': 'Imax', 'asperui_value': '3.500000'},
              {'default_name': 'Frequence', 'asperui_value': '16000'},
              {'default_name': 'Speed1', 'asperui_value': '4'},
              {'default_name': 'Speed2', 'asperui_value': '7'},
            ],
            'response': []
          }
        },
        {
          'id': '2:tuning:command-3-text',
          'binding': 'device.parameters.2_tuning_command_3_text',
          'parameter': 'tuning',
          'value': '--',
          'deviceFrame': {
            'name': 'tuning',
            'commands': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'Resistance', 'asperui_value': '2.300000'},
              {'default_name': 'Imin', 'asperui_value': '3.100000'},
              {'default_name': 'Imax', 'asperui_value': '3.500000'},
              {'default_name': 'Frequence', 'asperui_value': '16000'},
              {'default_name': 'Speed1', 'asperui_value': '4'},
              {'default_name': 'Speed2', 'asperui_value': '7'},
            ],
            'response': []
          }
        },
        {
          'id': '2:tuning:command-6-text',
          'binding': 'device.parameters.2_tuning_command_6_text',
          'parameter': 'tuning',
          'value': '--',
          'deviceFrame': {
            'name': 'tuning',
            'commands': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'Resistance', 'asperui_value': '2.300000'},
              {'default_name': 'Imin', 'asperui_value': '3.100000'},
              {'default_name': 'Imax', 'asperui_value': '3.500000'},
              {'default_name': 'Frequence', 'asperui_value': '16000'},
              {'default_name': 'Speed1', 'asperui_value': '4'},
              {'default_name': 'Speed2', 'asperui_value': '7'},
            ],
            'response': []
          }
        },
      ],
      'state': {
        'device': {
          'parameters': {
            // Server snapshot contains field names as values
            '2_tuning_command_2_text': 'Speed1',
            '2_tuning_command_3_text': 'Speed2',
            '2_tuning_command_6_text': 'Resistance',
          }
        }
      }
    };

    final state = AppState(p2Schema);

    // Assert that "Speed1" and "Resistance" server snapshots were rejected in favor of true frame defaults
    expect(state.resolveBinding('device.parameters.2_tuning_command_2_text'), '2.300000');
    expect(state.resolveBinding('device.parameters.2_tuning_command_3_text'), '3.100000');
    expect(state.resolveBinding('device.parameters.2_tuning_command_6_text'), '4');

    final c2 = state.controlById('2:tuning:command-2-text')!;
    final c3 = state.controlById('2:tuning:command-3-text')!;
    final c6 = state.controlById('2:tuning:command-6-text')!;

    expect(state.presentedFieldText(c2, '2.300000'), '2.300000');
    expect(state.presentedFieldText(c3, '3.100000'), '3.100000');
    expect(state.presentedFieldText(c6, '4'), '4');
  });

  test('Page 4 Remote Pairing and Page 6 Mortgage reject field name placeholders', () {
    final p4Schema = {
      'id': 'page4',
      'name': 'Remote Pairing',
      'controls': [
        {
          'id': '4:remote_pairing:command-4-text',
          'binding': 'device.parameters.4_remote_pairing_command_4_text',
          'parameter': 'Remote Pairing',
          'value': 'Remote Key Speed 5',
          'deviceFrame': {
            'name': 'Remote Pairing',
            'commands': [
              {'default_name': 'CommandId'},
              {'default_name': 'Function Code'},
              {'default_name': 'Remote Address', 'asperui_value': '5063168'},
              {'default_name': 'Remote Power OFF', 'asperui_value': '0'},
              {'default_name': 'Remote Key Speed 5', 'asperui_value': '0'},
            ],
            'response': []
          }
        },
      ],
      'state': {
        'device': {
          'parameters': {
            '4_remote_pairing_command_4_text': 'Remote Key Speed 5',
          }
        }
      }
    };

    final state = AppState(p4Schema);
    expect(state.resolveBinding('device.parameters.4_remote_pairing_command_4_text'), '0');

    final c4 = state.controlById('4:remote_pairing:command-4-text')!;
    expect(state.presentedFieldText(c4, '0'), '0');
  });

  test('Multi-page schema with nested pages seeds Page 2 Tuning controls and supports offset command IDs', () {
    final multiPageSchema = {
      'pages': [
        {
          'id': 'page1',
          'name': 'Operation',
          'controls': [
            {
              'id': '1:power:command-2-toggle-switch',
              'binding': 'device.parameters.1_power_command_2_toggle_switch',
              'parameter': 'power',
              'value': 'OFF',
            }
          ]
        },
        {
          'id': 'page2',
          'name': 'Configure.Config',
          'controls': [
            {
              'id': '2:tuning:command-2-text',
              'binding': 'device.parameters.2_tuning_command_2_text',
              'parameter': 'tuning',
              'label': 'Data',
              'componentType': 'textField',
              'value': '--',
              'deviceFrame': {
                'name': 'tuning',
                'commands': [
                  {'default_name': 'CommandId', 'val': 'A1'},
                  {'default_name': 'Function Code', 'val': 'F7'},
                  {'default_name': 'Resistance', 'asperui_value': '2.300000', 'val': '40133333'},
                  {'default_name': 'Imin', 'asperui_value': '3.100000', 'val': '40466666'},
                  {'default_name': 'Imax', 'asperui_value': '3.500000', 'val': '40600000'},
                  {'default_name': 'Frequence', 'asperui_value': '16000', 'val': '00003E80'},
                  {'default_name': 'PolePairs', 'asperui_value': '8', 'val': '08'},
                  {'default_name': 'Open_Loop_Current', 'asperui_value': '1.500000', 'val': '3FC00000'},
                  {'default_name': 'PowerLimit', 'asperui_value': '44', 'val': '2C'},
                  {'default_name': 'TorqueLimit', 'asperui_value': '7000', 'val': '00001B58'},
                  {'default_name': 'Speed1', 'asperui_value': '4', 'val': '04'},
                  {'default_name': 'Speed2', 'asperui_value': '7', 'val': '07'},
                  {'default_name': 'Speed3', 'asperui_value': '11', 'val': '0B'},
                  {'default_name': 'Speed4', 'asperui_value': '17', 'val': '11'},
                  {'default_name': 'Speed5', 'asperui_value': '23', 'val': '17'},
                  {'default_name': 'Speed6', 'asperui_value': '26', 'val': '1A'},
                  {'default_name': 'Speed7', 'asperui_value': '27', 'val': '1B'},
                  {'default_name': 'Terminator', 'val': '0A'},
                  {'default_name': 'Trigger', 'asperui_value': 'OK', 'val': 'OK'},
                ],
                'response': [
                  {'default_name': 'Array'}
                ]
              }
            },
            {
              // Offset ID: 21 where frame commands length is 19 (21 % 19 = 2 -> Resistance)
              'id': '2:tuning:command-21-text',
              'binding': 'device.parameters.2_tuning_command_21_text',
              'parameter': 'tuning',
              'label': 'Data',
              'componentType': 'textField',
              'value': '--',
              'deviceFrame': {
                'name': 'tuning',
                'commands': [
                  {'default_name': 'CommandId', 'val': 'A1'},
                  {'default_name': 'Function Code', 'val': 'F7'},
                  {'default_name': 'Resistance', 'asperui_value': '2.300000', 'val': '40133333'},
                  {'default_name': 'Imin', 'asperui_value': '3.100000', 'val': '40466666'},
                  {'default_name': 'Imax', 'asperui_value': '3.500000', 'val': '40600000'},
                  {'default_name': 'Frequence', 'asperui_value': '16000', 'val': '00003E80'},
                  {'default_name': 'PolePairs', 'asperui_value': '8', 'val': '08'},
                  {'default_name': 'Open_Loop_Current', 'asperui_value': '1.500000', 'val': '3FC00000'},
                  {'default_name': 'PowerLimit', 'asperui_value': '44', 'val': '2C'},
                  {'default_name': 'TorqueLimit', 'asperui_value': '7000', 'val': '00001B58'},
                  {'default_name': 'Speed1', 'asperui_value': '4', 'val': '04'},
                  {'default_name': 'Speed2', 'asperui_value': '7', 'val': '07'},
                  {'default_name': 'Speed3', 'asperui_value': '11', 'val': '0B'},
                  {'default_name': 'Speed4', 'asperui_value': '17', 'val': '11'},
                  {'default_name': 'Speed5', 'asperui_value': '23', 'val': '17'},
                  {'default_name': 'Speed6', 'asperui_value': '26', 'val': '1A'},
                  {'default_name': 'Speed7', 'asperui_value': '27', 'val': '1B'},
                  {'default_name': 'Terminator', 'val': '0A'},
                  {'default_name': 'Trigger', 'asperui_value': 'OK', 'val': 'OK'},
                ],
                'response': []
              }
            },
            {
              // Command field with 'val' instead of 'asperui_value'
              'id': '2:tuning:command-5-text',
              'binding': 'device.parameters.2_tuning_command_5_text',
              'parameter': 'tuning',
              'label': 'Data',
              'componentType': 'textField',
              'value': '--',
              'deviceFrame': {
                'name': 'tuning',
                'commands': [
                  {'default_name': 'CommandId'},
                  {'default_name': 'Function Code'},
                  {'default_name': 'Resistance'},
                  {'default_name': 'Imin'},
                  {'default_name': 'Imax'},
                  {'default_name': 'Frequence', 'val': '16000'},
                ]
              }
            }
          ]
        }
      ],
      'state': {
        'device': {
          'parameters': {
            '2_tuning_command_2_text': '--',
            '2_tuning_command_21_text': '--',
            '2_tuning_command_5_text': '--',
          }
        }
      }
    };

    final state = AppState(multiPageSchema);

    // Verify all Page 2 controls are registered in state.controls
    expect(state.controls.any((c) => c['id'] == '2:tuning:command-2-text'), isTrue);
    expect(state.controls.any((c) => c['id'] == '2:tuning:command-21-text'), isTrue);
    expect(state.controls.any((c) => c['id'] == '2:tuning:command-5-text'), isTrue);

    // Verify bindings were correctly seeded with real data values from frames
    expect(state.resolveBinding('device.parameters.2_tuning_command_2_text'), '2.300000');
    expect(state.resolveBinding('device.parameters.2_tuning_command_21_text'), '2.300000');
    expect(state.resolveBinding('device.parameters.2_tuning_command_5_text'), '16000');

    // Verify presentedFieldText displays data values rather than empty strings
    final c2 = state.controlById('2:tuning:command-2-text')!;
    final c21 = state.controlById('2:tuning:command-21-text')!;
    final c5 = state.controlById('2:tuning:command-5-text')!;

    expect(state.presentedFieldText(c2, '--'), '2.300000');
    expect(state.presentedFieldText(c21, '--'), '2.300000');
    expect(state.presentedFieldText(c5, '--'), '16000');
  });
}
