import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/sdui/info_action.dart';
import 'package:efactor_sdui/services/device_info_cache_manager.dart';
import 'package:efactor_sdui/services/schema_offline.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('info_page_cache_test_');
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

  Map<String, dynamic> createTestDeviceSchema({
    required String modelId,
    required String nodeId,
  }) {
    return <String, dynamic>{
      'schemaType': 'device-ui',
      'node_details': {
        'model_no': modelId,
        'node_id': nodeId,
      },
      'infoPage': {
        'presentation': 'sheet',
        'entryScreen': 'deviceDetails',
        'theme': {
          'backgroundColor': '#FFFFFF',
          'textColor': '#111827',
        },
        'screens': {
          'deviceDetails': {
            'title': 'Device Specifications',
            'sections': [
              {
                'id': 'general_info',
                'title': 'Hardware Information',
                'rows': [
                  {
                    'id': 'model_name',
                    'label': 'Model Name',
                    'bind': 'device.product_name',
                  },
                  {
                    'id': 'firmware',
                    'label': 'Firmware Version',
                    'bind': 'device.firmware_version',
                  },
                ],
              },
            ],
          },
        },
        'dataSource': 'deviceInfoQuery',
      },
      'dataSources': {
        'deviceInfoQuery': {
          'url':
              'https://efactor.tech/api/device-info/{{device.model_no}}/{{device.node_id}}',
          'method': 'GET',
          'load': 'onAction',
        },
      },
    };
  }

  testWidgets(
      'Opening Info page with existing local cache renders immediately with cached values and NO blocking dialog',
      (tester) async {
    const model = 'EFANV1.0';
    const node = 'FAN_NODE_42';

    // Pre-populate local disk cache with saved payload (as if loaded before)
    await DeviceInfoCacheManager.instance.saveInfoData(
      modelId: model,
      nodeId: node,
      url: 'https://efactor.tech/api/device-info/$model/$node',
      data: {
        'device': {
          'product_name': 'Air Circulator Fan v1',
          'firmware_version': '1.0.8-cached',
        },
      },
    );

    final schema = createTestDeviceSchema(modelId: model, nodeId: node);
    final state = AppState(schema);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    handleOpenInfo(
                      context,
                      state,
                      {'value': 'openDeviceInfo'},
                    );
                  },
                  child: const Text('Open Info'),
                ),
              ),
            );
          },
        ),
      ),
    );

    // Tap to open Info
    await tester.tap(find.text('Open Info'));
    await tester.pump(); // immediate frame

    // Verify modal bottom sheet opened immediately without waiting
    expect(find.text('Device Specifications'), findsOneWidget);
    expect(find.text('Air Circulator Fan v1'), findsOneWidget);
    expect(find.text('1.0.8-cached'), findsOneWidget);

    // Verify no blocking progress indicator is shown
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
      'First time open caches data and schema so subsequent opens load instantly',
      (tester) async {
    const model = 'EF_smart_plug_C6';
    const node = 'PLUG_NODE_77';

    expect(
      await DeviceInfoCacheManager.instance.hasCachedInfoData(
        modelId: model,
        nodeId: node,
      ),
      isFalse,
    );

    // Populate data directly into cache simulating successful first-load download
    await DeviceInfoCacheManager.instance.saveInfoData(
      modelId: model,
      nodeId: node,
      url: 'https://efactor.tech/api/device-info/$model/$node',
      data: {
        'device': {
          'product_name': 'Smart Plug C6 Fast',
          'firmware_version': '3.2.0',
        },
      },
    );
    await DeviceInfoCacheManager.instance.saveInfoSchema(
      modelId: model,
      nodeId: node,
      schema: {
        'presentation': 'sheet',
        'entryScreen': 'deviceDetails',
        'screens': {
          'deviceDetails': {
            'title': 'Plug Specs',
            'sections': [
              {
                'id': 'sec1',
                'rows': [
                  {
                    'id': 'plug_name',
                    'label': 'Plug Name',
                    'bind': 'device.product_name',
                  },
                ],
              },
            ],
          },
        },
      },
    );

    // Check that it is now saved locally
    expect(
      await DeviceInfoCacheManager.instance.hasCachedInfoData(
        modelId: model,
        nodeId: node,
      ),
      isTrue,
    );

    // Clear in-memory cache to verify disk hydration on second open
    DeviceInfoCacheManager.instance.clearMemoryCache();

    final schema = createTestDeviceSchema(modelId: model, nodeId: node);
    final state = AppState(schema);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    handleOpenInfo(
                      context,
                      state,
                      {'value': 'openDeviceInfo'},
                    );
                  },
                  child: const Text('Open Info'),
                ),
              ),
            );
          },
        ),
      ),
    );

    // Tap to open Info
    await tester.tap(find.text('Open Info'));
    await tester.pump();

    // Verify it hydrated from disk immediately
    expect(find.text('Device Specifications'), findsOneWidget);
    expect(find.text('Smart Plug C6 Fast'), findsOneWidget);
  });
}
