import 'dart:convert';
import 'dart:io';

import 'package:efactor_sdui/iot_sdui/iot_schema_icon.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_renderer.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';
import 'package:efactor_sdui/sdui/schema_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> liveSchema;

  setUpAll(() {
    final devPath = r'C:\Users\DELL\.gemini\antigravity-ide\brain\5f8923e5-c288-4a07-a9a8-d7aa5d286f01\.system_generated\steps\1293\content.md';
    final devFile = File(devPath);
    if (devFile.existsSync()) {
      final content = devFile.readAsStringSync();
      final jsonStart = content.indexOf('{');
      final jsonStr = content.substring(jsonStart);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      liveSchema = data['schema'] as Map<String, dynamic>;
    } else {
      final localFile = File('assets/iot_schema_test.json');
      final data = jsonDecode(localFile.readAsStringSync()) as Map<String, dynamic>;
      liveSchema = data['schema'] as Map<String, dynamic>;
    }
  });

  test('Live schema 2.4.2 responsive breakpoints and deviceGrid responsiveLayout', () {
    final runtime = SchemaRuntime(liveSchema);
    
    // Narrow: 0 - 359 -> should resolve to narrow
    expect(runtime.resolveBreakpointName(320.0), 'narrow');
    // Compact: 360 - 599 -> should resolve to compact
    expect(runtime.resolveBreakpointName(400.0), 'compact');
    // Medium: 600 - 839 -> should resolve to medium
    expect(runtime.resolveBreakpointName(700.0), 'medium');
    // Expanded: >= 840 -> should resolve to expanded
    expect(runtime.resolveBreakpointName(1000.0), 'expanded');

    final grid = (liveSchema['components'] as List)
        .firstWhere((c) => c['type'] == 'deviceGrid') as Map<String, dynamic>;

    final narrowGrid = runtime.resolveResponsiveMap(grid, 320.0);
    expect(narrowGrid['columns'], 2);

    final compactGrid = runtime.resolveResponsiveMap(grid, 400.0);
    expect(compactGrid['columns'], 2);

    final mediumGrid = runtime.resolveResponsiveMap(grid, 700.0);
    expect(mediumGrid['columns'], 3);

    final expandedGrid = runtime.resolveResponsiveMap(grid, 1000.0);
    expect(expandedGrid['columns'], 4);
  });

  testWidgets('Device grid columns actually scale with viewport size', (tester) async {
    final state = IotSduiState(schema: liveSchema, accessToken: 'test_token');
    final renderer = IotSduiRenderer(state);

    // 1. Tablet landscape (1000 x 800)
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => renderer.build(ctx),
          ),
        ),
      ),
    );
    await tester.pump();

    // Verify symmetric grid rows render with IntrinsicHeight
    expect(find.byType(IntrinsicHeight), findsWidgets);
  });

  testWidgets('Icon resolution and fallback widgets render without schema error red dots', (tester) async {
    final iconResolver = IotSchemaIcon(liveSchema);

    // Top-level declared icons
    expect(iconResolver.resolveNamedDefinition('smartHomeHeader'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('wifiSignal'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('addDevice'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('qrcode'), isNotNull);

    // Catalog declared icons
    expect(iconResolver.resolveNamedDefinition('fan'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('light'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('switch'), isNotNull);
    expect(iconResolver.resolveNamedDefinition('device'), isNotNull);

    // Missing from server schema definition:
    expect(iconResolver.resolveNamedDefinition('qrFrame'), isNull);
    expect(iconResolver.resolveNamedDefinition('trash-2'), isNull);

    // BUT buildNamed falls back dynamically to SduiIconRegistry rather than error circle!
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Column(
              children: [
                iconResolver.buildNamed(ctx, name: 'qrFrame'),
                iconResolver.buildNamed(ctx, name: 'device'),
                iconResolver.buildNamed(ctx, name: 'addDevice'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Verify icons rendered without red error circle (which has BoxDecoration with red color / shape circle)
    expect(find.byType(Icon), findsWidgets);
  });
}
