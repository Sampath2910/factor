import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/services/json_http.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> createTestDeviceSchema({
    required int pageNo,
    required int totalPages,
    required List<String> controlIdsForThisPage,
  }) {
    final pages = <Map<String, dynamic>>[
      for (var i = 1; i <= totalPages; i++)
        {
          'id': 'page_$i',
          'pageNo': '$i',
          'title': 'Page $i',
          'controlIds': [
            for (var c = 1; c <= 3; c++) 'p${i}_ctrl_$c',
          ],
        },
    ];

    final controls = <Map<String, dynamic>>[
      for (final id in controlIdsForThisPage)
        {
          'id': id,
          'type': 'text',
          'binding': 'device.parameters.$id',
          'properties': {'text': 'Control Label $id'},
        },
    ];

    final slides = <Map<String, dynamic>>[
      for (var i = 1; i <= totalPages; i++)
        {
          'id': 'page_slide_${i - 1}',
          'type': 'column',
          'properties': {'pageNo': '$i', 'pageId': 'page_$i'},
          'children': i == pageNo
              ? [
                  for (final id in controlIdsForThisPage)
                    {
                      'id': id,
                      'type': 'text',
                      'properties': {'text': 'Control Label $id'},
                    },
                ]
              : <dynamic>[],
        },
    ];

    final doc = <String, dynamic>{
      'version': '4.0.0',
      'generatedAt': '2026-09-23 13:48:19 IST',
      'theme': {
        'colors': {
          'background': '#FFFFFF',
          'primary': '#0055FF',
          'accent': '#FF5500',
          'border': '#E0E0E0',
        },
        'radius': {'pill': 10},
        'typography': {'fontFamily': 'Poppins'},
      },
      'extensions': {
        'universalUi': {
          'designSystem': {
            'componentStyles': {
              'progress': {'height': 4},
            },
          },
        },
      },
      'paging': {
        'page_no': pageNo,
        'pageCount': totalPages,
      },
      'pages': pages,
      'controls': controls,
      'state': {
        'device': {
          'parameters': {
            for (final id in controlIdsForThisPage) id: 'val_$id',
          },
        },
      },
      'ui': {
        'type': 'column',
        'children': [
          {
            'id': 'slider',
            'type': 'listView',
            'properties': {'physics': 'page', 'scrollDirection': 'horizontal'},
            'children': slides,
          },
        ],
      },
    };

    assignClientHash(doc, '_clientSchemaHash');
    return doc;
  }

  testWidgets('PageSlider preserves scroll controllers and avoids _dependents.isEmpty during background merge and swipes', (tester) async {
    // 1. Initial State: Page 1 with controls
    final page1 = createTestDeviceSchema(
      pageNo: 1,
      totalPages: 3,
      controlIdsForThisPage: ['p1_ctrl_1', 'p1_ctrl_2'],
    );
    final state = AppState(page1);
    final renderer = SduiRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: AnimatedBuilder(
              animation: state,
              builder: (context, _) => renderer.build(context, state.schema['ui']),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Page 1 controls visible
    expect(find.text('Control Label p1_ctrl_1'), findsOneWidget);

    // 2. Background arrival of Page 2
    final page2 = createTestDeviceSchema(
      pageNo: 2,
      totalPages: 3,
      controlIdsForThisPage: ['p2_ctrl_1', 'p2_ctrl_2'],
    );
    final mergedWithPage2 = SchemaRepository.mergeDevicePageSchema(state.schema, page2);
    state.replaceSchema(mergedWithPage2, preserveValues: true, preservePage: true);

    // Pump to verify no assertion failure or controller crash
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Control Label p1_ctrl_1'), findsOneWidget);

    // 3. User switches to Page 2
    state.revealPageIndex(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify Page 2 is cleanly rendered with controls
    expect(find.text('Control Label p2_ctrl_1'), findsOneWidget);

    // 4. Background arrival of Page 3 while user is viewing Page 2
    final page3 = createTestDeviceSchema(
      pageNo: 3,
      totalPages: 3,
      controlIdsForThisPage: ['p3_ctrl_1'],
    );
    final mergedWithPage3 = SchemaRepository.mergeDevicePageSchema(state.schema, page3);
    state.replaceSchema(mergedWithPage3, preserveValues: true, preservePage: true);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify user is STILL safely on Page 2
    expect(find.text('Control Label p2_ctrl_1'), findsOneWidget);

    // 5. Switch to Page 3
    state.revealPageIndex(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify Page 3 controls
    expect(find.text('Control Label p3_ctrl_1'), findsOneWidget);

    // 6. Fast switch back to Page 1
    state.revealPageIndex(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Control Label p1_ctrl_1'), findsOneWidget);
  });
}
