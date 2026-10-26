import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/schema_repository.dart';
import '../grid_sdui/grid_live_location_service.dart';
import '../grid_sdui/grid_schema_repository.dart';
import '../grid_sdui/grid_shell_pool.dart';
import '../home_sdui/home_schema_repository.dart';
import '../home_sdui/home_sdui_state.dart';
import '../iot_sdui/iot_schema_repository.dart';
import '../iot_sdui/iot_sdui_state.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'device_parameter_store.dart';
import 'efactor_cloud_service.dart';
import 'json_http.dart';
import 'schema_offline.dart';
import 'schema_prefetch.dart';

/// Centralized manager for purging all cache memory, disk files, in-memory states,
/// and storage keys across the entire application upon user logout.
class AppCacheManager {
  AppCacheManager._();

  /// Completely wipes all memory and disk caches across all modules on logout:
  /// - User-specific Home schemas and datasources
  /// - IoT schemas and datasources
  /// - Grid schemas and web snapshots
  /// - Device schemas and device page index
  /// - Device parameter store (persisted live parameters)
  /// - Disk-cached schema files (`SchemaDiskCache` directory)
  /// - Network and Auth image caches (both disk files and in-memory decoded bitmaps)
  /// - Cloud WebSocket connections and discovered device states
  /// - Schema prefetch and download queues
  /// - All user-specific and efactor-specific SharedPreferences entries
  static Future<void> clearAllOnLogout({
    int? userId,
    String? accessToken,
  }) async {
    logDebug('[AppCacheManager] Starting comprehensive logout cache cleanup for user=$userId...');

    // 1. Cloud connections & discovery
    try {
      await EfactorCloudService.instance.disconnect();
    } catch (e) {
      logDebug('[AppCacheManager] EfactorCloudService disconnect error: $e');
    }

    // 2. Schema prefetch and background queues
    try {
      SchemaLoadQueue.instance.reset();
    } catch (e) {
      logDebug('[AppCacheManager] Queue reset error: $e');
    }

    // 3. Home SDUI schema and datasource cache (both user-specific and global)
    try {
      await HomeSchemaRepository.clearUserCache(userId: userId);
      await HomeSchemaRepository.clearAllCache();
    } catch (e) {
      logDebug('[AppCacheManager] HomeSchemaRepository clear error: $e');
    }
    try {
      await HomeSduiState.clearUserCache(userId: userId);
      await HomeSduiState.clearAllCache();
    } catch (e) {
      logDebug('[AppCacheManager] HomeSduiState clear error: $e');
    }

    // 4. IoT schema and datasource cache
    try {
      await IotSduiState.clearUserCache(accessToken: accessToken);
    } catch (e) {
      logDebug('[AppCacheManager] IotSduiState clear error: $e');
    }
    try {
      await IotSchemaRepository.clearCache();
    } catch (e) {
      logDebug('[AppCacheManager] IotSchemaRepository clear error: $e');
    }

    // 5. Grid schema cache & pre-warmed WebView shells
    try {
      await GridSchemaRepository.clearUserCache(userId: userId);
    } catch (e) {
      logDebug('[AppCacheManager] GridSchemaRepository clear error: $e');
    }
    try {
      GridShellPool.instance.clearAll();
      await GridLiveLocationService.instance.stopAll(postStop: true);
    } catch (e) {
      logDebug('[AppCacheManager] GridShellPool clear error: $e');
    }

    // 6. WebView session cookies & web storage
    try {
      final cookieManager = WebViewCookieManager();
      await cookieManager.clearCookies();
    } catch (e) {
      logDebug('[AppCacheManager] WebViewCookieManager clear error: $e');
    }

    // 7. Device schemas & known devices index
    try {
      await SchemaRepository.clearAllCache();
    } catch (e) {
      logDebug('[AppCacheManager] SchemaRepository clear error: $e');
    }

    // 8. Device parameter store
    try {
      await DeviceParameterStore.clearAll();
    } catch (e) {
      logDebug('[AppCacheManager] DeviceParameterStore clear error: $e');
    }

    // 9. Disk cache files
    try {
      await SchemaDiskCache.clearAll();
    } catch (e) {
      logDebug('[AppCacheManager] SchemaDiskCache clear error: $e');
    }

    // 10. Network and Auth image caches (disk + in-memory decoded image cache)
    try {
      await SduiNetworkImageCache.clearAll();
    } catch (e) {
      logDebug('[AppCacheManager] Image cache clear error: $e');
    }

    // 11. SharedPreferences cleanup for all remaining app cache keys
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList();
      for (final key in keys) {
        if (key.startsWith('efactor.') ||
            key.startsWith('home_sdui.') ||
            key.startsWith('home_sdui_') ||
            key.startsWith('sdui.') ||
            key.startsWith('sdui_') ||
            key.startsWith('grid.') ||
            key.startsWith('iot.')) {
          await prefs.remove(key);
        }
      }
    } catch (e) {
      logDebug('[AppCacheManager] SharedPreferences cleanup error: $e');
    }

    logDebug('[AppCacheManager] Comprehensive logout cache cleanup completed successfully.');
  }
}
