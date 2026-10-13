import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_renderer.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';

void main() {
  late Map<String, dynamic> schema;

  setUpAll(() {
    final file = File('assets/iot_schema_test.json');
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    schema = raw['schema'] as Map<String, dynamic>;
  });

  final testViewports = [
    {'name': 'iPhone SE (Ultra-Compact)', 'width': 320.0, 'height': 568.0, 'expectedCols': 2},
    {'name': 'Samsung Galaxy S25', 'width': 360.0, 'height': 780.0, 'expectedCols': 2},
    {'name': 'Native Android Device', 'width': 360.0, 'height': 800.0, 'expectedCols': 2},
    {'name': 'Realme Narzo 30', 'width': 392.0, 'height': 850.0, 'expectedCols': 2},
    {'name': 'iPhone 16 Pro Max', 'width': 430.0, 'height': 932.0, 'expectedCols': 2},
    {'name': 'Compact Tablet / Fold Inner', 'width': 600.0, 'height': 960.0, 'expectedCols': 3},
  ];

  for (final vp in testViewports) {
    final name = vp['name'] as String;
    final width = vp['width'] as double;
    final height = vp['height'] as double;
    final expectedCols = vp['expectedCols'] as int;

    testWidgets('IoT Screen renders $expectedCols columns cleanly on $name ($width x $height)', (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      FlutterErrorDetails? overflowError;
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('overflowed')) {
          overflowError = details;
        }
        originalOnError?.call(details);
      };

      final state = IotSduiState(schema: schema, accessToken: 'test_token');
      final renderer = IotSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (ctx) => renderer.build(ctx)),
          ),
        ),
      );
      await tester.pump();

      expect(overflowError, isNull, reason: 'Must not trigger RenderFlex overflow on $name');

      // Locate row containing device cards
      final rows = tester.widgetList<Row>(find.byType(Row)).where((r) {
        return r.children.whereType<Expanded>().length >= expectedCols;
      }).toList();

      expect(rows, isNotEmpty, reason: 'Expected to find card row with at least $expectedCols columns on $name');
      final cardRow = rows.first;
      final expandedChildren = cardRow.children.whereType<Expanded>().toList();
      expect(expandedChildren.length, expectedCols, reason: 'Device grid must render exactly $expectedCols columns on $name');
    });
  }
}
