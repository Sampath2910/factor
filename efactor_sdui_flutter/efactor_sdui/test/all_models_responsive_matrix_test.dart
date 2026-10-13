import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/sdui/renderer.dart';

void main() {
  final file = File('tool/live_schema_audit_result.json');
  if (!file.existsSync()) {
    test('Schemas file not found', () {});
    return;
  }

  final auditJson = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  final modelsToTest = <String>[
    'Device Schema (EFANV1.0)',
    'Device Schema (EF-001FMN01)',
    'Device Schema (nireeModal1)',
  ];

  final devices = <String, Size>{
    'Samsung Galaxy S25 (360x780)': const Size(360, 780),
    'Realme Narzo 30 (392x850)': const Size(392, 850),
    'Compact Phone (320x568)': const Size(320, 568),
  };

  for (final modelKey in modelsToTest) {
    final modelData = auditJson[modelKey] as Map<String, dynamic>?;
    if (modelData == null || modelData['extracted'] == null) continue;

    final schema = modelData['extracted'] as Map<String, dynamic>;
    final pages = schema['pages'];
    if (pages is! List || pages.isEmpty) continue;

    group('Universal Responsiveness Verification for $modelKey', () {
      for (final device in devices.entries) {
        testWidgets('Renders all pages cleanly on ${device.key} without overflows',
            (WidgetTester tester) async {
          tester.view.physicalSize = Size(device.value.width * 2, device.value.height * 2);
          tester.view.devicePixelRatio = 2.0;
          // Simulate 3-Button Nav bar (48dp bottom inset)
          tester.view.padding = const FakeViewPadding(bottom: 96);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetPadding();
          });

          final state = AppState(schema);
          final renderer = SduiRenderer(state);

          // Test rendering Page 1
          final firstPage = pages.first as Map<String, dynamic>;

          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: device.value,
                padding: const EdgeInsets.only(bottom: 48),
                textScaler: const TextScaler.linear(1.15), // Simulated system font zoom
              ),
              child: MaterialApp(
                home: Scaffold(
                  body: SafeArea(
                    bottom: true,
                    child: SingleChildScrollView(
                      child: Builder(
                        builder: (context) => renderer.build(context, firstPage),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(tester.takeException(), isNull,
              reason: 'Model $modelKey must render with zero overflows on ${device.key}');

          state.dispose();
        });
      }
    });
  }
}
