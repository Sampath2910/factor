import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/sdui/tap_diagnostic_inspector.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;

  setUp(() {
    TapDiagnosticInspector.instance.history.clear();
    TapDiagnosticInspector.instance.latestReportNotifier.value = null;

    final schema = <String, dynamic>{
      'version': '1.0.0',
      'controls': <Map<String, dynamic>>[
        {
          'id': '1:Power:command-2-toggle_switch',
          'binding': 'device.parameters.power_switch',
          'writable': true,
          'access': 'Read/Write',
        },
        {
          'id': '1:Speed:command-3-slider',
          'binding': 'device.parameters.speed_control',
          'writable': false,
          'access': 'Read Only',
        },
        {
          'id': '1:ReadOnlyProto:command-4',
          'binding': 'device.parameters.proto_lock',
          'protocolMeta': {'access': 'Read Only'},
        },
      ],
      'theme': {
        'colors': {
          'toggleOn': '#10B981',
          'toggleOff': '#64748B',
          'surface': '#FFFFFF',
        },
      },
    };

    state = AppState(schema);
  });

  testWidgets('TapDiagnosticInspector dispatches permitted write and logs report',
      (tester) async {
    var executed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  TapDiagnosticInspector.instance.inspectTap(
                    context: context,
                    componentType: 'switch',
                    controlId: '1:Power:command-2-toggle_switch',
                    binding: 'device.parameters.power_switch',
                    currentValue: false,
                    attemptedValue: true,
                    state: state,
                    onDispatched: () {
                      executed = true;
                    },
                  );
                },
                child: const Text('Tap Me'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tap Me'));
    await tester.pumpAndSettle();

    expect(executed, isTrue, reason: 'Writable tap should execute callback');
    expect(TapDiagnosticInspector.instance.history.length, 1);
    final report = TapDiagnosticInspector.instance.history.first;
    expect(report.status, TapDiagnosticStatus.dispatched);
    expect(report.controlId, '1:Power:command-2-toggle_switch');
    expect(find.text('TAP DISPATCHED'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('TapDiagnosticInspector blocks read-only control with clear reason',
      (tester) async {
    var executed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  TapDiagnosticInspector.instance.inspectTap(
                    context: context,
                    componentType: 'slider',
                    controlId: '1:Speed:command-3-slider',
                    binding: 'device.parameters.speed_control',
                    currentValue: 10,
                    attemptedValue: 20,
                    state: state,
                    onDispatched: () {
                      executed = true;
                    },
                  );
                },
                child: const Text('Tap Disabled Slider'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tap Disabled Slider'));
    await tester.pumpAndSettle();

    expect(executed, isFalse, reason: 'Read-only tap must NOT execute callback');
    expect(TapDiagnosticInspector.instance.history.length, 1);
    final report = TapDiagnosticInspector.instance.history.first;
    expect(report.status, TapDiagnosticStatus.blocked);
    expect(report.reason, contains('writable'));
    expect(find.text('TAP BLOCKED'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('TapDiagnosticInspector warns on missing binding prefix',
      (tester) async {
    var executed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  TapDiagnosticInspector.instance.inspectTap(
                    context: context,
                    componentType: 'switch',
                    controlId: 'raw_switch',
                    binding: 'raw_binding_without_prefix',
                    currentValue: false,
                    attemptedValue: true,
                    state: state,
                    onDispatched: () {
                      executed = true;
                    },
                  );
                },
                child: const Text('Tap Raw Binding'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tap Raw Binding'));
    await tester.pumpAndSettle();

    expect(TapDiagnosticInspector.instance.history.length, 1);
    final report = TapDiagnosticInspector.instance.history.first;
    expect(report.status, TapDiagnosticStatus.warning);
    expect(report.reason, contains('device.parameters.'));
    expect(find.text('TAP WARNING'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}
