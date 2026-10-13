import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/services/schema_patch.dart';

void main() {
  test('unchanged fingerprint skips merge work', () {
    final current = <String, dynamic>{
      '_clientSchemaHash': 'abc',
      'pages': [
        {'id': 'p1', 'title': 'One'},
      ],
    };
    final incoming = <String, dynamic>{
      '_clientSchemaHash': 'abc',
      'pages': [
        {'id': 'p1', 'title': 'Changed but hash says no'},
      ],
    };

    final patch = SchemaPatch.merge(current, incoming);
    expect(patch.unchanged, isTrue);
    expect(current['pages'][0]['title'], 'One');
  });

  test('replaces only the changed control and keeps the other object', () {
    final speed = <String, dynamic>{'id': 'speed', 'binding': 'a', 'min': 1};
    final power = <String, dynamic>{'id': 'power', 'binding': 'b', 'value': 0};
    final current = <String, dynamic>{
      'pages': [
        {
          'id': 'page-1',
          'controls': [speed, power],
        },
      ],
    };
    final incoming = <String, dynamic>{
      'pages': [
        {
          'id': 'page-1',
          'controls': [
            {'id': 'speed', 'binding': 'a', 'min': 1},
            {'id': 'power', 'binding': 'b', 'value': 1},
          ],
        },
      ],
    };

    final patch = SchemaPatch.merge(current, incoming);
    expect(patch.unchanged, isFalse);
    expect(patch.structural, isFalse);
    expect(patch.changedNodeIds, contains('power'));
    expect(patch.changedNodeIds, isNot(contains('speed')));

    final controls = (current['pages'] as List).first['controls'] as List;
    expect(identical(controls[0], speed), isTrue);
    expect(controls[1]['value'], 1);
  });

  test('added page is structural', () {
    final current = <String, dynamic>{
      'pages': [
        {'id': 'page-1'},
      ],
    };
    final incoming = <String, dynamic>{
      'pages': [
        {'id': 'page-1'},
        {'id': 'page-2'},
      ],
    };

    final patch = SchemaPatch.merge(current, incoming);
    expect(patch.structural, isTrue);
    expect(patch.changedNodeIds, contains('page-2'));
  });
}
