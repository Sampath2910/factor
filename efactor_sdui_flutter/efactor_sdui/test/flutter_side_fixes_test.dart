import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/sdui/component_registry.dart';
import 'package:efactor_sdui/sdui/parameter_card.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/schema_guard.dart';
import 'package:efactor_sdui/sdui/style.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testTheme = <String, dynamic>{
    'theme': {
      'colors': {
        'cardBackground': '#FFFFFF',
        'cardBorder': '#E2E8F0',
        'textPrimary': '#1E293B',
        'text': '#1E293B',
        'surface': '#FFFFFF',
        'border': '#E2E8F0',
        'accent': '#3B82F6',
        'accentEnd': '#2563EB',
        'chipBackground': '#F1F5F9',
        'chipText': '#64748B',
      },
      'radius': {'card': 12, 'button': 8},
      'borders': {'size': 1},
      'spacing': {'cardPadding': 16},
      'typography': {
        'bodySize': 14,
        'bodyWeight': 600,
        'fontFamily': 'Poppins',
      },
      'shadows': {
        'card': {
          'color': '#00000010',
          'offset': {'x': 0, 'y': 2},
          'blur': 4,
        },
      },
    },
  };

  group('Flutter Side Fixes Tests', () {
    test('AppState.resolveControlDisplayName resolves fields when default_name is Data', () {
      final control = <String, dynamic>{
        'id': '3:command_get_status:response-2-text',
        'parameter': 'Command Get Status',
        'binding': 'device.parameters.3_command_get_status_response_2_text',
        'componentType': 'textField',
        'value': 'OFF',
        'deviceFrame': {
          'name': 'Command Get Status',
          'response': [
            {'default_name': 'CommandId', 'ui_type': 'Text'},
            {'default_name': 'Function Code', 'ui_type': 'Text'},
            {'default_name': 'Data', 'value': 'Speed', 'ui_type': 'Text'},
          ],
        },
      };

      final name = AppState.resolveControlDisplayName(control);
      expect(name, 'Speed');
    });

    test('AppState._appendLiveSnapshotToConsole appends command get status fields', () {
      final controls = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': '3:display_log:button',
          'parameter': 'Display Log',
          'binding': 'device.parameters.display_log',
          'value': 'OFF',
        },
        <String, dynamic>{
          'id': '3:display:console',
          'parameter': 'Display',
          'binding': 'device.parameters.display_console',
          'value': '',
          'component': {
            'props': {
              'variant': 'terminal',
            },
          },
        },
        <String, dynamic>{
          'id': '3:command_get_status:response-0-speed',
          'parameter': 'Command Get Status',
          'binding': 'device.parameters.speed_reading',
          'componentType': 'textField',
          'value': '',
          'deviceFrame': {
            'name': 'Command Get Status',
            'response': [
              {'default_name': 'Data', 'value': 'Speed', 'ui_type': 'Text'},
            ],
          },
        },
        <String, dynamic>{
          'id': '3:command_get_status:response-0-voltage',
          'parameter': 'Command Get Status',
          'binding': 'device.parameters.voltage_reading',
          'componentType': 'textField',
          'value': '',
          'deviceFrame': {
            'name': 'Command Get Status',
            'response': [
              {'default_name': 'Data', 'value': 'Voltage', 'ui_type': 'Text'},
            ],
          },
        },
      ];

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': controls,
      });

      // Set readings
      state.setBinding('device.parameters.speed_reading', '6', dispatch: false);
      state.setBinding('device.parameters.voltage_reading', '230', dispatch: false);

      // Turn on log gate
      state.setBinding('device.parameters.display_log', 'ON');

      final consoleOutput = state.resolveBinding('device.parameters.display_console')?.toString() ?? '';
      expect(consoleOutput, contains('Speed=6'));
      expect(consoleOutput, contains('Voltage=230'));

      state.dispose();
    });

    testWidgets('ParameterCard terminal console does not leak displayValue onto card header', (tester) async {
      final terminalControl = <String, dynamic>{
        'id': '3:display:console',
        'parameter': 'Display',
        'fieldLabel': 'Terminal Console',
        'icon': 'terminal',
        'binding': 'device.parameters.display_console',
        'componentType': 'textField',
        'component': {
          'props': {
            'variant': 'terminal',
            'textColor': '#00FF00',
            'borderColor': '#333333',
            'focusedBorderColor': '#00FF00',
            'borderRadius': 8,
            'horizontalPadding': 12,
            'verticalPadding': 8,
            'readOnly': true,
          },
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [terminalControl],
      });

      state.setBinding(
        'device.parameters.display_console',
        'Speed 6\nDirection 0\nVoltage 230',
        dispatch: false,
      );

      final card = ParameterCard(
        control: terminalControl,
        state: state,
        embedded: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: card,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In embedded mode, the caption is displayed
      expect(find.text('Terminal Console'), findsOneWidget);

      // The multi-line displayValue should NOT be rendered in the header as a standalone Text widget!
      final textWidgets = tester.widgetList<Text>(find.byType(Text)).toList();
      final headerLeaks = textWidgets.where((w) => w.data == 'Speed 6\nDirection 0\nVoltage 230').toList();
      expect(headerLeaks, isEmpty, reason: 'Console log text leaked into a header Text widget');

      // Check that TextField inside terminal has expands: true and AlwaysScrollableScrollPhysics
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.expands, isTrue);
      expect(textField.scrollPhysics, isA<AlwaysScrollableScrollPhysics>());

      state.dispose();
    });

    testWidgets('Send button on textfield is clickable and has active onTap', (tester) async {
      final sendControl = <String, dynamic>{
        'id': '3:send_data:command-0-enter-text',
        'parameter': 'Send Data',
        'binding': 'device.parameters.send_data_input',
        'componentType': 'textField',
        'component': {
          'props': {
            'textColor': '#111827',
            'borderColor': '#E5E7EB',
            'focusedBorderColor': '#3B82F6',
            'borderRadius': 8,
            'horizontalPadding': 12,
            'verticalPadding': 8,
            'sendButton': {
              'icon': 'send',
              'size': 40,
              'borderRadius': 8,
              'iconSize': 20,
              'backgroundColor': '#3B82F6',
              'iconColor': '#FFFFFF',
              'action': {
                'type': 'send',
                'binding': 'device.parameters.send_data_input',
              },
            },
          },
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [sendControl],
      });

      final renderer = SduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ComponentRegistry.instance.build(
                context: context,
                node: <String, dynamic>{
                  'type': 'textField',
                  'properties': <String, dynamic>{
                    'binding': 'device.parameters.send_data_input',
                    'props': sendControl['component']['props'],
                  },
                },
                props: <String, dynamic>{
                  'binding': 'device.parameters.send_data_input',
                  ...Map<String, dynamic>.from(sendControl['component']['props'] as Map),
                },
                style: SduiStyle(const {}),
                children: const [],
                state: state,
                renderer: renderer,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final allInkWells = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
      expect(allInkWells.isNotEmpty, isTrue);
      final activeInkWells = allInkWells.where((w) => w.onTap != null).toList();
      expect(activeInkWells.isNotEmpty, isTrue, reason: 'Send button InkWell should have an active onTap handler');

      state.dispose();
    });

    testWidgets('Single-page model displays page button 1 and progress bar', (tester) async {
      final singlePageSchema = <String, dynamic>{
        'version': '4.0.0',
        ...testTheme,
        'pages': [
          {'id': 'page_1', 'pageNo': '1', 'title': 'Page1.Operation'},
        ],
        'controls': [
          {
            'id': 'ctrl_1',
            'type': 'text',
            'properties': {'text': 'Single Page Control'},
          }
        ],
        'state': {
          'activePageIndex': 0,
          'device': {'parameters': {}},
        },
        'ui': {
          'type': 'column',
          'children': [
            {
              'id': 'progress_bar',
              'type': 'progress',
              'properties': {'binding': 'state.pageProgress'},
              'style': {
                'trackColor': '#E2E8F0',
                'height': 4,
                'fill': {
                  'fallbackColor': '#3B82F6',
                },
              },
            },
            {
              'id': 'page_buttons',
              'type': 'listView',
              'properties': {'scrollDirection': 'horizontal'},
              'children': [
                {
                  'id': 'page_button_0',
                  'type': 'button',
                  'properties': {
                    'events': [
                      {
                        'event': 'onTap',
                        'action': {
                          'type': 'update',
                          'value': 'activePageIndex=0',
                        },
                      }
                    ],
                  },
                  'children': [
                    {
                      'id': 'page_text_1',
                      'type': 'text',
                      'properties': {'text': '1'},
                    }
                  ],
                },
              ],
            },
          ],
        },
      };

      final state = AppState(singlePageSchema);
      expect(state.pages.length, 1);

      final renderer = SduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.build(context, singlePageSchema['ui']),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Page button 1 should be visible
      expect(find.text('1'), findsOneWidget, reason: 'Page button 1 must be rendered for single-page models');

      // Progress bar should be visible
      expect(find.byKey(const ValueKey<String>('page-progress-0-1')), findsOneWidget, reason: 'Progress bar must be rendered for single-page models');

      state.dispose();
    });

    testWidgets('Direction control resolves Clockwise and Anti-clockwise buttons with icons and header value 00 instead of [0][1]', (tester) async {
      final directionControl = <String, dynamic>{
        'id': '1:direction:command-2-trigger',
        'parameter': 'Direction',
        'fieldLabel': 'Direction',
        'icon': 'rotate_right',
        'binding': 'device.parameters.1_direction_command_2_trigger',
        'componentType': 'segmented',
        'value': '00',
        'component': {
          'type': 'segmented',
          'widgetTree': {
            'type': 'SegmentedControl',
            'properties': {
              'binding': 'device.parameters.1_direction_command_2_trigger',
              'props': {
                'options': [
                  {'label': 'Clockwise', 'value': '00'},
                  {'label': 'Anti-clockwise', 'value': '01'},
                ],
                'value': '00',
              },
            },
          },
          'props': {
            'options': [
              {'label': '[0][1]', 'value': '[08][08]'},
            ],
            'value': '00',
          },
          'options': [
            {'label': '[0][1]', 'value': '[08][08]'},
          ],
        },
        'props': {
          'options': [
            {'label': 'Clockwise', 'value': '00'},
            {'label': 'Anti-clockwise', 'value': '01'},
          ],
          'value': '00',
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [directionControl],
      });
      state.setBinding('device.parameters.1_direction_command_2_trigger', '00', dispatch: false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ParameterCard(
                control: directionControl,
                state: state,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Human readable buttons should be rendered
      expect(find.text('Clockwise'), findsOneWidget);
      expect(find.text('Anti-clockwise'), findsOneWidget);

      // Raw bracket code [0][1] must NOT be rendered
      expect(find.text('[0][1]'), findsNothing);

      // Header value 00 should be visible
      expect(find.text('00'), findsOneWidget);

      // Rotate icons should be present
      expect(find.byIcon(Icons.rotate_right), findsOneWidget);
      expect(find.byIcon(Icons.rotate_left), findsOneWidget);

      state.dispose();
    });

    testWidgets('Direction segmented buttons do not overflow in narrow 2-column mobile card (width: 140px)', (tester) async {
      final directionControl = <String, dynamic>{
        'id': '1:direction:command-2-trigger',
        'parameter': 'Direction',
        'fieldLabel': 'Direction',
        'icon': 'rotate_right',
        'binding': 'device.parameters.1_direction_command_2_trigger',
        'componentType': 'segmented',
        'value': '01',
        'component': {
          'type': 'segmented',
          'widgetTree': {
            'type': 'SegmentedControl',
            'properties': {
              'binding': 'device.parameters.1_direction_command_2_trigger',
              'props': {
                'options': [
                  {'label': 'Clockwise', 'value': '00'},
                  {'label': 'Anti-clockwise', 'value': '01'},
                ],
                'value': '01',
              },
            },
          },
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [directionControl],
      });
      state.setBinding('device.parameters.1_direction_command_2_trigger', '01', dispatch: false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140.0, // Tight half-screen card width
                child: ParameterCard(
                  control: directionControl,
                  state: state,
                  embedded: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify that no exceptions or overflows occurred during layout
      expect(tester.takeException(), isNull);
      expect(find.text('Clockwise'), findsOneWidget);
      expect(find.text('Anti-clockwise'), findsOneWidget);

      state.dispose();
    });

    test('DisplayLog does not overwrite toggle button value with log text and appends to terminal console', () {
      final controls = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': '3:display_log:button',
          'parameter': 'Display Log',
          'binding': 'device.parameters.3_display_log_command_0_button',
          'value': 'OFF',
          'componentType': 'button',
          'displayValue': 'OFF',
        },
        <String, dynamic>{
          'id': '3:display:console',
          'parameter': 'Display',
          'binding': 'device.parameters.3_display_command_0_console',
          'value': '',
          'componentType': 'textField',
          'component': {
            'props': {
              'variant': 'terminal',
            },
          },
        },
      ];

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': controls,
      });

      // Turn on log gate
      state.setBinding('device.parameters.3_display_log_command_0_button', 'ON', dispatch: false);

      // Telemetry arrives with DisplayLog key containing log dump
      state.applyRemoteParameter('DisplayLog', 'power: 1,Speed: 6,Direction: 00');

      // The log gate button value must NOT be corrupted by the log string
      final buttonVal = state.resolveBinding('device.parameters.3_display_log_command_0_button');
      expect(buttonVal, isNot(contains('power: 1')));
      expect(buttonVal, true);

      // The log dump must be routed to the console
      final consoleOutput = state.resolveBinding('device.parameters.3_display_command_0_console')?.toString() ?? '';
      expect(consoleOutput, contains('power: 1,Speed: 6,Direction: 00'));

      state.dispose();
    });

    testWidgets('Slider with missing inactiveColor and range falls back gracefully without red schema error', (tester) async {
      final malformedSliderControl = <String, dynamic>{
        'id': '5:remote_address:response-3-slider',
        'parameter': 'Speed',
        'binding': 'device.parameters.5_remote_address_response_3_slider',
        'componentType': 'slider',
        'value': '1',
        'props': {
          'hintText': 'Remote Address',
          'readOnly': true,
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [malformedSliderControl],
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ParameterCard(
                control: malformedSliderControl,
                state: state,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should not throw red schema issue widget
      expect(find.byType(SchemaIssueWidget), findsNothing);
      expect(find.byType(Slider), findsOneWidget);

      state.dispose();
    });

    test('AppState.extractBracketTokens extracts discrete items from concatenated bracket strings', () {
      final tokens = AppState.extractBracketTokens('[OFF][WHITE][RED][GREEN][BLUE]');
      expect(tokens, ['OFF', 'WHITE', 'RED', 'GREEN', 'BLUE']);

      final numTokens = AppState.extractBracketTokens('[00][01][02][03][04]');
      expect(numTokens, ['00', '01', '02', '03', '04']);

      final singleToken = AppState.extractBracketTokens('[16Amps]');
      expect(singleToken, ['16Amps']);
    });

    test('AppState.normalizeEnumOptions parses bracket maps into discrete label/value option maps', () {
      final rawList = [
        {'label': '[OFF][WHITE][RED][GREEN][BLUE]', 'value': '[00][01][02][03][04]'}
      ];
      final options = AppState.normalizeEnumOptions(rawList);
      expect(options.length, 5);
      expect(options[0], {'label': 'OFF', 'value': '00'});
      expect(options[1], {'label': 'WHITE', 'value': '01'});
      expect(options[2], {'label': 'RED', 'value': '02'});
      expect(options[3], {'label': 'GREEN', 'value': '03'});
      expect(options[4], {'label': 'BLUE', 'value': '04'});
    });

    test('AppState.optionsFor resolves clean options from protocolMeta items and deviceFrame asperui', () {
      final controlWithMeta = <String, dynamic>{
        'id': '3:led_color:drop-down',
        'binding': 'device.parameters.led_color',
        'protocolMeta': {
          'items': ['[OFF][WHITE][RED][GREEN][BLUE]'],
          'sno_asperui': ['[00][01][02][03][04]'],
        },
      };
      final options = AppState.optionsFor(controlWithMeta);
      expect(options.length, 5);
      expect(options.map((o) => o['label']).toList(), ['OFF', 'WHITE', 'RED', 'GREEN', 'BLUE']);
      expect(options.map((o) => o['value']).toList(), ['00', '01', '02', '03', '04']);
    });

    testWidgets('Dropdown with raw bracket options renders Choose hint and discrete popup items without raw text', (tester) async {
      final dropdownControl = <String, dynamic>{
        'id': '3:led_on_colour:command-2-drop-down',
        'parameter': 'LED ON Colour',
        'label': 'LED ON Colour',
        'binding': 'device.parameters.led_on_colour',
        'componentType': 'dropdown',
        'value': '',
        'initialValue': '',
        'props': {
          'options': [
            {'label': '[OFF][WHITE][RED][GREEN][BLUE]', 'value': '[00][01][02][03][04]'}
          ],
          'hint': 'Choose',
        },
      };

      final state = AppState(<String, dynamic>{
        ...testTheme,
        'controls': [dropdownControl],
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ParameterCard(
                control: dropdownControl,
                state: state,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Raw concatenated bracket string must never be displayed as text
      expect(find.text('[OFF][WHITE][RED][GREEN][BLUE]'), findsNothing);
      expect(find.textContaining('[OFF][WHITE]'), findsNothing);

      // 'Choose' hint must be displayed
      expect(find.text('Choose'), findsOneWidget);

      // Open the dropdown
      await tester.tap(find.byType(DropdownButton<dynamic>), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Discrete items must be visible in the popup
      expect(find.text('OFF'), findsOneWidget);
      expect(find.text('WHITE'), findsOneWidget);
      expect(find.text('RED'), findsOneWidget);
      expect(find.text('GREEN'), findsOneWidget);
      expect(find.text('BLUE'), findsOneWidget);

      // Select 'RED'
      await tester.tap(find.text('RED').last);
      await tester.pumpAndSettle();

      // Selected value must update the state binding to '02'
      expect(state.resolveBinding('device.parameters.led_on_colour'), '02');

      state.dispose();
    });

    test('Dropdown options parser handles arbitrary different models and parameters without hardcoding', () {
      // Model A: Current rating dropdown
      final ampsControl = <String, dynamic>{
        'id': 'model_amps',
        'binding': 'device.parameters.amps',
        'props': {
          'options': [
            {'label': '[10Amps][16Amps][32Amps]', 'value': '[00][01][02]'}
          ]
        }
      };
      final ampsOpts = AppState.optionsFor(ampsControl);
      expect(ampsOpts.length, 3);
      expect(ampsOpts[0], {'label': '10Amps', 'value': '00'});
      expect(ampsOpts[1], {'label': '16Amps', 'value': '01'});
      expect(ampsOpts[2], {'label': '32Amps', 'value': '02'});

      // Model B: HVAC 5-speed fan mode
      final fanControl = <String, dynamic>{
        'id': 'fan_mode',
        'binding': 'device.parameters.fan_mode',
        'protocolMeta': {
          'items': ['[Silent][Low][Medium][High][Turbo]'],
          'item_values': ['[00][01][02][03][04]'],
        }
      };
      final fanOpts = AppState.optionsFor(fanControl);
      expect(fanOpts.length, 5);
      expect(fanOpts.map((o) => o['label']).toList(), ['Silent', 'Low', 'Medium', 'High', 'Turbo']);
      expect(fanOpts.map((o) => o['value']).toList(), ['00', '01', '02', '03', '04']);

      // Model C: Irrigation valve state with deviceFrame command
      final valveControl = <String, dynamic>{
        'id': 'valve_state',
        'binding': 'device.parameters.valve',
        'deviceFrame': {
          'commands': [
            {
              'Field_description': 'Data',
              'asperui': ['[Closed][Auto][Open]'],
              'sno_asperui': ['[00][01][02]'],
            }
          ]
        }
      };
      final valveOpts = AppState.optionsFor(valveControl);
      expect(valveOpts.length, 3);
      expect(valveOpts.map((o) => o['label']).toList(), ['Closed', 'Auto', 'Open']);
    });

    testWidgets('Tuning textField card displays both caption name and frame data value', (tester) async {
      final tuningSchema = <String, dynamic>{
        ...testTheme,
        'pages': [
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
                  ],
                  'response': []
                }
              }
            ]
          }
        ],
        'state': {
          'device': {
            'parameters': {
              '2_tuning_command_2_text': '--',
            }
          }
        }
      };

      final state = AppState(tuningSchema);
      final control = state.controlById('2:tuning:command-2-text')!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ParameterCard(
                control: control,
                state: state,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Field label "Resistance" must be displayed
      expect(find.text('Resistance'), findsOneWidget);

      // TextField must display the data value "2.300000" rather than being blank
      expect(find.byType(TextField), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller?.text, '2.300000');
    });

    test('AppState.resolveDeviceIdentity handles node_details as List<dynamic> without type cast errors', () {
      final schemaWithListNodeDetails = <String, dynamic>{
        ...testTheme,
        'node_details': <dynamic>[
          <String, dynamic>{
            'id': 'NODE_LIST_99',
            'model_no': 'MODEL_DYNAMIC_FAN',
            'config': {
              'devices': [
                {
                  'pages': {
                    'p1': {
                      'f1': {
                        'response': ['ok'],
                      },
                    },
                  },
                },
              ],
            },
          },
        ],
        'device': <dynamic>[],
        'controls': <Map<String, dynamic>>[],
      };

      // Initializing AppState must not throw type cast error
      final state = AppState(schemaWithListNodeDetails);
      final identity = state.resolveDeviceIdentity();
      expect(identity.modelId, 'MODEL_DYNAMIC_FAN');
      expect(identity.nodeId, 'NODE_LIST_99');
      state.dispose();
    });
  });
}


