import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Page 1 retention and instant navigation', () {
    final page1Doc = <String, dynamic>{
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'title': 'Page 1',
          'controlIds': ['1:power', '1:speed'],
        },
        {
          'id': 'page_2',
          'pageNo': '2',
          'title': 'Page 2',
          'controlIds': ['2:mode'],
        },
      ],
      'controls': [
        {'id': '1:power', 'type': 'switch', 'pageNo': '1'},
        {'id': '1:speed', 'type': 'slider', 'pageNo': '1'},
      ],
      'state': {
        'device': {
          'parameters': {'1_power': 'ON', '1_speed': 50},
        },
      },
      'ui': {
        'children': [
          {
            'id': 'slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': [
              {'id': '1:power'},
              {'id': '1:speed'},
            ],
          },
          {
            'id': 'slide_1',
            'type': 'column',
            'properties': {'pageNo': '2', 'pageId': 'page_2'},
            'children': <dynamic>[],
          },
        ],
      },
    };

    final page2Doc = <String, dynamic>{
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'title': 'Page 1',
          'controlIds': ['1:power', '1:speed'],
        },
        {
          'id': 'page_2',
          'pageNo': '2',
          'title': 'Page 2',
          'controlIds': ['2:mode'],
        },
      ],
      'controls': [
        {'id': '2:mode', 'type': 'segmentedControl', 'pageNo': '2'},
      ],
      'state': {
        'device': {
          'parameters': {'2_mode': 'AUTO'},
        },
      },
      'ui': {
        'children': [
          {
            'id': 'slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': <dynamic>[],
          },
          {
            'id': 'slide_1',
            'type': 'column',
            'properties': {'pageNo': '2', 'pageId': 'page_2'},
            'children': [
              {'id': '2:mode'},
            ],
          },
        ],
      },
    };

    test('Initial state has Page 1 ready and Page 2 empty', () {
      expect(SchemaRepository.pageSlotReady(page1Doc, 1), isTrue);
      expect(SchemaRepository.pageSlotReady(page1Doc, 2), isFalse);
    });

    test('Cumulative merge keeps Slide 0 populated when Page 2 is loaded', () {
      // 1. Initial screen state
      var schema = page1Doc;
      final pageSchemas = <int, Map<String, dynamic>>{1: page1Doc};
      var currentPageNo = 1;
      var totalPageCount = SchemaRepository.publishedPageCount(schema);

      expect(totalPageCount, 2);
      expect(SchemaRepository.pageSlotReady(schema, 1), isTrue);

      // 2. Navigate to Page 2
      final pageIndex = 1;
      final targetPageNo = pageIndex + 1;
      currentPageNo = targetPageNo;

      // Page 2 arrives
      pageSchemas[2] = page2Doc;
      schema = SchemaRepository.mergeDevicePageSchema(schema, page2Doc);
      totalPageCount = SchemaRepository.publishedPageCount(schema);

      // Both Page 1 and Page 2 are now ready in the unified schema!
      expect(SchemaRepository.pageSlotReady(schema, 1), isTrue);
      expect(SchemaRepository.pageSlotReady(schema, 2), isTrue);
      expect(totalPageCount, 2);

      // Verify Slide 0 children are intact (not empty)
      final slides = (schema['ui']['children'] as List);
      final slide0 = slides[0] as Map;
      final slide1 = slides[1] as Map;

      expect(slide0['children'], isNotEmpty);
      expect((slide0['children'] as List).length, 2);
      expect(slide1['children'], isNotEmpty);
      expect((slide1['children'] as List).length, 1);

      // 3. Navigate back to Page 1
      final backPageIndex = 0;
      final backPageNo = backPageIndex + 1;
      currentPageNo = backPageNo;

      // Page 1 is already ready in schema - 0ms transition, no network reload needed!
      expect(SchemaRepository.pageSlotReady(schema, backPageNo), isTrue);
      expect(pageSchemas[1], isNotNull);
      expect(slide0['children'], isNotEmpty);
      // Pager will NOT display "Loading page..." because children is not empty!
    });
  });
}
