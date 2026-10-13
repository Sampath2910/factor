import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../sdui/sdui_network_image_cache.dart';
import '../services/json_http.dart';
import '../services/schema_incremental_sync.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_offline.dart';

dynamic _gridJsonDecodeAny(String raw) => jsonDecode(raw);

/// Live Grid SDUI schema loader with disk + memory cache for offline use.
class GridSchemaRepository {
  GridSchemaRepository({
    required this.accessToken,
    this.userId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const String _configuredUrl = String.fromEnvironment(
    'GRID_SCHEMA_URL',
    defaultValue:
        'https://efactor.tech/v8/grid_api_creation.php?action=get_grid&user_id={userId}',
  );

  final String accessToken;
  final int? userId;
  final http.Client _client;

  /// Memory is keyed by userId so token refresh still hits the cached schema.
  static final Map<String, Map<String, dynamic>> _memoryCache =
      <String, Map<String, dynamic>>{};
  static final Map<String, Future<Map<String, dynamic>>> _inFlight =
      <String, Future<Map<String, dynamic>>>{};

  String get _cacheKey => 'user_${userId ?? 0}';

  Future<Map<String, dynamic>> load({bool forceRefresh = false}) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw StateError(
        'Grid live schema request requires the current authenticated access token.',
      );
    }
    if (userId == null) {
      throw StateError(
        'Grid live schema request requires the authenticated user id.',
      );
    }

    final flightKey = '$_cacheKey|${forceRefresh ? 'live' : 'any'}';
    final existing = _inFlight[flightKey] ??
        (forceRefresh ? null : _inFlight['$_cacheKey|live']);
    if (existing != null) return existing;

    final pending = _loadUncoalesced(forceRefresh: forceRefresh);
    _inFlight[flightKey] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[flightKey], pending)) {
        _inFlight.remove(flightKey);
      }
    }
  }

  String get _diskCacheFileName => 'efactor.grid.server_schema.v1.user_${userId ?? 0}.json';

  /// Clears in-memory and disk Grid schema cache for a user on logout.
  static Future<void> clearUserCache({int? userId}) async {
    _memoryCache.clear();
    _inFlight.clear();
    try {
      final key = 'efactor.grid.server_schema.v1.user_${userId ?? 0}.json';
      await SchemaDiskCache.remove(key);
      logDebug('[GRID_SDUI][FETCH_SCHEMA] Cleared Grid schema cache for user=$userId');
    } catch (e) {
      logDebug('[GRID_SDUI][FETCH_SCHEMA] Failed to clear Grid cache: $e');
    }
  }

  /// Read cached schema (disk cache, or bundled fallback asset) without network attempt.
  Future<Map<String, dynamic>?> readFromCache() async {
    final disk = await _readDiskCache();
    if (disk != null) return disk;
    return _readAssetFallback();
  }

  /// Already-parsed Grid schema for this user in the current process.
  Map<String, dynamic>? peekMemory() {
    final cached = _memoryCache[_cacheKey];
    if (cached == null) return null;
    cached['_clientGridSchemaCacheHit'] = true;
    return cached;
  }

  Future<Map<String, dynamic>> _loadUncoalesced({
    required bool forceRefresh,
  }) async {
    if (!forceRefresh) {
      final memory = _memoryCache[_cacheKey];
      if (memory != null) {
        logDebug('[GRID_SDUI][FETCH_SCHEMA] MEMORY HIT');
        return memory;
      }

      final disk = await _readDiskCache();
      if (disk != null) {
        _memoryCache[_cacheKey] = disk;
        logDebug('[GRID_SDUI][FETCH_SCHEMA] DISK CACHE HIT');
        return disk;
      }
    }

    try {
      return await _loadLive(forceRefresh: forceRefresh);
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      final stale = await _readDiskCache();
      if (stale != null) {
        _memoryCache[_cacheKey] = stale;
        logDebug('[GRID_SDUI][FETCH_SCHEMA] OFFLINE FALLBACK TO DISK CACHE');
        return stale;
      }
      final fallback = await _readAssetFallback();
      if (fallback != null) {
        _memoryCache[_cacheKey] = fallback;
        logDebug('[GRID_SDUI][FETCH_SCHEMA] OFFLINE FALLBACK TO ASSET BUNDLE');
        return fallback;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _readAssetFallback() async {
    try {
      final raw = await rootBundle.loadString('assets/branding/grid.json');
      if (raw.trim().isEmpty) return null;
      final schema = await _decode(raw, sourceName: 'asset://assets/branding/grid.json');
      schema['_clientGridSchemaSource'] = 'asset://assets/branding/grid.json';
      schema['_clientGridSchemaCacheHit'] = true;
      assignClientHash(schema, '_clientGridSchemaHash', rawSource: raw);
      return schema;
    } catch (e) {
      logDebug('[GRID_SDUI][FETCH_SCHEMA] Asset bundle fallback read failed: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readDiskCache() async {
    try {
      final raw = await SchemaDiskCache.readString(_diskCacheFileName);
      if (raw == null || raw.trim().isEmpty) return null;
      final schema = await _decode(raw, sourceName: 'disk://$_diskCacheFileName');
      schema['_clientGridSchemaSource'] = 'disk://$_diskCacheFileName';
      schema['_clientGridSchemaCacheHit'] = true;
      assignClientHash(schema, '_clientGridSchemaHash', rawSource: raw);
      return schema;
    } catch (e) {
      logDebug('[GRID_SDUI][FETCH_SCHEMA] Disk cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeDiskCache(String raw) async {
    try {
      await SchemaDiskCache.writeString(_diskCacheFileName, raw);
      await LocalSchemaManifest.record(
        schemaKey: 'grid:${userId ?? 0}',
        schemaType: 'grid',
        contentHash: contentHashString(raw),
        fileName: _diskCacheFileName,
      );
      logDebug('[GRID_SDUI][FETCH_SCHEMA] DISK CACHE SAVED');
    } catch (e) {
      logDebug('[GRID_SDUI][FETCH_SCHEMA] Disk cache save failed: $e');
    }
  }

  Future<void> saveToCache(Map<String, dynamic> schema) async {
    final raw = jsonEncode(schema);
    _memoryCache[_cacheKey] = schema;
    await _writeDiskCache(raw);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  /// Cache-first incremental revalidation for Grid schemas.
  Future<SchemaSyncResult> revalidate({
    SchemaInvalidationEvent? event,
    bool forceFull = false,
  }) async {
    final cached =
        _memoryCache[_cacheKey] ?? await _readDiskCache();

    if (cached == null) {
      final full = await _loadLive(forceRefresh: true);
      return SchemaSyncResult(
        schema: full,
        changed: true,
        usedDelta: false,
        source: 'full-no-cache',
      );
    }

    // Asset fallback schemas have no server delta contract and no signed SSO tokens.
    // Force a full fetch so the live document with grid_sso is retrieved immediately.
    final isAsset =
        cached['_clientGridSchemaSource']?.toString().startsWith('asset://') ??
            false;
    final effectiveForceFull = forceFull || isAsset;

    try {
      return await SchemaIncrementalSync.revalidate(
        client: _client,
        localSchema: cached,
        accessToken: accessToken.trim(),
        event: event,
        forceFull: effectiveForceFull,
        logTag: 'GridSchemaSync',
        persist: (schema) async {
          schema['_clientGridSchemaCacheHit'] = true;
          assignClientHash(schema, '_clientGridSchemaHash');
          await saveToCache(schema);
        },
        fetchFull: ({Map<String, String>? syncQuery}) async {
          return _loadLive(forceRefresh: true, syncQuery: syncQuery);
        },
      );
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      logDebug(
        '[GRID_SDUI][FETCH_SCHEMA] REVALIDATE OFFLINE — keeping cached schema',
      );
      return SchemaSyncResult(
        schema: cached,
        changed: false,
        usedDelta: false,
        source: 'offline-cache-retained',
      );
    }
  }

  Future<Map<String, dynamic>> _loadLive({
    required bool forceRefresh,
    Map<String, String>? syncQuery,
  }) async {
    final rawUrl = _configuredUrl.replaceAll('{userId}', '${userId!}');
    final baseUri = Uri.tryParse(rawUrl);
    if (baseUri == null ||
        !baseUri.hasScheme ||
        baseUri.host.isEmpty ||
        baseUri.scheme.toLowerCase() != 'https') {
      throw const FormatException(
        'GRID_SCHEMA_URL must be an absolute HTTPS URL.',
      );
    }

    final query = <String, String>{
      ...baseUri.queryParameters,
      'user_id': '${userId!}',
      'access_token': accessToken.trim(),
      if (syncQuery != null) ...syncQuery,
    };
    if (forceRefresh) {
      query['_ts'] = DateTime.now().microsecondsSinceEpoch.toString();
    }

    final uri = baseUri.replace(queryParameters: query);
    logDebug('[GRID_SDUI][FETCH_SCHEMA] mode=live url=${_redactUri(uri)}');

    final response = await _client.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'Authorization': 'Bearer ${accessToken.trim()}',
      },
    ).timeout(const Duration(seconds: 30));

    logDebug(
      '[GRID_SDUI][FETCH_SCHEMA] HTTP ${response.statusCode} '
      'bytes=${response.bodyBytes.length}',
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Grid schema request failed with HTTP ${response.statusCode}.',
        _redactUri(uri),
      );
    }

    if (syncQuery != null && syncQuery.isNotEmpty) {
      try {
        final root = response.body.length > 50 * 1024
            ? await compute(_gridJsonDecodeAny, response.body)
            : jsonDecode(response.body);
        if (root is Map) {
          final map = Map<String, dynamic>.from(root.cast<dynamic, dynamic>());
          final data = map['data'] is Map
              ? Map<String, dynamic>.from(
                  (map['data'] as Map).cast<dynamic, dynamic>(),
                )
              : map;
          final looksIncremental =
              data.containsKey('patch') ||
              data.containsKey('created') ||
              data.containsKey('updated') ||
              data.containsKey('deleted') ||
              data['unchanged'] == true ||
              data['not_modified'] == true ||
              data['full_required'] == true;
          if (looksIncremental) {
            logDebug('[GRID_SDUI][FETCH_SCHEMA] INCREMENTAL ENVELOPE');
            return map;
          }
        }
      } catch (_) {}
    }

    final schema = await _decode(
      response.body,
      sourceName: _redactUri(uri).toString(),
      contentType: response.headers['content-type'],
    );

    schema['_clientGridSchemaSource'] = _redactUri(uri).toString();
    schema['_clientGridSchemaCacheHit'] = false;
    assignClientHash(schema, '_clientGridSchemaHash', rawSource: response.body);
    _memoryCache[_cacheKey] = schema;
    // Await disk write so offline open after first visit is reliable.
    await _writeDiskCache(response.body);
    return schema;
  }

  Future<Map<String, dynamic>> _decode(
    String raw, {
    required String sourceName,
    String? contentType,
  }) async {
    ensureDecodableJson(
      body: raw,
      contentType: contentType,
      source: sourceName,
    );

    final decoded = await compute(_gridJsonDecodeAny, raw);
    if (decoded is! Map) {
      throw FormatException(
        'Grid response root must be a JSON object. source=$sourceName',
      );
    }

    final root = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
    final nested = root['schema'];
    final schema = nested is Map
        ? Map<String, dynamic>.from(nested.cast<dynamic, dynamic>())
        : root;

    if (schema['components'] is! Map || schema['page'] is! Map) {
      throw FormatException(
        'Grid response is missing schema.page and schema.components. '
        'source=$sourceName',
      );
    }

    final content = root['content'] ?? schema['content'];
    if (content is Map && schema['content'] is! Map) {
      schema['content'] = Map<String, dynamic>.from(
        content.cast<dynamic, dynamic>(),
      );
    }

    return schema;
  }

  Uri _redactUri(Uri uri) {
    final query = Map<String, String>.from(uri.queryParameters);
    for (final key in query.keys.toList()) {
      if (key.toLowerCase().contains('token') ||
          key.toLowerCase().contains('key')) {
        query[key] = '***';
      }
    }
    return uri.replace(queryParameters: query);
  }

  /// Extracts the signed `grid_sso` token from any known location in [schema].
  static String? extractSsoToken(Map<String, dynamic>? schema) {
    if (schema == null) return null;

    // 1. Direct root or top-level properties
    final rootToken = schema['grid_sso']?.toString().trim();
    if (rootToken != null && rootToken.isNotEmpty) return rootToken;

    // 2. Feature cards in content
    final content = schema['content'];
    if (content is Map) {
      final cards = content['featureCards'];
      if (cards is List) {
        for (final card in cards) {
          if (card is Map) {
            final token = _ssoFromUrl(card['url']?.toString()) ??
                _ssoFromUrl(card['route']?.toString());
            if (token != null) return token;
          }
        }
      }
    }

    // 3. Actions
    final actions = schema['actions'];
    if (actions is Map) {
      for (final action in actions.values) {
        if (action is Map) {
          final dest = action['destination'];
          final token = _ssoFromUrl(action['url']?.toString()) ??
              _ssoFromUrl(action['route']?.toString()) ??
              (dest is Map ? _ssoFromUrl(dest['url']?.toString()) : null);
          if (token != null) return token;
        }
      }
    }

    // 4. Components
    final components = schema['components'];
    if (components is Map) {
      for (final comp in components.values) {
        if (comp is Map) {
          final token = _ssoFromUrl(comp['url']?.toString()) ??
              _ssoFromUrl(comp['route']?.toString());
          if (token != null) return token;
        }
      }
    }

    return null;
  }

  static String? _ssoFromUrl(String? raw) {
    if (raw == null || raw.isEmpty || !raw.contains('grid_sso=')) return null;
    final parsed = Uri.tryParse(raw);
    final token = parsed?.queryParameters['grid_sso']?.trim();
    return (token != null && token.isNotEmpty) ? token : null;
  }

  /// Resolves an authenticated URI for [targetUri]. If [targetUri] is an
  /// efactor.tech Grid or Circle Connect route and lacks `grid_sso`, this helper
  /// injects the active token from cache or fetches the live schema if needed.
  Future<Uri> resolveAuthenticatedUri(
    Uri targetUri, {
    Map<String, dynamic>? activeSchema,
  }) async {
    final host = targetUri.host.toLowerCase();
    final isEfactor = host.contains('efactor.tech');
    final path = targetUri.path.toLowerCase();
    final isGridRoute = path.contains('/grid') || path.contains('/grid-chat');

    if (!isEfactor || !isGridRoute) {
      return targetUri;
    }

    final existingSso = targetUri.queryParameters['grid_sso'];
    if (existingSso != null && existingSso.isNotEmpty) {
      return targetUri;
    }

    // 1. Try extracting from active in-memory schema
    var ssoToken = extractSsoToken(activeSchema);

    // 2. Try peekMemory
    ssoToken ??= extractSsoToken(peekMemory());

    // 3. Try reading disk cache
    if (ssoToken == null) {
      try {
        final disk = await _readDiskCache();
        ssoToken = extractSsoToken(disk);
      } catch (_) {}
    }

    // 4. If still missing, fetch live schema directly from server
    if (ssoToken == null) {
      try {
        final live = await load(forceRefresh: true);
        ssoToken = extractSsoToken(live);
      } catch (e) {
        logDebug('[GRID_SDUI][SSO_RESOLVE] Failed to fetch live schema for SSO: $e');
      }
    }

    if (ssoToken != null && ssoToken.isNotEmpty) {
      final params = Map<String, String>.from(targetUri.queryParameters);
      params['grid_sso'] = ssoToken;
      return targetUri.replace(queryParameters: params);
    }

    return targetUri;
  }

  void dispose() {
    _client.close();
  }
}
