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
            for (var c = 1; c <= 5; c++) 'p${i}_ctrl_$c',
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

  testWidgets('6-page IoT device: all pages merge, update controls, and render properly', (tester) async {
    // 1. Prepare 6 distinct page payloads, all sharing backend generatedAt
    final pages = <Map<String, dynamic>>[
      for (var i = 1; i <= 6; i++)
        createTestDeviceSchema(
          pageNo: i,
          totalPages: 6,
          controlIdsForThisPage: [
            for (var c = 1; c <= 5; c++) 'p${i}_ctrl_$c',
          ],
        ),
    ];

    // Initial state: Page 1 loaded
    final state = AppState(pages[0]);
    expect(state.controls.length, 5);
    expect(SchemaRepository.pageSlotReady(state.schema, 1), isTrue);

    // Iteratively merge pages 2 through 6
    for (var pageNo = 2; pageNo <= 6; pageNo++) {
      expect(SchemaRepository.pageSlotReady(state.schema, pageNo), isFalse);

      final incoming = pages[pageNo - 1];
      final merged = SchemaRepository.mergeDevicePageSchema(state.schema, incoming);

      expect(SchemaRepository.pageSlotReady(merged, pageNo), isTrue);
      expect(schemaFingerprint(state.schema), isNot(equals(schemaFingerprint(merged))));

      final patch = state.replaceSchema(merged, preservePage: false);
      expect(patch.unchanged, isFalse);
      expect(state.controls.length, pageNo * 5);
      expect(SchemaRepository.pageSlotReady(state.schema, pageNo), isTrue);
    }

    // Now all 6 pages have 30 controls in state
    expect(state.controls.length, 30);
    for (var i = 1; i <= 6; i++) {
      expect(SchemaRepository.pageSlotReady(state.schema, i), isTrue);
    }

    // Mount renderer in widget test
    final renderer = SduiRenderer(state);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => renderer.build(context, state.schema['ui']),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Page 1 controls visible initially
    expect(find.text('Control Label p1_ctrl_1'), findsOneWidget);

    // Switch to Page 2
    state.revealPageIndex(1);
    await tester.pumpAndSettle();
    expect(find.text('Control Label p2_ctrl_1'), findsOneWidget);

    // Switch to Page 6
    state.revealPageIndex(5);
    await tester.pumpAndSettle();
    expect(find.text('Control Label p6_ctrl_1'), findsOneWidget);

    // Switch back to Page 1
    state.revealPageIndex(0);
    await tester.pumpAndSettle();
    expect(find.text('Control Label p1_ctrl_1'), findsOneWidget);
  });

  test('Cloud telemetry buffer stages remote parameters for unmerged pages and drains seamlessly on page schema merge, with value-only diffing', () {
    final initialPage = createTestDeviceSchema(
      pageNo: 1,
      totalPages: 6,
      controlIdsForThisPage: [
        for (var c = 1; c <= 5; c++) 'p1_ctrl_$c',
      ],
    );
    final state = AppState(initialPage);

    // 1. Cloud pushes readings for Page 1 AND Page 6:
    // Page 1 is in controls -> applies immediately
    state.applyRemoteParameter('p1_ctrl_1', 'live_p1_value');
    expect(state.parameters['p1_ctrl_1'], 'live_p1_value');
    expect(state.resolveBinding('device.parameters.p1_ctrl_1'), 'live_p1_value');

    // Page 6 is NOT in controls yet -> staged in buffer, not dropped
    state.applyRemoteParameter('p6_ctrl_1', 'live_p6_value');
    expect(state.cloudTelemetryBuffer['p6_ctrl_1'], 'live_p6_value');

    // 2. Telemetry value-diffing: re-applying identical value does not change state
    state.applyRemoteParameter('p1_ctrl_1', 'live_p1_value');
    expect(state.parameters['p1_ctrl_1'], 'live_p1_value');

    // 3. New changed value for Page 1 applies
    state.applyRemoteParameter('p1_ctrl_1', 'live_p1_updated');
    expect(state.parameters['p1_ctrl_1'], 'live_p1_updated');

    // 4. Now page 6 schema arrives from server/cache and merges into state
    final page6Schema = createTestDeviceSchema(
      pageNo: 6,
      totalPages: 6,
      controlIdsForThisPage: [
        for (var c = 1; c <= 5; c++) 'p6_ctrl_$c',
      ],
    );
    final merged = SchemaRepository.mergeDevicePageSchema(state.schema, page6Schema);
    state.replaceSchema(merged, preservePage: false);

    // 5. Buffer auto-drained into newly merged controls & parameters!
    expect(state.cloudTelemetryBuffer.containsKey('p6_ctrl_1'), isFalse);
    expect(state.parameters['p6_ctrl_1'], 'live_p6_value');
    expect(state.resolveBinding('device.parameters.p6_ctrl_1'), 'live_p6_value');
  });
}

