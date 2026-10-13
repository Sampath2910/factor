import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/sdui/renderer.dart';

void main() {
  testWidgets('Simulate user on Page 3 and see what is rendered on screen', (tester) async {
    final file = File('test/test_schemas_cache.json');
    final allPages = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    final p1 = allPages['1'] as Map<String, dynamic>;
    final p2 = allPages['2'] as Map<String, dynamic>;
    final p3 = allPages['3'] as Map<String, dynamic>;
    final p4 = allPages['4'] as Map<String, dynamic>;

    // In loadMergedDeviceSchema / _cacheRemainingPages:
    var merged = SchemaRepository.mergeDevicePageSchema(p1, p2);
    merged = SchemaRepository.mergeDevicePageSchema(merged, p3);
    merged = SchemaRepository.mergeDevicePageSchema(merged, p4);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final state = AppState(merged);
    state.activePageIndex = 2; // viewing page 3 (index 2)
    final renderer = SduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.build(context, merged['ui']['widgetTree']),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()).toList();
    // Verify Page 3 content is present
    expect(texts.any((t) => t?.toUpperCase().contains('STATUS') == true), isTrue);
    expect(texts.any((t) => t?.toUpperCase().contains('COMMAND GET STATUS') == true), isTrue);

    // Verify Page 4 content NEVER appears on Page 3
    expect(texts.any((t) => t?.toUpperCase().contains('REMOTE PAIRING') == true), isFalse);
    expect(texts.any((t) => t?.toUpperCase().contains('PAIRING') == true), isFalse);
  });

  testWidgets('filterBy pageNo strictly hides other page controls in column layouts', (tester) async {
    final file = File('test/test_schemas_cache.json');
    final allPages = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final p3 = allPages['3'] as Map<String, dynamic>;

    final c1 = (allPages['1'] as Map)['controls'][0] as Map<String, dynamic>;
    final c2 = (allPages['2'] as Map)['controls'][0] as Map<String, dynamic>;
    final c3 = (allPages['3'] as Map)['controls'][0] as Map<String, dynamic>;
    final c4 = (allPages['4'] as Map)['controls'][0] as Map<String, dynamic>;

    final schema = {
      'version': '4.0.0',
      'theme': p3['theme'],
      'extensions': p3['extensions'],
      'pages': [
        {'id': 'page_1', 'pageNo': '1', 'title': 'Page 1', 'controlIds': [c1['id']]},
        {'id': 'page_2', 'pageNo': '2', 'title': 'Page 2', 'controlIds': [c2['id']]},
        {'id': 'page_3', 'pageNo': '3', 'title': 'Page 3', 'controlIds': [c3['id']]},
        {'id': 'page_4', 'pageNo': '4', 'title': 'Page 4', 'controlIds': [c4['id']]},
      ],
      'controls': [c1, c2, c3, c4],
      'state': {'activePageIndex': 2}, // Page 3
      'ui': {
        'widgetTree': {
          'id': 'root',
          'type': 'column',
          'children': [
            {
              'id': 'list_p1',
              'type': 'schemaControlList',
              'properties': {'filterBy': 'pageNo', 'pageNo': '1', 'controlIds': [c1['id']]},
            },
            {
              'id': 'list_p2',
              'type': 'schemaControlList',
              'properties': {'filterBy': 'pageNo', 'pageNo': '2', 'controlIds': [c2['id']]},
            },
            {
              'id': 'list_p3',
              'type': 'schemaControlList',
              'properties': {'filterBy': 'pageNo', 'pageNo': '3', 'controlIds': [c3['id']]},
            },
            {
              'id': 'list_p4',
              'type': 'schemaControlList',
              'properties': {'filterBy': 'pageNo', 'pageNo': '4', 'controlIds': [c4['id']]},
            },
          ],
        },
      },
    };

    final state = AppState(schema);
    state.activePageIndex = 2; // Page 3
    final renderer = SduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.build(context, (schema['ui'] as Map)['widgetTree']),
          ),
        ),
      ),
    );
    await tester.pump();

    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()).toList();
    // Only Page 3 control should be rendered
    expect(texts.any((t) => t?.toUpperCase().contains('COMMAND GET STATUS') == true), isTrue);
    expect(texts.any((t) => t?.toUpperCase().contains('REMOTE PAIRING') == true), isFalse);
    expect(texts.any((t) => t?.toUpperCase().contains('TUNING') == true), isFalse);
    expect(texts.any((t) => t?.toUpperCase().contains('POWER') == true), isFalse);
  });
}
