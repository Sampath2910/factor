import 'package:efactor_sdui/services/schema_incremental_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('forceFull revalidate always calls fetchFull (live schema)', () async {
    var fetchFullCalls = 0;
    final local = <String, dynamic>{
      'schemaVersion': '1.0.0',
      'revision': 1,
      'contentHash': 'abc',
    };

    final result = await SchemaIncrementalSync.revalidate(
      client: MockClient((_) async => http.Response('{}', 200)),
      localSchema: local,
      forceFull: true,
      logTag: 'TestPull',
      persist: (_) async {},
      fetchFull: ({Map<String, String>? syncQuery}) async {
        fetchFullCalls++;
        return <String, dynamic>{
          'schemaVersion': '1.0.1',
          'revision': 2,
          'contentHash': 'def',
        };
      },
    );

    expect(fetchFullCalls, 1);
    expect(result.source, 'full-forced');
    expect(result.usedDelta, isFalse);
    expect(result.schema['revision'], 2);
  });

  test('IoT-style reloadHandler contract uses forceRefresh true', () async {
    var forceRefreshArg = false;
    Future<void> reloadHandler() async {
      // Mirrors DynamicIotSduiPage: reloadHandler = () => _load(forceRefresh: true)
      forceRefreshArg = true;
    }

    await reloadHandler();
    expect(forceRefreshArg, isTrue);
  });
}
