import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/sdui/schema_runtime.dart';

void main() {
  Map<String, dynamic> schema() => <String, dynamic>{
        'extensions': <String, dynamic>{
          'universalUi': <String, dynamic>{
            'designSystem': <String, dynamic>{
              'componentStyles': <String, dynamic>{
                'parameterCard': <String, dynamic>{
                  'padding': 14,
                  'parts': <String, dynamic>{
                    'metaChip': <String, dynamic>{
                      'unit': 'UI',
                      'separator': ' ',
                    },
                  },
                },
                'appBar': <String, dynamic>{
                  'minHeight': 72,
                  'backgroundColor': '#1E3A8A',
                },
              },
            },
          },
        },
      };

  test('styleRef short keys resolve from designSystem.componentStyles', () {
    final resolved = SchemaRuntime.resolveComponentStyle(schema(), 'appBar');
    expect(resolved['minHeight'], 72);
    expect(resolved['backgroundColor'], '#1E3A8A');
  });

  test('dotted styleRef paths resolve to the same design-system map', () {
    final resolved = SchemaRuntime.resolveComponentStyle(
      schema(),
      'designSystem.componentStyles.parameterCard',
    );
    expect(resolved['padding'], 14);
    expect(
      (resolved['parts'] as Map)['metaChip'],
      <String, dynamic>{'unit': 'UI', 'separator': ' '},
    );
  });

  test('unknown styleRef does not invent a fallback style', () {
    expect(
      SchemaRuntime.resolveComponentStyle(schema(), 'missingStyle'),
      isEmpty,
    );
  });

  test('parameter group chip uses schema unit and separator', () {
    expect(
      SchemaRuntime.parameterGroupChipLabel(
        count: 3,
        metaChipStyle: const <String, dynamic>{
          'unit': 'UI',
          'separator': ' ',
        },
      ),
      '3 UI',
    );
  });

  test('parameter group chip substitutes a schema textTemplate', () {
    expect(
      SchemaRuntime.parameterGroupChipLabel(
        count: 1,
        metaChipStyle: const <String, dynamic>{
          'textTemplate': '{count} UI',
        },
      ),
      '1 UI',
    );
  });

  test('publishedControlIds uses the longest schema-owned page list', () {
    final ids = SchemaRuntime.publishedControlIds(
      schema: <String, dynamic>{
        'pages': <dynamic>[
          <String, dynamic>{
            'id': 'page_1',
            'pageNo': '1',
            'controlIds': <String>['a', 'b'],
          },
        ],
        'navigation': <String, dynamic>{
          'pages': <dynamic>[
            <String, dynamic>{
              'id': 'page_1',
              'pageNo': '1',
              'controlIds': <String>['a', 'b', 'tuning'],
            },
          ],
        },
      },
      nodeControlIds: <String>['a', 'b'],
      pageNo: '1',
      pageId: 'page_1',
    );
    expect(ids, <String>['a', 'b', 'tuning']);
  });
}
