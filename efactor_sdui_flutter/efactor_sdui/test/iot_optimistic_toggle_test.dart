import 'dart:async';
import 'package:efactor_sdui/iot_sdui/iot_sdui_renderer.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> createTestSchema({required bool initialPower}) {
    return <String, dynamic>{
      'theme': {
        'background': '#ffffff',
        'surfaceOnline': '#ffffff',
        'surfaceOffline': '#f3f4f6',
        'textPrimary': '#111827',
        'textOnDark': '#ffffff',
      },
      'layout': {
        'card': {
          'minHeight': 100,
          'borderRadius': 16,
          'padding': {'top': 12, 'right': 12, 'bottom': 12, 'left': 12},
        },
      },
      'typography': {
        'powerLabel': {'fontSize': 14, 'fontWeight': '600', 'color': '#111827'},
      },
      'devices': [
        {
          'id': 'dev_1',
          'node_id': 'NODE_001',
          'name': 'Living Room Light',
          'online': true,
          'power': initialPower,
          'actions': {
            'onPowerToggle': {
              'action': 'hostAction',
              'name': 'powerToggle',
            },
          },
        }
      ],
      'components': [
        {
          'type': 'deviceGrid',
          'id': 'deviceGrid',
          'columns': 1,
          'dataSource': 'devices',
          'card': {
            'states': {
              'online': {'background': '#ffffff', 'color': '#111827'},
              'offline': {'background': '#f3f4f6', 'color': '#9ca3af'},
            },
            'zones': [
              {
                'name': 'header',
                'fields': ['powerLabel', 'powerToggle'],
              }
            ],
            'fields': {
              'powerLabel': {
                'type': 'text',
                'valueOnline': 'On',
                'valueOffline': 'Off',
                'bindPower': '{{device.power}}',
                'typography': 'powerLabel',
              },
              'powerToggle': {
                'type': 'toggle',
                'enabledWhen': '{{device.online}}',
                'bind': '{{device.power}}',
                'width': 44.0,
                'height': 26.0,
                'borderRadius': 999.0,
                'thumb': {
                  'diameter': 20.0,
                  'offset': 3.0,
                  'translateXOn': 18.0,
                },
                'track': {
                  'onlineOn': {'background': '#10b981'},
                  'onlineOff': {'background': '#e5e7eb'},
                  'offline': {'background': '#e5e7eb'},
                },
                'thumbColors': {
                  'onlineOn': '#ffffff',
                  'onlineOff': '#ffffff',
                  'offlineOn': '#ffffff',
                  'offlineOff': '#ffffff',
                },
                'onTap': {
                  'action': 'hostAction',
                  'name': 'powerToggle',
                },
              },
            },
          },
        }
      ],
    };
  }

  group('IoT SDUI Optimistic UI with Rollback Tests', () {
    setUp(() {
      IotSduiRenderer.resetToggleThrottleForTesting();
    });

    test('writeBinding updates in-memory device state and notifies listeners', () async {
      final schema = createTestSchema(initialPower: false);
      final state = IotSduiState(schema: schema, accessToken: 'test_token');

      var notified = false;
      state.addListener(() => notified = true);

      final device = state.devices.first;
      expect(device['power'], isFalse);

      state.writeBinding('{{device.power}}', true, device);
      await Future<void>.delayed(Duration.zero);

      expect(device['power'], isTrue);
      expect(notified, isTrue);
    });

    testWidgets('Tapping toggle gives instant visual feedback (0ms) and updates label', (tester) async {
      final schema = createTestSchema(initialPower: false);
      final state = IotSduiState(schema: schema, accessToken: 'test_token');

      // Create Completer so the action stays pending in-flight
      final actionCompleter = Completer<dynamic>();
      state.hostActionHandler = (action) {
        return actionCompleter.future;
      };

      final renderer = IotSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (context, _) => renderer.build(context),
            ),
          ),
        ),
      );

      // Initial state: Off
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('On'), findsNothing);

      // Tap the toggle
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pump(); // Frame 0ms (no duration pump)

      // Optimistic update: Label changed to "On" immediately without waiting for network!
      expect(find.text('On'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(state.devices.first['power'], isTrue);

      // Now complete the network call
      actionCompleter.complete({'status': 'ok'});
      await tester.pumpAndSettle();

      // State remains On
      expect(find.text('On'), findsOneWidget);
      expect(state.devices.first['power'], isTrue);
    });

    testWidgets('Rollback on failure reverts switch state and displays SnackBar', (tester) async {
      final schema = createTestSchema(initialPower: false);
      final state = IotSduiState(schema: schema, accessToken: 'test_token');

      final actionCompleter = Completer<dynamic>();
      state.hostActionHandler = (action) {
        return actionCompleter.future;
      };

      final renderer = IotSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (context, _) => renderer.build(context),
            ),
          ),
        ),
      );

      expect(find.text('Off'), findsOneWidget);

      // Tap toggle: Optimistically flips to On
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pump();
      expect(find.text('On'), findsOneWidget);

      // Fail network call
      actionCompleter.completeError(Exception('Connection timed out'));
      await tester.pumpAndSettle();

      // Reverted to Off!
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('On'), findsNothing);
      expect(state.devices.first['power'], isFalse);

      // SnackBar displayed
      expect(
        find.text('Unable to change device state. Please check your connection.'),
        findsOneWidget,
      );
    });

    testWidgets('Rapid double-taps within 300ms or while in flight are throttled', (tester) async {
      final schema = createTestSchema(initialPower: false);
      final state = IotSduiState(schema: schema, accessToken: 'test_token');

      var callCount = 0;
      final actionCompleter = Completer<dynamic>();
      state.hostActionHandler = (action) {
        callCount++;
        return actionCompleter.future;
      };

      final renderer = IotSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (context, _) => renderer.build(context),
            ),
          ),
        ),
      );

      // Tap twice quickly
      await tester.tap(find.byType(GestureDetector).last);
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pump();

      // Only 1 network call should have fired
      expect(callCount, equals(1));

      actionCompleter.complete({'status': 'ok'});
      await tester.pumpAndSettle();
    });
  });
}
