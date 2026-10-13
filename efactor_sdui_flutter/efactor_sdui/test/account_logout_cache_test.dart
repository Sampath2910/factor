import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';
import 'package:efactor_sdui/home_sdui/home_schema_repository.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';
import 'package:efactor_sdui/iot_sdui/iot_schema_repository.dart';
import 'package:efactor_sdui/services/app_cache_manager.dart';
import 'package:efactor_sdui/services/efactor_cloud_service.dart';
import 'package:efactor_sdui/services/schema_prefetch.dart';
import 'package:efactor_sdui/sdui/sdui_network_image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return Directory.systemTemp.path;
      },
    );
  });

  test('Logout clears user-specific home cache and all IoT caches', () async {
    SharedPreferences.setMockInitialValues({
      'home_sdui.cache.707.home_overview': '{"status": 1, "user": 707}',
      'home_sdui.cache.708.home_overview': '{"status": 1, "user": 708}',
      'home_sdui.cache.legacy_key': '{"legacy": true}',
      'efactor.iot.datasource.v1.some_token': '{"devices": []}',
      'efactor.device.server_schema.v1.abc': '{"schema": true}',
    });

    // Verify initial values exist
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('home_sdui.cache.707.home_overview'), isTrue);
    expect(prefs.containsKey('home_sdui.cache.708.home_overview'), isTrue);
    expect(prefs.containsKey('efactor.iot.datasource.v1.some_token'), isTrue);

    // Call clearUserCache on logout for user 707
    await HomeSchemaRepository.clearUserCache(userId: 707);
    await HomeSduiState.clearUserCache(userId: 707);
    await IotSduiState.clearUserCache(accessToken: 'some_token');
    await IotSchemaRepository.clearCache();
    EfactorCloudService.instance.disconnect();
    SchemaLoadQueue.instance.reset();

    // Verify user 707 caches are wiped
    expect(prefs.containsKey('home_sdui.cache.707.home_overview'), isFalse);
    // User 708 cache should remain untouched (or isolated)
    expect(prefs.containsKey('home_sdui.cache.708.home_overview'), isTrue);
    // IoT datasource cache for that token is wiped
    expect(prefs.containsKey('efactor.iot.datasource.v1.some_token'), isFalse);
  });

  test('AppCacheManager.clearAllOnLogout wipes all memory, device parameters, schemas, and prefs', () async {
    SharedPreferences.setMockInitialValues({
      'efactor.device.live_params.v1.dev_123.switch': 'true',
      'efactor.device.server_schema.v1.modelA.page1': '{"schema": 1}',
      'efactor.device.known_models_nodes': '["modelA/1"]',
      'efactor.iot.server_schema.v2.key1': '{"page": {}}',
      'home_sdui.cache.707.home_overview': '{"home": true}',
      'home_sdui_cache_overview': '{"stale": true}',
      'sdui_temp_key': '123',
      'unrelated_app_setting': 'keep_me',
    });

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('efactor.device.live_params.v1.dev_123.switch'), isTrue);
    expect(prefs.containsKey('efactor.device.server_schema.v1.modelA.page1'), isTrue);
    expect(prefs.containsKey('home_sdui.cache.707.home_overview'), isTrue);
    expect(prefs.containsKey('sdui_temp_key'), isTrue);

    // Call unified AppCacheManager.clearAllOnLogout
    await AppCacheManager.clearAllOnLogout(userId: 707, accessToken: 'token_abc');

    // Verify all caches and parameters are wiped
    expect(prefs.containsKey('efactor.device.live_params.v1.dev_123.switch'), isFalse);
    expect(prefs.containsKey('efactor.device.server_schema.v1.modelA.page1'), isFalse);
    expect(prefs.containsKey('efactor.device.known_models_nodes'), isFalse);
    expect(prefs.containsKey('home_sdui.cache.707.home_overview'), isFalse);
    expect(prefs.containsKey('home_sdui_cache_overview'), isFalse);
    expect(prefs.containsKey('sdui_temp_key'), isFalse);
    // Unrelated setting retained
    expect(prefs.getString('unrelated_app_setting'), 'keep_me');
  });

  test('SduiNetworkImageCache.collectImageUrls correctly harvests all URLs from schema', () {
    final schema = <String, dynamic>{
      'page': {
        'logoUrl': 'https://example.com/logo.png',
        'backgroundImage': 'https://example.com/bg.jpg',
      },
      'components': [
        {
          'type': 'image',
          'src': 'https://example.com/image1.webp',
        },
        {
          'type': 'card',
          'avatarUrl': 'https://example.com/avatar.png',
          'details': 'Contact support or visit https://example.com/embedded.jpg today',
        },
        {
          'type': 'banner',
          'src': 'invalid-url',
        },
      ],
    };

    final urls = SduiNetworkImageCache.collectImageUrls(schema);
    expect(urls.contains('https://example.com/logo.png'), isTrue);
    expect(urls.contains('https://example.com/bg.jpg'), isTrue);
    expect(urls.contains('https://example.com/image1.webp'), isTrue);
    expect(urls.contains('https://example.com/avatar.png'), isTrue);
    expect(urls.contains('https://example.com/embedded.jpg'), isTrue);
    expect(urls.contains('invalid-url'), isFalse);
  });
}
