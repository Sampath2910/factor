import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Multi-page schema displays all page number buttons and progress bar',
      (tester) async {
    final schema = <String, dynamic>{
      'version': '4.0.0',
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
        'mode': 'page',
        'pageCount': 6,
        'pages': [
          {'id': 'page_1', 'pageNo': '1', 'title': 'Page1.Operation'},
          {'id': 'page_2', 'pageNo': '2', 'title': 'Configure.Config'},
          {'id': 'page_3', 'pageNo': '3', 'title': 'Status'},
          {'id': 'page_4', 'pageNo': '4', 'title': 'Remote Pair.pairing'},
          {'id': 'page_5', 'pageNo': '5', 'title': 'Remote Address'},
          {'id': 'page_6', 'pageNo': '6', 'title': 'Mortgage'},
        ],
      },
      'pages': [
        {'id': 'page_1', 'pageNo': '1', 'title': 'Page1.Operation'},
      ],
      'controls': [
        {
          'id': 'ctrl_1',
          'type': 'text',
          'properties': {'text': 'Control on Page 1'},
        }
      ],
      'state': {
        'activePageIndex': 0,
        'device': {'parameters': {}},
      },
      'ui': {
        'type': 'column',
        'children': [
          {
            'id': 'page_slider',
            'type': 'listView',
            'properties': {'physics': 'page', 'scrollDirection': 'horizontal'},
            'children': [
              {
                'id': 'page_slide_0',
                'type': 'column',
                'properties': {'pageNo': '1', 'pageId': 'page_1'},
                'children': [
                  {
                    'id': 'ctrl_1',
                    'type': 'text',
                    'properties': {'text': 'Control on Page 1'},
                  }
                ],
              },
            ],
          },
          {
            'id': 'progress_bar',
            'type': 'progress',
            'properties': {'binding': 'state.pageProgress'},
          },
          {
            'id': 'page_buttons',
            'type': 'listView',
            'properties': {'scrollDirection': 'horizontal'},
            'children': [
              for (var i = 1; i <= 6; i++)
                {
                  'id': 'page_button_${i - 1}',
                  'type': 'button',
                  'properties': {
                    'events': [
                      {
                        'event': 'onTap',
                        'action': {
                          'type': 'update',
                          'value': 'activePageIndex=${i - 1}',
                        },
                      }
                    ],
                  },
                  'children': [
                    {
                      'id': 'page_text_$i',
                      'type': 'text',
                      'properties': {'text': '$i'},
                    }
                  ],
                },
            ],
          },
        ],
      },
    };

    SchemaRepository.ensurePlaceholderSlides(schema);
    final state = AppState(schema);

    expect(state.pages.length, 6);
    expect(state.activePage['title'], 'Page1.Operation');

    final renderer = SduiRenderer(state);

    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => SingleChildScrollView(
              child: renderer.build(context, schema['ui']),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Verify all 6 page number buttons are rendered and visible
    for (var i = 1; i <= 6; i++) {
      expect(find.text('$i'), findsOneWidget,
          reason: 'Page button $i should be visible');
    }

    // Scroll to and tap page button 2
    await tester.ensureVisible(find.text('2'));
    await tester.pump();
    await tester.tap(find.text('2'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.activePageIndex, 1);
    expect(state.activePage['title'], 'Configure.Config');

    // Scroll to and tap page button 6
    await tester.ensureVisible(find.text('6'));
    await tester.pump();
    await tester.tap(find.text('6'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.activePageIndex, 5);
    expect(state.activePage['title'], 'Mortgage');
  });
}
