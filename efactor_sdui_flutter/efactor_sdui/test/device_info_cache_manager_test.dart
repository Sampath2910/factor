import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/services/device_info_cache_manager.dart';
import 'package:efactor_sdui/services/schema_offline.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('device_info_cache_test_');
    SchemaDiskCache.testDirectory = tempDir;
    DeviceInfoCacheManager.instance.clearMemoryCache();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    SchemaDiskCache.testDirectory = null;
    DeviceInfoCacheManager.instance.clearMemoryCache();
  });

  group('DeviceInfoCacheManager Tests', () {
    test('Dynamic cache key generation supports all models and nodes', () {
      final key1 = DeviceInfoCacheManager.buildCacheKey(
        modelId: 'EFANV1.0',
        nodeId: 'NODE-001',
        prefix: 'info_data',
      );
      expect(key1, 'device_info_data_EFANV1.0_NODE-001');

      final key2 = DeviceInfoCacheManager.buildCacheKey(
        modelId: 'EF_smart_plug_C6',
        nodeId: 'NODE_PLUG_99',
        prefix: 'info_data',
      );
      expect(key2, 'device_info_data_EF_smart_plug_C6_NODE_PLUG_99');

      final key3 = DeviceInfoCacheManager.buildCacheKey(
        modelId: 'EF-003PA:Rev2',
        nodeId: '12:34:56:AB',
        prefix: 'info_schema',
      );
      expect(key3, 'device_info_schema_EF-003PA_Rev2_12_34_56_AB');
    });

    test('First-time save stores data to local disk and memory', () async {
      const model = 'MODEL_ALPHA';
      const node = 'NODE_123';
      final testPayload = <String, dynamic>{
        'device': {
          'model_no': model,
          'node_id': node,
          'firmware_version': 'v2.4.1',
          'product_name': 'Smart Sensor Pro',
        },
        'status': 'online',
      };

      expect(
        await DeviceInfoCacheManager.instance.hasCachedInfoData(
          modelId: model,
          nodeId: node,
        ),
        isFalse,
      );

      // Save locally for the first time
      await DeviceInfoCacheManager.instance.saveInfoData(
        modelId: model,
        nodeId: node,
        data: testPayload,
      );

      expect(
        await DeviceInfoCacheManager.instance.hasCachedInfoData(
          modelId: model,
          nodeId: node,
        ),
        isTrue,
      );

      final cached = await DeviceInfoCacheManager.instance.getCachedInfoData(
        modelId: model,
        nodeId: node,
      );
      expect(cached, isNotNull);
      expect(cached['device']['firmware_version'], 'v2.4.1');
      expect(cached['device']['product_name'], 'Smart Sensor Pro');
    });

    test('Data persists across app restarts (disk hydration)', () async {
      const model = 'MODEL_BETA';
      const node = 'NODE_456';
      final testPayload = <String, dynamic>{
        'device': {
          'model_no': model,
          'node_id': node,
          'ip': '192.168.1.105',
          'mac': 'AA:BB:CC:DD:EE:FF',
        },
      };

      // Save to cache
      await DeviceInfoCacheManager.instance.saveInfoData(
        modelId: model,
        nodeId: node,
        data: testPayload,
      );

      // Simulate app kill/restart by clearing memory cache
      DeviceInfoCacheManager.instance.clearMemoryCache();

      // Read from disk storage
      final hydrated = await DeviceInfoCacheManager.instance.getCachedInfoData(
        modelId: model,
        nodeId: node,
      );
      expect(hydrated, isNotNull);
      expect(hydrated['device']['ip'], '192.168.1.105');
      expect(hydrated['device']['mac'], 'AA:BB:CC:DD:EE:FF');
    });

    test('InfoPage schema is saved and retrieved locally', () async {
      const model = 'MODEL_GAMMA';
      const node = 'NODE_789';
      final testSchema = <String, dynamic>{
        'presentation': 'bottomSheet',
        'entryScreen': 'mainInfo',
        'screens': {
          'mainInfo': {
            'title': 'Device Specifications',
            'sections': [
              {
                'id': 'sec1',
                'title': 'General',
                'rows': [
                  {'id': 'row_mac', 'label': 'MAC Address', 'bind': 'device.mac'},
                ],
              },
            ],
          },
        },
      };

      await DeviceInfoCacheManager.instance.saveInfoSchema(
        modelId: model,
        nodeId: node,
        schema: testSchema,
      );

      // Wipe memory
      DeviceInfoCacheManager.instance.clearMemoryCache();

      final cachedSchema =
          await DeviceInfoCacheManager.instance.getCachedInfoSchema(
        modelId: model,
        nodeId: node,
      );
      expect(cachedSchema, isNotNull);
      expect(cachedSchema!['presentation'], 'bottomSheet');
      expect(cachedSchema['entryScreen'], 'mainInfo');
      expect(
        cachedSchema['screens']['mainInfo']['title'],
        'Device Specifications',
      );
    });

    test('Template resolution replaces node and model placeholders', () {
      final state = AppState(
        <String, dynamic>{
          'schemaType': 'device-ui',
          'node_details': {
            'node_id': 'TEST_NODE_88',
            'model_no': 'EF_CUSTOM_FAN',
          },
        },
        accessToken: 'TOKEN_XYZ_123',
      );

      const urlTemplate =
          'https://efactor.tech/api/device-info/{{device.model_no}}/{{device.node_id}}?token={{model_no}}';
      final resolved = resolveInfoTemplateValue(state, urlTemplate);
      expect(
        resolved,
        'https://efactor.tech/api/device-info/EF_CUSTOM_FAN/TEST_NODE_88?token=EF_CUSTOM_FAN',
      );

      const headerMap = {
        'Authorization': 'Bearer \$runtime.accessToken',
        'X-Node': '{{node_id}}',
      };
      final resolvedHeaders = resolveInfoTemplateValue(state, headerMap);
      expect(resolvedHeaders['Authorization'], 'Bearer TOKEN_XYZ_123');
      expect(resolvedHeaders['X-Node'], 'TEST_NODE_88');
    });

    test('PreloadInfoData silently downloads and caches info in background',
        () async {
      const model = 'MODEL_DELTA';
      const node = 'NODE_555';

      final mockClient = MockClient((request) async {
        expect(request.url.path, contains('MODEL_DELTA/NODE_555'));
        return http.Response(
          jsonEncode({
            'success': true,
            'device': {
              'model_no': model,
              'node_id': node,
              'signal_strength': '-58 dBm',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final schema = <String, dynamic>{
        'schemaType': 'device-ui',
        'node_details': {
          'model_no': model,
          'node_id': node,
        },
        'infoPage': {
          'title': 'Delta Device Info',
          'dataUrl':
              'https://efactor.tech/index.php/iot-dashboard/api/device-ui-schema/{{device.model_no}}/{{device.node_id}}',
        },
      };

      final state = AppState(schema);

      // Preload in background
      await DeviceInfoCacheManager.instance.preloadInfoData(
        state: state,
        schema: schema,
        client: mockClient,
      );

      // Now verify it was cached locally to disk
      DeviceInfoCacheManager.instance.clearMemoryCache();
      final cached = await DeviceInfoCacheManager.instance.getCachedInfoData(
        modelId: model,
        nodeId: node,
      );
      expect(cached, isNotNull);
      expect(cached['device']['signal_strength'], '-58 dBm');

      // Verify schema definition was also cached
      final cachedSchema =
          await DeviceInfoCacheManager.instance.getCachedInfoSchema(
        modelId: model,
        nodeId: node,
      );
      expect(cachedSchema, isNotNull);
      expect(cachedSchema!['title'], 'Delta Device Info');
    });

    test('Device removal purges all cached info files and keys', () async {
      const model = 'MODEL_EPSILON';
      const node = 'NODE_999';

      await DeviceInfoCacheManager.instance.saveInfoData(
        modelId: model,
        nodeId: node,
        data: {'status': 'active'},
      );
      await DeviceInfoCacheManager.instance.saveInfoSchema(
        modelId: model,
        nodeId: node,
        schema: {'title': 'Epsilon'},
      );

      expect(
        await DeviceInfoCacheManager.instance.hasCachedInfoData(
          modelId: model,
          nodeId: node,
        ),
        isTrue,
      );

      await DeviceInfoCacheManager.instance.remove(
        modelId: model,
        nodeId: node,
      );

      expect(
        await DeviceInfoCacheManager.instance.hasCachedInfoData(
          modelId: model,
          nodeId: node,
        ),
        isFalse,
      );
      expect(
        await DeviceInfoCacheManager.instance.getCachedInfoData(
          modelId: model,
          nodeId: node,
        ),
        isNull,
      );
      expect(
        await DeviceInfoCacheManager.instance.getCachedInfoSchema(
          modelId: model,
          nodeId: node,
        ),
        isNull,
      );
    });
  });
}
