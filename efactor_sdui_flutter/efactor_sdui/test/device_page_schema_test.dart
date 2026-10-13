import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/services/json_http.dart';
import 'package:efactor_sdui/services/schema_patch.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every published page number is saved, including a higher total', () {
    expect(
      SchemaRepository.publishedPageNumbers(<String, dynamic>{
        'meta': {'pageCount': 2},
        'pages': [
          {'pageNo': '1'},
          {'pageNo': '3'},
        ],
        'paging': {
          'pageCount': 2,
          'pages': [
            {
              'pageNo': '1',
              'pageApi': 'https://efactor.tech/v8/api_schema.php?page_no=1',
            },
            {
              'pageNo': '3',
              'pageApi': 'https://efactor.tech/v8/api_schema.php?page_no=3',
            },
          ],
        },
        'deviceConfig': {
          'devices': [
            {'total_pages': '4'},
          ],
        },
      }),
      [1, 2, 3, 4],
    );
  });

  test('page count comes from schema metadata', () {
    expect(
      SchemaRepository.publishedPageCount(<String, dynamic>{
        'meta': {'pageCount': 2},
        'pages': [
          {'pageNo': '1'},
          {'pageNo': '3'},
        ],
      }),
      2,
    );
  });

  test('a later pager slot is ready only in its own page schema', () {
    final first = <String, dynamic>{
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'controlIds': ['1:power'],
        },
        {
          'id': 'page_3',
          'pageNo': '3',
          'controlIds': ['3:status'],
        },
      ],
      'controls': [
        {'id': '1:power'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': [
              {'id': 'param_list_0'},
            ],
          },
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '3', 'pageId': 'page_3'},
            'children': <dynamic>[],
          },
        ],
      },
    };
    final second = <String, dynamic>{
      'pages': first['pages'],
      'controls': [
        {'id': '3:status'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': <dynamic>[],
          },
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '3', 'pageId': 'page_3'},
            'children': [
              {'id': 'param_list_1'},
            ],
          },
        ],
      },
    };

    expect(SchemaRepository.pageSlotReady(first, 1), isTrue);
    expect(SchemaRepository.pageSlotReady(first, 2), isFalse);
    expect(SchemaRepository.pageSlotReady(second, 2), isTrue);
  });

  test('page slot 1 does not cover controls named on later pages', () {
    final page = <String, dynamic>{
      'pages': [
        {
          'pageNo': '1',
          'controlIds': ['1:power'],
        },
        {
          'pageNo': '3',
          'controlIds': ['3:status'],
        },
      ],
      'controls': [
        {'id': '1:power'},
      ],
    };

    expect(SchemaRepository.publishedPageSlots(page), 2);
    expect(SchemaRepository.schemaCoversPublishedControls(page), isFalse);
  });

  test('merging page_no slots keeps the first page and adds the next', () {
    final first = <String, dynamic>{
      'pages': [
        {'id': 'page_1', 'controlIds': ['1:power']},
        {'id': 'page_3', 'controlIds': ['3:status']},
      ],
      'controls': [
        {'id': '1:power', 'pageNo': '1'},
      ],
      'state': {
        'device': {
          'parameters': {'1_power': 'OFF'},
        },
      },
    };
    final second = <String, dynamic>{
      'pages': first['pages'],
      'controls': [
        {'id': '3:status', 'pageNo': '3'},
      ],
      'state': {
        'device': {
          'parameters': {
            '1_power': 'ON',
            '3_status': 'OFF',
          },
        },
      },
    };

    final merged = SchemaRepository.mergeDevicePageSchema(first, second);

    expect(
      (merged['controls'] as List).map((control) => control['id']).toList(),
      ['1:power', '3:status'],
    );
    expect(
      merged['state']['device']['parameters'],
      {'1_power': 'OFF', '3_status': 'OFF'},
    );
    expect(SchemaRepository.schemaCoversPublishedControls(merged), isTrue);
    expect(first['controls'], [
      {'id': '1:power', 'pageNo': '1'},
    ]);
  });

  test('page links come from the schema, including a non-sequential page number', () {
    const first =
        'https://efactor.tech/v8/api_schema.php?model_no=Pavan-2608&node_id=23&page_no=1';
    const second =
        'https://efactor.tech/v8/api_schema.php?model_no=Pavan-2608&node_id=23&page_no=3';
    final schema = <String, dynamic>{
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'controlIds': ['1:power'],
        },
        {
          'id': 'page_3',
          'pageNo': '3',
          'controlIds': ['3:status'],
        },
      ],
      'controls': [
        {'id': '1:power'},
      ],
      'paging': {
        'pageCount': 2,
        'pages': [
          {'id': 'page_1', 'pageNo': '1', 'pageApi': first},
          {'id': 'page_3', 'pageNo': '3', 'pageApi': second},
        ],
        'nextPageApi': second,
        'prevPageApi': null,
        'pageApiTemplate':
            'https://efactor.tech/v8/api_schema.php?model_no=Pavan-2608&node_id=23&page_no={pageNo}',
        'fullSchemaApi':
            'https://efactor.tech/v8/api_schema.php?model_no=Pavan-2608&node_id=23',
      },
    };

    expect(SchemaRepository.publishedPageSchemaUrls(schema), [first, second]);
    expect(
      SchemaRepository.pageSchemaAlreadyLoaded(schema, first),
      isTrue,
    );
    expect(
      SchemaRepository.pageSchemaAlreadyLoaded(schema, second),
      isFalse,
    );
  });

  test('a later page publishes the next and back schema urls', () {
    const back =
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=1';
    const here =
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=3';
    const next =
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=5';
    final schema = <String, dynamic>{
      'paging': {
        'pages': [
          {'pageApi': here},
        ],
        'prevPageApi': back,
        'nextPageApi': next,
      },
    };

    expect(
      SchemaRepository.publishedPageSchemaUrls(schema),
      [here, back, next],
    );
  });

  test('without a paging block the page number in the schema is requested', () {
    final schema = <String, dynamic>{
      '_clientSchemaSource':
          'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1',
      'pages': [
        {'pageNo': '1', 'controlIds': ['1:power']},
        {'pageNo': '3', 'controlIds': ['3:status']},
      ],
    };

    expect(
      SchemaRepository.publishedPageSchemaUrls(schema),
      [
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=1',
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=3',
      ],
    );
  });

  test('merging pages keeps the paging list that names every screen', () {
    final first = <String, dynamic>{
      'pages': [
        {'controlIds': ['1:power']},
      ],
      'controls': [
        {'id': '1:power'},
      ],
      'paging': {
        'pages': [
          {'pageApi': 'https://efactor.tech/a?page_no=1'},
          {'pageApi': 'https://efactor.tech/a?page_no=3'},
        ],
        'nextPageApi': 'https://efactor.tech/a?page_no=3',
      },
    };
    final second = <String, dynamic>{
      'pages': first['pages'],
      'controls': [
        {'id': '3:status'},
      ],
      'paging': {
        'pages': [
          {'pageApi': 'https://efactor.tech/a?page_no=3'},
        ],
        'prevPageApi': 'https://efactor.tech/a?page_no=1',
      },
    };

    final merged = SchemaRepository.mergeDevicePageSchema(first, second);

    expect((merged['paging']['pages'] as List).length, 2);
    expect(
      SchemaRepository.sameControlIds(first, merged),
      isFalse,
    );
  });

  test('an empty later slide receives the control list from its page schema', () {
    final first = <String, dynamic>{
      'controls': [
        {'id': '1:power'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slider',
            'children': [
              {
                'id': 'page_slide_0',
                'children': [
                  {'id': 'param_list_0', 'type': 'schemaControlList'},
                ],
              },
              {
                'id': 'page_slide_1',
                'properties': {'pageNo': '3', 'pageId': 'page_3'},
                'children': <dynamic>[],
              },
            ],
          },
        ],
      },
    };
    final second = <String, dynamic>{
      'controls': [
        {'id': '3:status'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slider',
            'children': [
              {
                'id': 'page_slide_0',
                'children': <dynamic>[],
              },
              {
                'id': 'page_slide_1',
                'properties': {'pageNo': '3', 'pageId': 'page_3'},
                'children': [
                  {
                    'id': 'param_list_1',
                    'type': 'schemaControlList',
                    'properties': {'pageNo': '3', 'pageId': 'page_3'},
                  },
                ],
              },
            ],
          },
        ],
      },
    };

    final merged = SchemaRepository.mergeDevicePageSchema(first, second);
    final slides =
        merged['ui']['children'][0]['children'] as List;

    expect((slides[0]['children'] as List).single['id'], 'param_list_0');
    expect((slides[1]['children'] as List).single['id'], 'param_list_1');
    expect(
      (first['ui']['children'][0]['children'][1]['children'] as List),
      isEmpty,
    );
  });

  test('controls without the page slide are not treated as loaded', () {
    final schema = <String, dynamic>{
      'pages': [
        {
          'pageNo': '3',
          'controlIds': ['3:status'],
        },
      ],
      'controls': [
        {'id': '3:status'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '3', 'pageId': 'page_3'},
            'children': <dynamic>[],
          },
        ],
      },
    };

    expect(SchemaRepository.emptyPageSlides(schema), 1);
    expect(
      SchemaRepository.pageSchemaAlreadyLoaded(
        schema,
        'https://efactor.tech/v8/api_schema.php?model_no=M&node_id=1&page_no=3',
      ),
      isFalse,
    );
  });

  test('merging page slides with nested widgetTree fills empty slides matching by pageNo', () {
    final first = <String, dynamic>{
      'pages': [
        {'id': 'page_1', 'pageNo': '1', 'controlIds': ['1:power']},
        {'id': 'page_2', 'pageNo': '2', 'controlIds': ['2:speed']},
      ],
      'controls': [
        {'id': '1:power'},
      ],
      'ui': {
        'widgetTree': {
          'id': 'phone_shell',
          'type': 'container',
          'children': [
            {
              'id': 'slider_shell',
              'type': 'column',
              'children': [
                {
                  'id': 'page_slider',
                  'type': 'listView',
                  'children': [
                    {
                      'id': 'page_slide_0',
                      'type': 'column',
                      'properties': {'pageNo': '1', 'pageId': 'page_1'},
                      'children': [
                        {'id': 'param_list_0', 'type': 'schemaControlList'},
                      ],
                    },
                    {
                      'id': 'page_slide_1',
                      'type': 'column',
                      'properties': {'pageNo': '2', 'pageId': 'page_2'},
                      'children': <dynamic>[],
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
    };

    final second = <String, dynamic>{
      'pages': first['pages'],
      'controls': [
        {'id': '2:speed'},
      ],
      'ui': {
        'widgetTree': {
          'id': 'phone_shell',
          'type': 'container',
          'children': [
            {
              'id': 'slider_shell',
              'type': 'column',
              'children': [
                {
                  'id': 'page_slider',
                  'type': 'listView',
                  'children': [
                    {
                      'id': 'page_slide_0',
                      'type': 'column',
                      'properties': {'pageNo': '1', 'pageId': 'page_1'},
                      'children': <dynamic>[],
                    },
                    {
                      'id': 'page_slide_1',
                      'type': 'column',
                      'properties': {'pageNo': '2', 'pageId': 'page_2'},
                      'children': [
                        {'id': 'param_list_1', 'type': 'schemaControlList'},
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
    };

    final merged = SchemaRepository.mergeDevicePageSchema(first, second);
    final slider = merged['ui']['widgetTree']['children'][0]['children'][0];
    final slides = slider['children'] as List;

    expect((slides[0]['children'] as List).single['id'], 'param_list_0');
    expect((slides[1]['children'] as List).single['id'], 'param_list_1');
    expect(SchemaRepository.pageSlotReady(merged, 1), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 2), isTrue);
  });

  test('schemaFingerprint differentiates separate page schemas sharing generatedAt', () {
    final page1 = <String, dynamic>{
      'version': '4.0.0',
      'generatedAt': '2026-09-23 13:48:19 IST',
      'paging': {'page_no': 1},
      'pages': [
        {'id': 'p1', 'pageNo': '1'},
        {'id': 'p2', 'pageNo': '2'},
      ],
      'controls': [
        {'id': 'c1'},
        {'id': 'c2'},
      ],
    };
    final page2 = <String, dynamic>{
      'version': '4.0.0',
      'generatedAt': '2026-09-23 13:48:19 IST',
      'paging': {'page_no': 2},
      'pages': [
        {'id': 'p1', 'pageNo': '1'},
        {'id': 'p2', 'pageNo': '2'},
      ],
      'controls': [
        {'id': 'c3'},
        {'id': 'c4'},
        {'id': 'c5'},
      ],
    };

    final fp1 = schemaFingerprint(page1);
    final fp2 = schemaFingerprint(page2);
    expect(fp1, isNot(equals(fp2)));
  });

  test('mergeDevicePageSchema generates fresh _clientSchemaHash and AppState updates controls', () {
    final page1 = <String, dynamic>{
      'version': '4.0.0',
      'generatedAt': '2026-09-23 13:48:19 IST',
      'paging': {'page_no': 1},
      'pages': [
        {
          'id': 'page_1',
          'pageNo': '1',
          'controlIds': ['c1', 'c2'],
        },
        {
          'id': 'page_2',
          'pageNo': '2',
          'controlIds': ['c3', 'c4'],
        },
      ],
      'controls': [
        {'id': 'c1', 'type': 'text'},
        {'id': 'c2', 'type': 'text'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': [
              {'id': 'c1'},
              {'id': 'c2'},
            ],
          },
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '2', 'pageId': 'page_2'},
            'children': <dynamic>[],
          },
        ],
      },
    };
    assignClientHash(page1, '_clientSchemaHash');

    final page2 = <String, dynamic>{
      'version': '4.0.0',
      'generatedAt': '2026-09-23 13:48:19 IST',
      'paging': {'page_no': 2},
      'pages': page1['pages'],
      'controls': [
        {'id': 'c3', 'type': 'text'},
        {'id': 'c4', 'type': 'text'},
      ],
      'ui': {
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': <dynamic>[],
          },
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '2', 'pageId': 'page_2'},
            'children': [
              {'id': 'c3'},
              {'id': 'c4'},
            ],
          },
        ],
      },
    };
    assignClientHash(page2, '_clientSchemaHash');

    final merged = SchemaRepository.mergeDevicePageSchema(page1, page2);
    expect(merged['_clientSchemaHash'], isNotNull);
    expect(merged['_clientSchemaHash'], isNot(equals(page1['_clientSchemaHash'])));
    expect(schemaFingerprint(page1), isNot(equals(schemaFingerprint(merged))));

    final patch = SchemaPatch.merge(page1, merged);
    expect(patch.unchanged, isFalse);
    expect(patch.structural, isTrue);

    final appState = AppState(Map<String, dynamic>.from(page1)
      ..['controls'] = [
        {'id': 'c1', 'type': 'text'},
        {'id': 'c2', 'type': 'text'},
      ]);
    expect(appState.controls.length, 2);

    final replacePatch = appState.replaceSchema(merged, preservePage: false);
    expect(replacePatch.unchanged, isFalse);
    expect(appState.controls.length, 4);
    expect(appState.controls.map((c) => c['id']), containsAll(['c1', 'c2', 'c3', 'c4']));
  });

  test('EF-003FMN03: mergeDevicePageSchema accumulates single-page responses into all 6 published pages', () {
    final page1 = <String, dynamic>{
      'meta': {'pageCount': 6},
      'pages': [
        {'id': 'page_1', 'pageNo': 1, 'title': 'Main Controls', 'controlIds': ['1:p1']},
      ],
      'controls': [
        {'id': '1:p1', 'type': 'slider'},
      ],
      'ui': {
        'type': 'listView',
        'properties': {'physics': 'page'},
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': [{'id': '1:p1'}],
          },
        ],
      },
    };

    final page2 = <String, dynamic>{
      'meta': {'pageCount': 6},
      'pages': [
        {'id': 'page_2', 'pageNo': 2, 'title': 'Lighting Effects', 'controlIds': ['2:p2']},
      ],
      'controls': [
        {'id': '2:p2', 'type': 'slider'},
      ],
      'ui': {
        'type': 'listView',
        'properties': {'physics': 'page'},
        'children': [
          {
            'id': 'page_slide_1',
            'type': 'column',
            'properties': {'pageNo': '2', 'pageId': 'page_2'},
            'children': [{'id': '2:p2'}],
          },
        ],
      },
    };

    SchemaRepository.ensurePlaceholderSlides(page1);
    expect(page1['pages'].length, 6);
    expect((page1['ui']['children'] as List).length, 6);

    final merged = SchemaRepository.mergeDevicePageSchema(page1, page2);

    final pages = merged['pages'] as List;
    expect(pages.length, 6);
    expect(pages[0]['id'], 'page_1');
    expect(pages[0]['controlIds'], ['1:p1']);
    expect(pages[1]['id'], 'page_2');
    expect(pages[1]['controlIds'], ['2:p2']);
    expect(pages[2]['id'], 'page_3');
    expect(pages[2]['controlIds'], isEmpty);

    expect(SchemaRepository.pageSlotReady(merged, 1), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 2), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 3), isFalse);

    final slides = merged['ui']['children'] as List;
    expect(slides.length, 6);
    expect((slides[0]['children'] as List).isNotEmpty, isTrue);
    expect((slides[1]['children'] as List).isNotEmpty, isTrue);
    expect((slides[2]['children'] as List).isEmpty, isTrue);

    final appState = AppState(merged);
    expect(appState.pages.length, 6);
    expect(appState.activePageIndex, 0);

    appState.activePageIndex = 1;
    expect(appState.activePageIndex, 1);
    expect(appState.activePage['id'], 'page_2');

    appState.activePageIndex = 5;
    expect(appState.activePageIndex, 5);
  });

  test('generic: pruneHeavyProtocolMeta strips redundant oversized ui_components down to ui_type across any device', () {
    final schema = <String, dynamic>{
      'controls': [
        {
          'id': 'ctrl_1',
          'protocolMeta': {
            'command_id': 10,
            'function_code': 2,
            'ui_components': [
              {
                'ui_type': 'range-slider',
                'html_template': '<div>Huge SVG and HTML markup repeated 34 times...</div>' * 100,
                'svg_icon': '<svg>...</svg>' * 50,
              },
              {
                'ui_type': 'toggle-switch',
                'html_template': '<div>Another large markup block...</div>' * 100,
              },
            ],
          },
        },
      ],
    };

    SchemaRepository.pruneHeavyProtocolMeta(schema);

    final ctrl = (schema['controls'] as List).first as Map;
    final protocol = ctrl['protocolMeta'] as Map;
    expect(protocol['command_id'], 10);
    expect(protocol['function_code'], 2);

    final components = protocol['ui_components'] as List;
    expect(components.length, 2);
    expect(components[0], {'ui_type': 'range-slider'});
    expect(components[1], {'ui_type': 'toggle-switch'});
    expect(components[0].containsKey('html_template'), isFalse);
    expect(components[0].containsKey('svg_icon'), isFalse);
  });

  test('dynamic multi-page scalability: supports arbitrary page counts (e.g. 10 pages) dynamically', () {
    // A future device model publishing 10 pages
    final tenPageSchema = <String, dynamic>{
      'meta': {'pageCount': 10},
      'paging': {
        'pageCount': 10,
        'pageNo': 1,
      },
      'pages': [
        {
          'id': 'page_1',
          'pageNo': 1,
          'title': 'Zone 1',
          'controlIds': ['ctrl_p1_1'],
        },
      ],
      'controls': [
        {'id': 'ctrl_p1_1', 'label': 'Power Zone 1'},
      ],
      'ui': {
        'type': 'listView',
        'properties': {'physics': 'page', 'scrollDirection': 'horizontal'},
        'children': [
          {
            'id': 'page_slide_0',
            'type': 'column',
            'properties': {'pageNo': '1', 'pageId': 'page_1'},
            'children': [
              {'id': 'ctrl_p1_1'},
            ],
          },
        ],
      },
    };

    // 1. Verify dynamic page count extraction
    expect(SchemaRepository.publishedPageCount(tenPageSchema), 10);

    // 2. Verify all 10 page numbers are dynamically scheduled for sync
    final pageNumbers = SchemaRepository.publishedPageNumbers(tenPageSchema);
    expect(pageNumbers, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

    // 3. Ensure placeholder slides creates all 10 slots dynamically
    SchemaRepository.ensurePlaceholderSlides(tenPageSchema);
    final pages = tenPageSchema['pages'] as List;
    expect(pages.length, 10);
    expect(pages.map((p) => p['pageNo']).toList(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

    final slides = (tenPageSchema['ui'] as Map)['children'] as List;
    expect(slides.length, 10);
    // Page 1 slide is populated
    expect((slides[0]['children'] as List).isNotEmpty, isTrue);
    // Pages 2-10 are valid placeholders ready for lazy loading
    for (var i = 1; i < 10; i++) {
      expect((slides[i]['children'] as List).isEmpty, isTrue);
    }

    // 4. Simulate downloading and merging Page 10 dynamically
    final page10Payload = <String, dynamic>{
      'paging': {'pageCount': 10, 'pageNo': 10},
      'pages': [
        {
          'id': 'page_10',
          'pageNo': 10,
          'title': 'Zone 10 Diagnostics',
          'controlIds': ['ctrl_p10_1'],
        },
      ],
      'controls': [
        {'id': 'ctrl_p10_1', 'label': 'Diagnostics 10'},
      ],
      'ui': {
        'type': 'listView',
        'properties': {'physics': 'page', 'scrollDirection': 'horizontal'},
        'children': [
          {
            'id': 'page_slide_9',
            'type': 'column',
            'properties': {'pageNo': '10', 'pageId': 'page_10'},
            'children': [
              {'id': 'ctrl_p10_1'},
            ],
          },
        ],
      },
    };

    final merged = SchemaRepository.mergeDevicePageSchema(tenPageSchema, page10Payload);
    expect(SchemaRepository.publishedPageCount(merged), 10);
    expect((merged['pages'] as List).length, 10);
    expect((merged['controls'] as List).length, 2); // ctrl_p1_1 + ctrl_p10_1
    expect(SchemaRepository.pageSlotReady(merged, 1), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 10), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 5), isFalse); // not yet loaded

    // 5. Test AppState navigation with all 10 pages
    final appState = AppState(merged);
    expect(appState.pages.length, 10);
    expect(appState.activePageIndex, 0);

    // Navigate to page 10 (index 9)
    appState.activePageIndex = 9;
    expect(appState.activePageIndex, 9);
    expect(appState.activePage['id'], 'page_10');
  });
}

