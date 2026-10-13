import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/schema_guard.dart';
import 'package:efactor_sdui/state/app_state.dart';

/// Reproduces the live EFCKER Skipmode control shape that paints an empty
/// gray ParameterCard body on device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> skipmodeSchema() {
    return <String, dynamic>{
      'theme': {
        'colors': {
          'surface': '#F8FAFC',
          'text': '#0F172A',
          'primary': '#2563EB',
          'buttonBg': '#2563EB',
          'buttonText': '#FFFFFF',
          'border': '#E2E8F0',
          'accent': '#2563EB',
          'mutedText': '#64748B',
        },
        'radius': {'card': 16, 'button': 14, 'pill': 999},
        'spacing': {'cardPadding': 14, 'pagePadding': 16},
        'borders': {'size': 1},
      },
      'components': {
        'catalog': [
          {
            'id': 'trigger',
            'layout': 'row',
            'position': 'trailing',
          },
        ],
      },
      'extensions': {
        'universalUi': {
          'designSystem': {
            'componentStyles': {
              'parameterCard': {
                'layout': {
                  'type': 'grid',
                  'columns': ['auto', '1fr', 'auto'],
                  'alignItems': 'center',
                  'gap': 12,
                },
                'borderRadius': 16,
                'padding': 14,
                'borderWidth': 1,
                'minHeight': 44,
                'parts': {
                  'leftAccent': {
                    'visible': true,
                    'width': 3,
                    'background': {
                      'stops': [
                        {'color': '#94A3B8'},
                        {'color': '#2563EB'},
                      ],
                    },
                  },
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
      'state': {
        'device': {
          'parameters': {
            '1_skipmode_command_2_trigger': 'Skipmode',
          },
        },
      },
      'controls': [
        {
          'id': '1:Skipmode:command-2-trigger',
          'parameter': 'Skipmode',
          'label': 'Skipmode',
          'value': 'Skipmode',
          'valueType': 'trigger',
          'componentType': 'elevatedButton',
          'binding': 'device.parameters.1_skipmode_command_2_trigger',
          'icon': 'gauge',
          'options': [
            {'label': 'false', 'value': '00'},
            {'label': 'true', 'value': '01'},
          ],
          'component': {
            'type': 'elevatedButton',
            'catalogComponentType': 'trigger',
            'binding': 'device.parameters.1_skipmode_command_2_trigger',
            'valueType': 'trigger',
            'displayValue': 'Skipmode',
            'widgetTree': {
              'type': 'ParameterCard',
              'properties': {
                'binding': 'device.parameters.1_skipmode_command_2_trigger',
                'props': {
                  'label': 'Skipmode',
                  'value': 'Command',
                  'icon': 'gauge',
                  'variant': 'elevatedButton',
                  'catalogComponentType': 'trigger',
                  'layout': 'row',
                  'cardStyle': {
                    'backgroundColor': '#00000000',
                    'borderColor': '#00000000',
                    'borderWidth': 0,
                    'borderRadius': 0,
                    'padding': 8,
                    'minHeight': 44,
                    'leftAccent': {
                      'visible': true,
                      'width': 3,
                      'colorStart': '#94A3B8',
                      'colorEnd': '#2563EB',
                    },
                    'iconBubble': {
                      'size': 38,
                      'backgroundColor': '#242563EB',
                      'iconColor': '#2563EB',
                    },
                    'fieldLabel': {
                      'fontFamily': 'Inter',
                      'fontSize': 11,
                      'fontWeight': 800,
                      'color': '#64748B',
                      'uppercase': true,
                    },
                    'fieldValue': {
                      'fontFamily': 'Inter',
                      'fontSize': 16,
                      'fontWeight': 700,
                      'color': '#0F172A',
                    },
                  },
                  'metaValue': '1',
                },
              },
              'children': [
                {
                  'type': 'ElevatedButton',
                  'properties': {
                    'binding':
                        'device.parameters.1_skipmode_command_2_trigger',
                    'props': {
                      'labelBinding':
                          'device.parameters.1_skipmode_command_2_trigger',
                      'backgroundColor': '#2563EB',
                      'textColor': '#FFFFFF',
                      'useLiveBinding': true,
                    },
                    'events': [
                      {
                        'event': 'onTap',
                        'action': {
                          'type': 'send',
                          'binding':
                              'device.parameters.1_skipmode_command_2_trigger',
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      ],
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'controlIds': ['1:Skipmode:command-2-trigger'],
        },
      ],
    };
  }

  testWidgets('Skipmode embedded row renders ElevatedButton', (tester) async {
    final schema = skipmodeSchema();
    final state = AppState(schema);
    final renderer = SduiRenderer(state);
    final control = Map<String, dynamic>.from(state.controls.first);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: renderer.parameterCard(control, embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SchemaIssueWidget), findsNothing);
    expect(find.byType(ElevatedButton), findsOneWidget);
  });

  testWidgets(
      'Trigger with only labelBinding still paints a button when binding is placeholder',
      (tester) async {
    final schema = skipmodeSchema();
    // Clear live value so labelBinding resolves empty/placeholder.
    (schema['state'] as Map)['device'] = {
      'parameters': {'1_skipmode_command_2_trigger': ''},
    };
    final state = AppState(schema);
    final renderer = SduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: renderer.parameterCard(
              Map<String, dynamic>.from(state.controls.first),
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SchemaIssueWidget), findsNothing);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.text('Skipmode'), findsWidgets);
  });

  testWidgets(
      'Skipmode control group stays compact inside a tall bounded viewport',
      (tester) async {
    final schema = skipmodeSchema();
    final state = AppState(schema);
    final renderer = SduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            width: 390,
            child: Builder(
              builder: (context) {
                return renderer.build(
                  context,
                  {
                    'type': 'schemaControlList',
                    'properties': {
                      'props': {
                        'renderMode': 'schemaControls',
                        'source': 'controls',
                        'pageNo': '1',
                      },
                    },
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(SchemaIssueWidget), findsNothing);

    final button = tester.getRect(find.byType(ElevatedButton));
    // Group must not stretch to the full 700px viewport (blank gray body).
    expect(button.top, lessThan(200));
  });
}
