import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/services/schema_incremental_sync.dart';

void main() {
  group('SchemaIncrementalSync.syncQueryParams', () {
    test('emits last sync state fields for the server', () {
      final query = SchemaIncrementalSync.syncQueryParams(
        revision: 7,
        contentHash: 'abc',
        updatedAt: '2026-09-21T10:00:00Z',
      );
      expect(query['from_revision'], '7');
      expect(query['since_revision'], '7');
      expect(query['base_hash'], 'abc');
      expect(query['updated_after'], '2026-09-21T10:00:00Z');
    });
  });

  group('SchemaIncrementalSync.tryApplyIncrementalPayload', () {
    test('returns base when unchanged flag is set', () {
      final base = <String, dynamic>{
        'revision': 1,
        'controls': <dynamic>[
          <String, dynamic>{'id': 'a', 'value': 1},
        ],
      };
      final applied = SchemaIncrementalSync.tryApplyIncrementalPayload(
        base: base,
        payload: <String, dynamic>{'unchanged': true},
      );
      expect(applied, isNotNull);
      expect(applied!['revision'], 1);
    });

    test('applies map delta patch for updated controls', () {
      final base = <String, dynamic>{
        'revision': 1,
        'controls': <dynamic>[
          <String, dynamic>{'id': 'fan', 'value': 1},
        ],
      };
      final applied = SchemaIncrementalSync.tryApplyIncrementalPayload(
        base: base,
        payload: <String, dynamic>{
          'patch': <String, dynamic>{
            'controls': <dynamic>[
              <String, dynamic>{'id': 'fan', 'value': 5},
            ],
          },
          'to_revision': 2,
          'target_hash': 'hash2',
        },
      );
      expect(applied, isNotNull);
      expect(applied!['revision'], 2);
      final controls = applied['controls'] as List;
      expect(controls.single['value'], 5);
    });

    test('applies created/updated/deleted record delta', () {
      final base = <String, dynamic>{
        'revision': 1,
        'controls': <dynamic>[
          <String, dynamic>{'id': 'a', 'value': 1},
          <String, dynamic>{'id': 'b', 'value': 2},
        ],
      };
      final applied = SchemaIncrementalSync.tryApplyIncrementalPayload(
        base: base,
        payload: <String, dynamic>{
          'created': <dynamic>[
            <String, dynamic>{'id': 'c', 'value': 3},
          ],
          'updated': <dynamic>[
            <String, dynamic>{'id': 'a', 'value': 10},
          ],
          'deleted': <dynamic>['b'],
          'revision': 2,
        },
      );
      expect(applied, isNotNull);
      final controls = applied!['controls'] as List;
      final ids = controls.map((e) => (e as Map)['id']).toSet();
      expect(ids, containsAll(<String>['a', 'c']));
      expect(ids.contains('b'), isFalse);
      expect(applied['revision'], 2);
    });

    test('returns null for a full schema document', () {
      final base = <String, dynamic>{'revision': 1};
      final applied = SchemaIncrementalSync.tryApplyIncrementalPayload(
        base: base,
        payload: <String, dynamic>{
          'schemaType': 'server-driven-mobile-app',
          'revision': 2,
          'pages': <String, dynamic>{},
        },
      );
      expect(applied, isNull);
    });
  });

  group('SchemaIncrementalSync.isUnchanged', () {
    test('matches on content hash', () {
      expect(
        SchemaIncrementalSync.isUnchanged(
          localRevision: 3,
          localHash: 'h1',
          localUpdatedAt: null,
          remoteRevision: 4,
          remoteHash: 'h1',
          remoteUpdatedAt: null,
        ),
        isTrue,
      );
    });

    test('matches on equal revision when hash missing', () {
      expect(
        SchemaIncrementalSync.isUnchanged(
          localRevision: 5,
          localHash: null,
          localUpdatedAt: null,
          remoteRevision: 5,
          remoteHash: null,
          remoteUpdatedAt: null,
        ),
        isTrue,
      );
    });
  });
}
