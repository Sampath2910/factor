import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/iot_sdui/iot_schema_repository.dart';
import 'package:efactor_sdui/services/device_page_cache_manager.dart';
import 'package:efactor_sdui/services/schema_offline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('device_cache_test_');
    SchemaDiskCache.testDirectory = tempDir;
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    SchemaDiskCache.testDirectory = null;
  });

  Map<String, dynamic> sampleDeviceSchema({int pageNo = 1, int pageCount = 2}) {
    return <String, dynamic>{
      'schemaType': 'device-ui',
      'schemaVersion': '1.0.0',
      'meta': {
        'pageCount': pageCount,
      },
      'paging': {
        'pageCount': pageCount,
        'pageNo': pageNo,
        'pages': [
          {'id': 'p1', 'pageNo': 1},
          {'id': 'p2', 'pageNo': 2},
        ],
      },
      'pages': [
        {
          'id': 'p1',
          'pageNo': 1,
          'controlIds': ['1:pwr'],
        },
        {
          'id': 'p2',
          'pageNo': 2,
          'controlIds': ['2:speed'],
        },
      ],
      'controls': [
        {
          'id': pageNo == 1 ? '1:pwr' : '2:speed',
          'type': 'button',
        },
      ],
      'ui': {
        'type': 'column',
        'children': [
          {
            'id': 'slide_$pageNo',
            'type': 'column',
            'properties': {'pageNo': '$pageNo'},
            'children': [
              {'id': pageNo == 1 ? '1:pwr' : '2:speed'},
            ],
          },
        ],
      },
      'state': {
        'device': {
          'parameters': <String, dynamic>{
            'power': true,
          },
        },
      },
    };
  }

  test('isPageCached returns false initially and true once saved', () async {
    const model = 'STUDIO_TEST_MODEL';
    const node = 'NODE_123';

    expect(
      await DevicePageCacheManager.instance.isPageCached(
        modelId: model,
        nodeId: node,
        pageNo: 1,
      ),
      isFalse,
    );

    final repo = SchemaRepository();
    final schema = sampleDeviceSchema(pageNo: 1);
    await repo.persistPageRaw(
      modelId: model,
      nodeId: node,
      pageNo: 1,
      raw: jsonEncode(schema),
    );

    expect(
      await DevicePageCacheManager.instance.isPageCached(
        modelId: model,
        nodeId: node,
        pageNo: 1,
      ),
      isTrue,
    );
  });

  test('getCachedPage retrieves completely saved page from local disk', () async {
    const model = 'STUDIO_TEST_MODEL';
    const node = 'NODE_456';

    expect(
      await DevicePageCacheManager.instance.getCachedPage(
        modelId: model,
        nodeId: node,
        pageNo: 2,
      ),
      isNull,
    );

    final repo = SchemaRepository();
    final schema2 = sampleDeviceSchema(pageNo: 2);
    await repo.persistPageRaw(
      modelId: model,
      nodeId: node,
      pageNo: 2,
      raw: jsonEncode(schema2),
    );

    final retrieved = await DevicePageCacheManager.instance.getCachedPage(
      modelId: model,
      nodeId: node,
      pageNo: 2,
    );
    expect(retrieved, isNotNull);
    expect(retrieved!['schemaType'], 'device-ui');
    expect(retrieved['_clientSchemaPageNo'], 2);
    expect(retrieved['_clientSchemaCacheHit'], isTrue);
  });

  test('corrupted or incomplete schema is rejected and never persisted', () async {
    const model = 'STUDIO_TEST_MODEL';
    const node = 'NODE_ERR';
    final repo = SchemaRepository();

    // Invalid JSON
    expect(
      () => repo.persistPageRaw(
        modelId: model,
        nodeId: node,
        pageNo: 1,
        raw: '{invalid json',
      ),
      throwsFormatException,
    );

    // Missing schemaType == 'device-ui'
    expect(
      () => repo.persistPageRaw(
        modelId: model,
        nodeId: node,
        pageNo: 1,
        raw: jsonEncode({'status': false, 'message': 'API Error'}),
      ),
      throwsFormatException,
    );

    expect(
      await DevicePageCacheManager.instance.isPageCached(
        modelId: model,
        nodeId: node,
        pageNo: 1,
      ),
      isFalse,
    );
  });

  test('ModelSchemaCache delegates seamlessly to DevicePageCacheManager', () async {
    const model = 'STUDIO_TEST_MODEL';
    const node = 'NODE_789';

    final repo = SchemaRepository();
    await repo.persistPageRaw(
      modelId: model,
      nodeId: node,
      pageNo: 1,
      raw: jsonEncode(sampleDeviceSchema(pageNo: 1)),
    );

    int updatedPage = -1;
    final changed = await ModelSchemaCache.instance.syncModel(
      modelId: model,
      nodeId: node,
      activePageNo: 1,
      onPageUpdated: (pageNo, _) {
        updatedPage = pageNo;
      },
    );

    expect(changed, isA<List<int>>());
    expect(updatedPage, -1);
    expect(
      await DevicePageCacheManager.instance.isPageCached(
        modelId: model,
        nodeId: node,
        pageNo: 1,
      ),
      isTrue,
    );
  });

  test('loadMergedDeviceSchema merges multiple cached pages into a single ready schema', () async {
    const model = 'MERGED_TEST_MODEL';
    const node = 'NODE_555';

    final repo = SchemaRepository();
    // Save Page 1 and Page 2 to local cache.
    await repo.persistPageRaw(
      modelId: model,
      nodeId: node,
      pageNo: 1,
      raw: jsonEncode(sampleDeviceSchema(pageNo: 1, pageCount: 2)),
    );
    await repo.persistPageRaw(
      modelId: model,
      nodeId: node,
      pageNo: 2,
      raw: jsonEncode(sampleDeviceSchema(pageNo: 2, pageCount: 2)),
    );

    // Call loadMergedDeviceSchema
    final merged = await repo.loadMergedDeviceSchema(
      modelId: model,
      nodeId: node,
    );

    // Both controls must be present in the unified schema
    final controlIds = (merged['controls'] as List)
        .map((c) => (c as Map)['id'])
        .toList();
    expect(controlIds, containsAll(['1:pwr', '2:speed']));

    // Both pager slots must be ready immediately (0ms tab switch)
    expect(SchemaRepository.pageSlotReady(merged, 1), isTrue);
    expect(SchemaRepository.pageSlotReady(merged, 2), isTrue);
  });

  test('expanded memory cache retains more than 2 pages without eviction', () async {
    const model = 'CACHE_RETENTION_MODEL';
    const node = 'NODE_777';

    final repo = SchemaRepository();
    for (int p = 1; p <= 3; p++) {
      await repo.persistPageRaw(
        modelId: model,
        nodeId: node,
        pageNo: p,
        raw: jsonEncode(sampleDeviceSchema(pageNo: p, pageCount: 3)),
      );
      // Read to populate memory cache
      await repo.loadSchemaPage(
        modelId: model,
        nodeId: node,
        pageNo: p,
      );
    }

    // With capacity = 30, Page 1, Page 2, and Page 3 must all remain in memory
    expect(repo.peekMemory(modelId: model, nodeId: node, pageNo: 1), isNotNull);
    expect(repo.peekMemory(modelId: model, nodeId: node, pageNo: 2), isNotNull);
    expect(repo.peekMemory(modelId: model, nodeId: node, pageNo: 3), isNotNull);
  });
}

