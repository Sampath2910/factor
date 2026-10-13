import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import 'json_http.dart';
import 'schema_offline.dart';

/// Resolves placeholder bindings (e.g. `{{device.node_id}}`, `{{model_no}}`,
/// `$runtime.modelId`, `$secureState`) dynamically from device state.
/// Works across any device model and node identity without hardcoding.
dynamic resolveInfoTemplateValue(AppState state, dynamic value) {
  if (value is Map) {
    final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    final secureKey = map[r'$secureState']?.toString();
    if (secureKey != null) {
      if (secureKey.contains('AccessToken') || secureKey.contains('token')) {
        return state.accessToken;
      }
      return null;
    }
    return map.map((k, v) => MapEntry(k, resolveInfoTemplateValue(state, v)));
  }
  if (value is List) {
    return value.map((item) => resolveInfoTemplateValue(state, item)).toList();
  }
  if (value is! String) return value;

  final identity = state.resolveDeviceIdentity();
  final modelId = identity.modelId ?? '';
  final nodeId = identity.nodeId ?? '';

  final replacements = <String, String>{
    r'$runtime.nodeId': nodeId,
    r'$runtime.modelId': modelId,
    r'$runtime.accessToken': state.accessToken,
    r'{{node_id}}': nodeId,
    r'{{nodeId}}': nodeId,
    r'{{device.node_id}}': nodeId,
    r'{{device.nodeId}}': nodeId,
    r'{{model_no}}': modelId,
    r'{{modelId}}': modelId,
    r'{{device.model_no}}': modelId,
    r'{{device.model_number}}': modelId,
  };

  if (replacements.containsKey(value)) return replacements[value];

  var resolved = value;
  for (final entry in replacements.entries) {
    resolved = resolved.replaceAll(entry.key, entry.value);
  }
  return resolved;
}

/// Manages local disk caching and immediate presentation for the SDUI
/// Device Info page across all hardware models.
///
/// Features:
/// 1. Local-first: If cached data exists locally on disk or in memory,
///    the Info page displays instantly with 0ms blocking spinner delay.
/// 2. First-time persistence: On the very first load, freshly fetched
///    info data and schema definitions are automatically saved to local
///    persistent storage (disk & SharedPreferences).
/// 3. Silent revalidation: When cached data is displayed, fresh updates
///    are fetched seamlessly in the background and applied in-place.
/// 4. Dynamic for all models: Works dynamically for any model and node
///    without hardcoding any model-specific identifiers.
class DeviceInfoCacheManager {
  DeviceInfoCacheManager._();

  static final DeviceInfoCacheManager instance = DeviceInfoCacheManager._();

  final Map<String, _CachedPayloadEntry> _memoryCache =
      <String, _CachedPayloadEntry>{};
  final Map<String, Future<dynamic>> _inFlight = <String, Future<dynamic>>{};

  /// Builds a sanitized, deterministic cache key for any model/node.
  static String buildCacheKey({
    required String modelId,
    required String nodeId,
    String? url,
    String prefix = 'info_data',
  }) {
    final cleanModel = modelId
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final cleanNode = nodeId
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (cleanModel.isNotEmpty && cleanNode.isNotEmpty) {
      return 'device_${prefix}_${cleanModel}_$cleanNode';
    }
    if (cleanModel.isNotEmpty) {
      return 'device_${prefix}_$cleanModel';
    }
    if (url != null && url.trim().isNotEmpty) {
      return 'device_${prefix}_url_${contentHashString(url.trim())}';
    }
    return 'device_${prefix}_default';
  }

