import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/schema_guard.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppState.isRawProtocolBracketString universal detection', () {
    test('Detects multi-bracket sno and enum arrays', () {
      expect(AppState.isRawProtocolBracketString('[00][01]'), isTrue);
      expect(
        AppState.isRawProtocolBracketString('[00][01][02][03][04][05][06][07][08]'),
        isTrue,
      );
      expect(
        AppState.isRawProtocolBracketString('[RICE][BROWNRICE][FRY][MILK]'),
        isTrue,
      );
    });

    test('Detects long hex payload tables and single hex blocks', () {
      expect(
        AppState.isRawProtocolBracketString(
          '[000000003C6E00007D010A28009600000001036E000000][000001003C6E010F00010A28009600000001036E000000]',
        ),
        isTrue,
      );
      expect(
        AppState.isRawProtocolBracketString(
          '[000000003C6E00007D010A28009600000001036E000000]',
        ),
        isTrue,
      );
    });

    test('Preserves legitimate human labels and readings across devices', () {
      expect(AppState.isRawProtocolBracketString('Cooking'), isFalse);
      expect(AppState.isRawProtocolBracketString('HARDVEG'), isFalse);
      expect(AppState.isRawProtocolBracketString('Skipmode'), isFalse);
      expect(AppState.isRawProtocolBracketString('remaining time'), isFalse);
      expect(AppState.isRawProtocolBracketString('38'), isFalse);
      expect(AppState.isRawProtocolBracketString('Voltage (V)'), isFalse);
      expect(AppState.isRawProtocolBracketString('Temp [C]'), isFalse);
      expect(AppState.isRawProtocolBracketString('[Beta] Mode'), isFalse);
      expect(AppState.isRawProtocolBracketString(''), isFalse);
      expect(AppState.isRawProtocolBracketString(null), isFalse);
    });
  });

  Map<String, dynamic> baseTestSchema({
    required List<Map<String, dynamic>> controls,
    Map<String, dynamic>? parameters,
  }) {
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
          {
            'id': 'dropdown',
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
          'parameters': parameters ?? {},
        },
      },
      'controls': controls,
    };
  }

  group('Universal SDUI rendering verification for Cooker, Skipmode, and Recipee', () {
    testWidgets('COOKER MODE suppresses [00][01][02]... caption and renders Cooking', (tester) async {
      final schema = baseTestSchema(
        parameters: {'cooker_mode': 'Cooking'},
        controls: [
          {
            'id': 'ctrl_cooker_mode',
            'fieldLabel': '[00][01][02][03][04][05][06][07][08]',
            'parameter': 'Cooker Mode',
            'componentType': 'value',
            'binding': 'device.parameters.cooker_mode',
            'icon': 'gauge',
            'component': {
              'type': 'value',
              'displayValue': 'Cooking',
            },
          },
        ],
      );

      final state = AppState(schema);
      final renderer = SduiRenderer(state);
      final control = state.controls.first;

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
      expect(find.textContaining('[00][01]'), findsNothing);
      expect(find.text('[00][01][02][03][04][05][06][07][08]'), findsNothing);
      expect(find.text('Cooking'), findsOneWidget);
    });

    testWidgets('SKIPMODE suppresses [00][01] caption and button renders clean "true"', (tester) async {
      final schema = baseTestSchema(
        parameters: {'1_skipmode_command_2_trigger': '01'},
        controls: [
          {
            'id': '1:Skipmode:command-2-trigger',
            'label': '[00][01]',
            'parameter': 'Skipmode',
            'componentType': 'elevatedButton',
            'valueType': 'trigger',
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
              'widgetTree': {
                'type': 'ParameterCard',
                'properties': {
                  'binding': 'device.parameters.1_skipmode_command_2_trigger',
                  'props': {
                    'label': '[00][01]',
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
                      'iconBubble': {
                        'size': 38,
                        'backgroundColor': '#242563EB',
                        'iconColor': '#2563EB',
                      },
                      'fieldLabel': {
                        'fontSize': 11,
                        'fontWeight': 800,
                        'color': '#64748B',
                        'uppercase': true,
                      },
                      'fieldValue': {
                        'fontSize': 16,
                        'fontWeight': 700,
                        'color': '#0F172A',
                      },
                    },
                  },
                },
                'children': [
                  {
                    'type': 'ElevatedButton',
                    'properties': {
                      'binding': 'device.parameters.1_skipmode_command_2_trigger',
                      'props': {
                        'label': '[00][01]',
                        'backgroundColor': '#2563EB',
                        'textColor': '#FFFFFF',
                      },
                    },
                  },
                ],
              },
            },
          },
        ],
      );

      final state = AppState(schema);
      final renderer = SduiRenderer(state);
      final control = state.controls.first;

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
      expect(find.textContaining('[00][01]'), findsNothing);
      expect(find.text('[00][01]: true'), findsNothing);
      expect(find.text('true'), findsOneWidget);
    });

    testWidgets('RECIPEE suppresses raw hex payload table and shows clean option', (tester) async {
      const rawHexPayloadTable =
          '[000000003C6E00007D010A28009600000001036E000000][000001003C6E010F00010A28009600000001036E000000]';

      final schema = baseTestSchema(
        parameters: {'recipe_select': '08'},
        controls: [
          {
            'id': 'ctrl_recipe',
            'parameter': 'Recipee',
            'componentType': 'dropdown',
            'valueType': 'enum',
            'value': rawHexPayloadTable,
            'binding': 'device.parameters.recipe_select',
            'icon': 'gauge',
            'options': [
              {
                'label': 'HARDVEG',
                'value': '0000080128C80000F0010A2800F000000000000000000000',
                'sno': '08',
              },
            ],
            'component': {
              'type': 'dropdown',
              'binding': 'device.parameters.recipe_select',
              'props': {
                'options': [
                  {
                    'label': 'HARDVEG',
                    'value': '0000080128C80000F0010A2800F000000000000000000000',
                    'sno': '08',
                  },
                ],
              },
            },
          },
        ],
      );

      final state = AppState(schema);
      final renderer = SduiRenderer(state);
      final control = state.controls.first;

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
      expect(find.textContaining('000000003C6E00007D01'), findsNothing);
      expect(find.text('HARDVEG'), findsOneWidget);
    });

    testWidgets('Backend fixed clean schema (empty strings) renders perfectly', (tester) async {
      final schema = baseTestSchema(
        parameters: {
          'cooker_mode': 'Cooking',
          'skipmode': '01',
          'recipe_select': '08',
        },
        controls: [
          {
            'id': 'ctrl_cooker_mode',
            'fieldLabel': '',
            'parameter': 'Cooker Mode',
            'componentType': 'value',
            'binding': 'device.parameters.cooker_mode',
            'icon': 'gauge',
            'component': {
              'type': 'value',
              'displayValue': 'Cooking',
            },
          },
          {
            'id': 'ctrl_skipmode',
            'label': '',
            'parameter': 'Skipmode',
            'componentType': 'elevatedButton',
            'valueType': 'trigger',
            'binding': 'device.parameters.skipmode',
            'icon': 'gauge',
            'options': [
              {'label': 'false', 'value': '00'},
              {'label': 'true', 'value': '01'},
            ],
            'component': {
              'type': 'elevatedButton',
              'binding': 'device.parameters.skipmode',
              'catalogComponentType': 'trigger',
              'valueType': 'trigger',
              'props': {'label': ''},
            },
          },
          {
            'id': 'ctrl_recipe',
            'parameter': 'Recipee',
            'componentType': 'dropdown',
            'valueType': 'enum',
            'value': '',
            'binding': 'device.parameters.recipe_select',
            'icon': 'gauge',
            'options': [
              {
                'label': 'HARDVEG',
                'value': '0000080128C80000F0010A2800F000000000000000000000',
                'sno': '08',
              },
            ],
          },
        ],
      );

      final state = AppState(schema);
      final renderer = SduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (final ctrl in state.controls)
                    renderer.parameterCard(ctrl, embedded: true),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SchemaIssueWidget), findsNothing);
      expect(find.text('Cooking'), findsOneWidget);
      expect(find.text('Skipmode: true'), findsOneWidget);
      expect(find.text('HARDVEG'), findsOneWidget);
    });
  });
}
