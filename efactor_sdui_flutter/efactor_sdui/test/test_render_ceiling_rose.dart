import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/sdui/parameter_card.dart';

void main() {
  testWidgets('Render EF001-CEILING_ROSE_6A_01 Page 3 Device Reset card', (tester) async {
    final jsonStr = File('test/fixtures/page3_schema.json').readAsStringSync();
    final data = jsonDecode(jsonStr);
    final schemaJson = data['data']['schema_json'] as Map<String, dynamic>;
    final state = AppState(schemaJson);

    final controls = state.controls;
    final count = controls.length;
    print('Found $count controls');
    final resetControl = controls.firstWhere((c) => c['id'].toString().contains('Device Reset'));
    final resetId = resetControl['id'];
    print('Reset control: $resetId');
    print('resetControl[props] type: ${resetControl['props'].runtimeType}');
    print('resetControl[props]: ${resetControl['props']}');
    print('resetControl[component][props] type: ${resetControl['component']?['props'].runtimeType}');
    print('Options for reset: ${AppState.optionsFor(resetControl)}');
    print('resetControl deviceFrame: ${resetControl['deviceFrame']}');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ParameterCard(
            control: resetControl,
            state: state,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final elevatedButton = find.byType(ElevatedButton);
    print('ElevatedButton found: ${elevatedButton.evaluate().length}');
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()).toList();
    print('Rendered texts in card: $texts');
    expect(elevatedButton, findsOneWidget);
  });
}