  /// Checks if cached info data exists in memory or on disk.
  Future<bool> hasCachedInfoData({
    required String modelId,
    required String nodeId,
    String? url,
  }) async {
    final key = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      url: url,
      prefix: 'info_data',
    );
    if (_memoryCache.containsKey(key)) return true;
    final diskExists = await SchemaDiskCache.exists('$key.json');
    if (diskExists) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(key) || prefs.containsKey('$key.savedAtMs');
  }

  /// Retrieves locally cached device info data (payload).
  Future<dynamic> getCachedInfoData({
    required String modelId,
    required String nodeId,
    String? url,
    bool allowStale = true,
  }) async {
    final key = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      url: url,
      prefix: 'info_data',
    );
    final memoryHit = _memoryCache[key];
    if (memoryHit != null) {
      logDebug('[DeviceInfoCacheManager] MEMORY CACHE HIT: $key');
      return memoryHit.data;
    }

    try {
      String? raw = await SchemaDiskCache.readString('$key.json');
      final prefs = await SharedPreferences.getInstance();
      raw ??= prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      _memoryCache[key] = _CachedPayloadEntry(
        data: decoded,
        cachedAt: DateTime.now(),
      );
      logDebug('[DeviceInfoCacheManager] DISK CACHE HIT: $key');
      return decoded;
    } catch (error) {
      logDebug('[DeviceInfoCacheManager] Cache read error for $key: $error');
      return null;
    }
  }

  /// Saves device info data (payload) to local persistent disk and memory.
  Future<void> saveInfoData({
    required String modelId,
    required String nodeId,
    String? url,
    required dynamic data,
  }) async {
    if (data == null) return;
    final key = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      url: url,
      prefix: 'info_data',
    );
    try {
      final raw = jsonEncode(data);
      _memoryCache[key] = _CachedPayloadEntry(
        data: data,
        cachedAt: DateTime.now(),
      );
      await SchemaDiskCache.writeString('$key.json', raw);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, raw);
      await prefs.setInt(
        '$key.savedAtMs',
        DateTime.now().millisecondsSinceEpoch,
      );
      logDebug('[DeviceInfoCacheManager] Saved info data locally for $key');
    } catch (error) {
      logDebug(
        '[DeviceInfoCacheManager] Failed to save info data for $key: $error',
      );
    }
  }

  /// Retrieves locally cached device info schema.
  Future<Map<String, dynamic>?> getCachedInfoSchema({
    required String modelId,
    required String nodeId,
  }) async {
    final key = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      prefix: 'info_schema',
    );
    final memoryHit = _memoryCache[key];
    if (memoryHit != null && memoryHit.data is Map) {
      return Map<String, dynamic>.from(memoryHit.data as Map);
    }

    try {
      String? raw = await SchemaDiskCache.readString('$key.json');
      final prefs = await SharedPreferences.getInstance();
      raw ??= prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final schemaMap = Map<String, dynamic>.from(decoded);
        _memoryCache[key] = _CachedPayloadEntry(
          data: schemaMap,
          cachedAt: DateTime.now(),
        );
        return schemaMap;
      }
      return null;
    } catch (error) {
      logDebug(
        '[DeviceInfoCacheManager] Failed to read info schema for $key: $error',
      );
      return null;
    }
  }

  /// Saves device info schema locally.
  Future<void> saveInfoSchema({
    required String modelId,
    required String nodeId,
    required Map<String, dynamic> schema,
  }) async {
    final key = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      prefix: 'info_schema',
    );
    try {
      final raw = jsonEncode(schema);
      _memoryCache[key] = _CachedPayloadEntry(
        data: schema,
        cachedAt: DateTime.now(),
      );
      await SchemaDiskCache.writeString('$key.json', raw);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, raw);
      await prefs.setInt(
        '$key.savedAtMs',
        DateTime.now().millisecondsSinceEpoch,
      );
      logDebug('[DeviceInfoCacheManager] Saved info schema locally for $key');
    } catch (error) {
      logDebug(
        '[DeviceInfoCacheManager] Failed to save info schema for $key: $error',
      );
    }
  }

  /// Removes cached info for a device (e.g. when removed or reset).
  Future<void> remove({
    required String modelId,
    required String nodeId,
  }) async {
    final dataKey = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      prefix: 'info_data',
    );
    final schemaKey = buildCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      prefix: 'info_schema',
    );
    _memoryCache.remove(dataKey);
    _memoryCache.remove(schemaKey);

    try {
      await SchemaDiskCache.remove('$dataKey.json');
      await SchemaDiskCache.remove('$schemaKey.json');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(dataKey);
      await prefs.remove('$dataKey.savedAtMs');
      await prefs.remove(schemaKey);
      await prefs.remove('$schemaKey.savedAtMs');
    } catch (_) {}
  }

  /// Clears in-memory cache (for unit tests / logout).
  void clearMemoryCache() {
    _memoryCache.clear();
    _inFlight.clear();
  }

  /// Pre-warms the device info data and schema in the background so opening
  /// the Info page is instantaneous even on first tap.
  Future<void> preloadInfoData({
    required AppState state,
    required Map<String, dynamic> schema,
    http.Client? client,
  }) async {
    try {
      final identity = state.resolveDeviceIdentity();
      final modelId = identity.modelId ?? '';
      final nodeId = identity.nodeId ?? '';
      if (modelId.isEmpty) return;

      Map<String, dynamic>? asMap(dynamic val) {
        if (val is Map) {
          return Map<String, dynamic>.from(val.cast<dynamic, dynamic>());
        }
        return null;
      }

      dynamic readPath(dynamic root, String path) {
        dynamic current = root;
        final tokenPattern = RegExp(r'([^\.\[\]]+)|\[(\d+)\]');
        for (final match in tokenPattern.allMatches(path)) {
          final key = match.group(1);
          final indexText = match.group(2);
          if (key != null) {
            if (current is! Map || !current.containsKey(key)) return null;
            current = current[key];
          } else if (indexText != null) {
            final index = int.tryParse(indexText);
            if (index == null || current is! List || index >= current.length) {
              return null;
            }
            current = current[index];
          }
        }
        return current;
      }

      final infoPage = asMap(schema['infoPage']) ??
          asMap(readPath(schema, 'extensions.serverDrivenUi.infoPage')) ??
          asMap(readPath(schema, 'extensions.universalUi.infoPage'));

      if (infoPage != null) {
        await saveInfoSchema(
          modelId: modelId,
          nodeId: nodeId,
          schema: infoPage,
        );
      }

      final dataSourceId = infoPage?['dataSource']?.toString();
      final dataSources = asMap(schema['dataSources']);
      final source = dataSourceId != null
          ? asMap(dataSources?[dataSourceId])
          : null;

      String? firstText(List<dynamic> values) {
        for (final v in values) {
          final t = v?.toString().trim();
          if (t != null && t.isNotEmpty) return t;
        }
        return null;
      }

      final rawUrl = firstText(<dynamic>[
        source?['url'],
        infoPage?['dataUrl'],
        asMap(source?['nativeApi'])?['url'],
      ]);

      if (rawUrl == null || rawUrl.isEmpty) return;

      final resolvedUrl = resolveInfoTemplateValue(state, rawUrl)?.toString();
      if (resolvedUrl == null || resolvedUrl.isEmpty) return;

      final cached = await hasCachedInfoData(
        modelId: modelId,
        nodeId: nodeId,
        url: resolvedUrl,
      );
      if (cached) return;

      final inFlightKey = buildCacheKey(
        modelId: modelId,
        nodeId: nodeId,
        url: resolvedUrl,
      );
      if (_inFlight.containsKey(inFlightKey)) return;

      final flight = _executeFetch(
        state: state,
        url: resolvedUrl,
        source: source,
        client: client,
      );
      _inFlight[inFlightKey] = flight;

      final payload = await flight;
      if (payload != null) {
        await saveInfoData(
          modelId: modelId,
          nodeId: nodeId,
          url: resolvedUrl,
          data: payload,
        );
        logDebug(
          '[DeviceInfoCacheManager] Pre-cached info data for $modelId/$nodeId',
        );
      }
    } catch (e) {
      logDebug('[DeviceInfoCacheManager] Preload error: $e');
    }
  }

  Future<dynamic> _executeFetch({
    required AppState state,
    required String url,
    required Map<String, dynamic>? source,
    http.Client? client,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      return null;
    }
    if (uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1') {
      return null;
    }

    final headers = <String, String>{'Accept': 'application/json'};
    final rawHeaders = source?['headers'] as Map?;
    if (rawHeaders != null) {
      for (final entry in rawHeaders.entries) {
        final val = resolveInfoTemplateValue(state, entry.value)?.toString();
        if (val != null && val.isNotEmpty) {
          headers[entry.key.toString()] = val;
        }
      }
    }

    final token = state.accessToken.trim();
    if (token.isNotEmpty && !headers.containsKey('Authorization')) {
      headers['Authorization'] = 'Bearer $token';
    }

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(uri, headers: headers).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final raw = utf8.decode(response.bodyBytes).trim();
      if (raw.isEmpty || looksLikeHtml(raw)) return null;
      return jsonDecode(raw);
    } catch (_) {
      return null;
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }
}

class _CachedPayloadEntry {
  _CachedPayloadEntry({required this.data, required this.cachedAt});
  final dynamic data;
  final DateTime cachedAt;
}
