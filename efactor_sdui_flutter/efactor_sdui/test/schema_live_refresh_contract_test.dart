import 'package:efactor_sdui/services/schema_incremental_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('forceFull revalidate always calls fetchFull (live schema)', () async {
    var fetchFullCount = 0;
    final local = <String, dynamic>{
      'schemaVersion': '1',
      'revision': 1,
      'contentHash': 'abc',
    };

    final result = await SchemaIncrementalSync.revalidate(
      client: MockClient((_) async => http.Response('{}', 200)),
      localSchema: local,
      forceFull: true,
      persist: (_) async {},
      fetchFull: ({Map<String, String>? syncQuery}) async {
        fetchFullCount++;
        return <String, dynamic>{
          ...local,
          'revision': 2,
          'contentHash': 'def',
          'pulledLive': true,
        };
      },
    );

    expect(fetchFullCount, 1);
    expect(result.source, 'full-forced');
    expect(result.schema['pulledLive'], isTrue);
  });
}
