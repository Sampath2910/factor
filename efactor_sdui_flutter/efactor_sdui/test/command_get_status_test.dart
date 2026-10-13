import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/services/device_frame_builder.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/parameter_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    {'default_name': 'Current', 'ui_type': 'Text'},
    {'default_name': 'Voltage', 'ui_type': 'Text'},
    {'default_name': 'vacrms', 'ui_type': 'Text'},
    {'default_name': 'PowerFactor', 'ui_type': 'Text'},
    {'default_name': 'Energy', 'ui_type': 'Text'},
    {'default_name': 'Frequency', 'ui_type': 'Text'},
    {'default_name': 'Temperature', 'ui_type': 'Text'},
  ];

  final triggerControl = <String, dynamic>{
    'id': '3:command_get_status:command-3-button',
    'parameter': 'Command Get Status',
    'binding': 'device.parameters.3_command_get_status_command_3_button',
    'revealBinding': 'state.getStatusResponse.3_command_get_status.open',
    'componentType': 'button',
    'valueType': 'trigger',
    'value': 'OFF',
    'deviceFrame': {
      'name': 'Command Get Status',
      'trigger_ui': [true, false, false],
      'commands': [
        {
          'Field_description': 'CommandId',
          'default_name': 'CommandId',
          'value': 'A1',
          'byte_start_position': 1,
          'no_of_bytes': 1,
        },
        {
          'Field_description': 'Function code',
          'default_name': 'Function code',
          'value': 'E7',
          'byte_start_position': 2,
          'no_of_bytes': 1,
        },
        {
          'Field_description': 'Terminator',
          'default_name': 'Terminator',
          'value': '0A',
          'byte_start_position': 3,
          'no_of_bytes': 1,
        },
        {
          'Field_description': 'Trigger',
          'default_name': 'Trigger',
          'value': '',
          'byte_start_position': 0,
          'no_of_bytes': 0,
          'type': 'Trigger',
        },
      ],
      'response': responseDefinitions,
    },
  };

  final allControls = <Map<String, dynamic>>[
    triggerControl,
    for (var i = 0; i < responseDefinitions.length; i++)
      <String, dynamic>{
        'id': '3:command_get_status:response-$i-text',
        'parameter': 'Command Get Status',
        'binding': 'device.parameters.3_command_get_status_response_${i}_text',
        'componentType': i == 0 ? 'switch' : 'textField',
        'value': 'OFF',
        'deviceFrame': {
          'name': 'Command Get Status',
          'trigger_ui': [true, false, false],
          'response': responseDefinitions,
        },
      },
  ];

  group('Command Get Status Fixes', () {
    test('DeviceFrameBuilder compiles A1E70A ignoring non-payload trigger slot', () {
      final result = DeviceFrameBuilder.build(
        control: triggerControl,
        runtimeValue: 'ON',
      );

      expect(result.ok, isTrue, reason: result.error);
      expect(result.frameHex, 'A1E70A');
      expect(result.numericValue, 1.0);
    });

    test('Response row labels display their respective default_name', () {
      final appState = AppState(<String, dynamic>{
        'controls': allControls,
      });

      // Verify that AppState.responseFieldFor returns the correct response definition
      for (var i = 0; i < responseDefinitions.length; i++) {
        final row = allControls[i + 1];
        final respField = AppState.responseFieldFor(row);
        expect(respField, isNotNull);
        expect(respField?['default_name'], responseDefinitions[i]['default_name']);

        final card = ParameterCard(
          control: row,
          state: appState,
          embedded: true,
        );
        final label = card.resolvedFieldLabel(row, null);
        expect(label, responseDefinitions[i]['default_name']);
      }

      appState.dispose();
    });

    testWidgets('Tapping the trigger button toggles accordion between 1 and 17 controls even in Offline mode', (tester) async {
      final appState = AppState(<String, dynamic>{
        '_clientConnection': {
          'modelId': 'M1',
          'nodeId': 'N1',
        },
        'state': {
          'online': false,
        },
        'controls': allControls,
        'theme': {
          'colors': {
            'cardBackground': '#FFFFFF',
            'cardBorder': '#E2E8F0',
            'textPrimary': '#1E293B',
            'accent': '#3B82F6',
            'accentEnd': '#2563EB',
            'chipBackground': '#F1F5F9',
            'chipText': '#64748B',
          },
          'radius': {'card': 12},
          'borders': {'size': 1},
          'spacing': {'cardPadding': 16},
          'typography': {
            'bodySize': 14,
            'bodyWeight': 600,
          },
          'metaChip': {
            'height': 24,
            'minWidth': 40,
            'paddingHorizontal': 8,
            'fontSize': 11,
            'fontWeight': 600,
          },
        },
        'extensions': {
          'universalUi': {
            'designSystem': {
              'componentStyles': {
                'parameterCard': {
                  'parts': {
                    'label': {'uppercase': true},
                    'metaChip': {
                      'height': 24,
                      'minWidth': 40,
                      'paddingHorizontal': 8,
                      'fontSize': 11,
                      'fontWeight': 600,
                    },
                  },
                },
              },
            },
          },
        },
      });

      // Initially offline, device parameter is OFF, revealBinding is null/false
      expect(appState.resolveBinding('device.parameters.3_command_get_status_command_3_button'), 'OFF');

      final renderer = SduiRenderer(appState);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: renderer.renderControlGroup(
                controls: allControls,
                embedded: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially collapsed: Only the trigger button row is rendered (1 parameterCard)
      expect(find.text('COMMAND GET STATUS'), findsWidgets);
      // Response rows (Speed, Direction, etc.) should not be visible when collapsed
      expect(find.text('Speed'), findsNothing);
      expect(find.text('Direction'), findsNothing);
      expect(find.text('Voltage'), findsNothing);

      // Tap to expand (toggling trigger to ON)
      appState.setBinding('device.parameters.3_command_get_status_command_3_button', 'ON');
      await tester.pumpAndSettle();


      // Now expanded: All 16 response fields are rendered
      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('Direction'), findsOneWidget);
      expect(find.text('Buzzer'), findsOneWidget);
      expect(find.text('Voltage'), findsOneWidget);

      // Verify that sendBinding in offline mode does NOT roll back or collapse accordion
      await appState.sendBinding('device.parameters.3_command_get_status_command_3_button');
      await tester.pumpAndSettle();

      // Still expanded!
      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('Voltage'), findsOneWidget);

      // Tap again to collapse (toggling trigger to OFF)
      appState.setBinding('device.parameters.3_command_get_status_command_3_button', 'OFF');
      await tester.pumpAndSettle();

      // Collapsed again!
      expect(find.text('Speed'), findsNothing);
      expect(find.text('Voltage'), findsNothing);

      appState.dispose();
    });
  });
}
