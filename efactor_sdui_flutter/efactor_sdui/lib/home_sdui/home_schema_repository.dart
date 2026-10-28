import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../sdui/sdui_network_image_cache.dart';
import '../services/json_http.dart';
import '../services/schema_incremental_sync.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_offline.dart';
import 'home_schema_adapter.dart';
import 'home_schema_validator.dart';

dynamic _homeJsonDecodeAny(String raw) => jsonDecode(raw);

/// Home SDUI schema repository.
///
/// TEMPORARY TEST MODE:
///   HOME_SCHEMA_MODE=asset-test
///   assets/branding/home_schema_test_user655.json
///
/// Production/live mode:
///   HOME_SCHEMA_MODE=live
///   GET https://efactor.tech/v8/api_creation.php
///       ?action=get_schema
///       &user_id=<runtime authenticated user id>
///
/// Default is `live`. Use --dart-define=HOME_SCHEMA_MODE=asset-test only for
/// local dump testing.
class HomeSchemaRepository {
  HomeSchemaRepository({
    http.Client? client,
    HomeSchemaValidator? validator,
    HomeSchemaAdapter? adapter,
  }) : _client = client ?? http.Client(),
       _validator = validator ?? const HomeSchemaValidator(),
       _adapter = adapter ?? const HomeSchemaAdapter();

  static const String _schemaMode = String.fromEnvironment(
    'HOME_SCHEMA_MODE',
    defaultValue: 'live',
  );

  static const String _testAssetPath =
      'assets/branding/home_schema_test_user655.json';

  static const String _configuredUrl = String.fromEnvironment(
    'HOME_SCHEMA_URL',
    defaultValue:
        'https://efactor.tech/v8/api_creation.php?action=get_schema&user_id={userId}',
  );

  static const bool _strictLiveSecurity = bool.fromEnvironment(
    'HOME_SCHEMA_STRICT_SECURITY',
    defaultValue: false,
  );

  final http.Client _client;
  final HomeSchemaValidator _validator;
  final HomeSchemaAdapter _adapter;

  static const Duration _freshCacheRevalidateAfter = Duration(minutes: 15);
  static final Map<String, Map<String, dynamic>> _memoryCache =
      <String, Map<String, dynamic>>{};
  static final Map<String, Future<Map<String, dynamic>>> _inFlight =
      <String, Future<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> load({
    bool forceRefresh = false,
    String? accessToken,
    int? userId,
  }) async {
    final mode = _schemaMode.trim().toLowerCase();

    if (mode == 'asset-test' || mode == 'asset' || mode == 'local-test') {
      return _loadTestAsset();
    }

    if (mode != 'live' && mode != 'server') {
      throw StateError(
        'Unsupported HOME_SCHEMA_MODE "$_schemaMode". '
        'Use "asset-test" for temporary local testing or "live" for server.',
      );
    }

    final flightKey =
        '${userId ?? 0}|${forceRefresh ? 'live' : 'any'}';
    final existing = _inFlight[flightKey] ??
        (forceRefresh ? null : _inFlight['${userId ?? 0}|live']);
    if (existing != null) return existing;

    final pending = _loadLive(
      forceRefresh: forceRefresh,
      accessToken: accessToken?.trim() ?? '',
      userId: userId,
    );
    _inFlight[flightKey] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[flightKey], pending)) {
        _inFlight.remove(flightKey);
      }
    }
  }

  static bool isFreshCache(Map<String, dynamic> schema) {
    if (schema['_clientHomeSchemaCacheHit'] != true) return false;
    final raw = schema['_clientHomeSchemaCachedAtMs'];
    final savedAtMs = raw is int
        ? raw
        : raw is num
            ? raw.toInt()
            : int.tryParse(raw?.toString() ?? '');
    if (savedAtMs == null) return false;
    return DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(savedAtMs),
        ) <
        _freshCacheRevalidateAfter;
  }

  Future<Map<String, dynamic>> _loadTestAsset() async {
    logDebug('[HomeSchemaRepository] TEST ASSET LOAD $_testAssetPath');

    final raw = await rootBundle.loadString(_testAssetPath);
    final schema = await _decode(raw, 'asset://$_testAssetPath');

    // Keep the same structural validator used by the live repository. Do not
    // require a production server signature for this intentional local test.
    await _validator.validate(
      schema,
      productionSecurity: false,
      rawByteLength: utf8.encode(raw).length,
    );

    schema['_clientHomeSchemaSource'] = 'asset://$_testAssetPath';
    schema['_clientHomeSchemaMode'] = 'asset-test';
    schema['_clientHomeSchemaSecurityMode'] = 'test-structural';
    assignClientHash(schema, '_clientHomeSchemaHash');

    logDebug(
      '[HomeSchemaRepository] TEST ASSET SCHEMA LOADED '
      'selectedPath=${schema['_clientHomeSchemaSelectedPath'] ?? '-'} '
      'schemaType=${schema['schemaType'] ?? '-'} '
      'schemaVersion=${schema['schemaVersion'] ?? '-'} '
      'adapter=${schema['_clientHomeSchemaAdapter'] ?? '-'}',
    );

    return schema;
  }

  String _effectiveLiveUrl({required int? userId}) {
    var rawUrl = _configuredUrl.trim();

    if (rawUrl.isEmpty) {
      throw StateError(
        'HOME_SCHEMA_URL is empty. Home schemas are server-only.',
      );
    }

    if (rawUrl.contains('{userId}')) {
      if (userId == null || userId < 1) {
        throw StateError(
          'The Home schema endpoint requires the authenticated runtime user id.',
        );
      }
      rawUrl = rawUrl.replaceAll(
        '{userId}',
        Uri.encodeQueryComponent(userId.toString()),
      );
    }

    if (rawUrl.contains('{')) {
      throw FormatException(
        'HOME_SCHEMA_URL contains an unresolved placeholder: "$rawUrl".',
      );
    }

    return rawUrl;
  }

  static const Duration _cacheMaxAge = Duration(hours: 24);

  String _cacheKey(int? userId) {
    return 'efactor.home.server_schema.v4.user_${userId ?? 0}';
  }

  Future<Map<String, dynamic>?> _readCache({
    required int? userId,
    bool allowStale = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _cacheKey(userId);
      final savedAtMs = prefs.getInt('$key.savedAt');
      String? raw;
      try {
        raw = await SchemaDiskCache.readString('$key.json');
      } catch (error) {
        logDebug('[HomeSchemaRepository] DISK CACHE READ FAILED: $error');
      }
      raw ??= prefs.getString(key);
      if (raw == null || savedAtMs == null) return null;

      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      );
      if (age > _cacheMaxAge && !allowStale) {
        return null;
      }

      final memory = _memoryCache[key];
      if (memory != null) {
        memory['_clientHomeSchemaCacheHit'] = true;
        memory['_clientHomeSchemaCachedAtMs'] = savedAtMs;
        logDebug(
          '[HomeSchemaRepository] MEMORY HIT user=$userId age=${age.inSeconds}s',
        );
        return memory;
      }

      final schema = await _decode(raw, 'local-user-cache');

      // Cache contents must satisfy exactly the same normalized structural
      // contract as a live response. Invalid/stale cache entries are removed
      // and the caller falls through to the network.
      await _validator.validate(
        schema,
        productionSecurity: false,
        rawByteLength: utf8.encode(raw).length,
      );

      schema['_clientHomeSchemaMode'] = 'local-user-cache';
      schema['_clientHomeSchemaCacheHit'] = true;
      schema['_clientHomeSchemaCachedAtMs'] = savedAtMs;
      _memoryCache[key] = schema;
      assignClientHash(schema, '_clientHomeSchemaHash', rawSource: raw);
      logDebug(
        '[HomeSchemaRepository] CACHE HIT '
        'age=${age.inSeconds}s user=$userId '
        'adapter=${schema['_clientHomeSchemaAdapter'] ?? '-'}',
      );
      return schema;
    } catch (error) {
      logDebug('[HomeSchemaRepository] CACHE INVALID: $error');
      try {
        final prefs = await SharedPreferences.getInstance();
        final key = _cacheKey(userId);
        await prefs.remove(key);
        await prefs.remove('$key.savedAt');
        await SchemaDiskCache.remove('$key.json');
      } catch (_) {}
      return null;
    }
  }

  Future<void> _writeCache(
    String raw, {
    required int? userId,
    required Map<String, dynamic> schema,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _cacheKey(userId);
      await SchemaDiskCache.writeString('$key.json', raw);
      await prefs.remove(key);
      await prefs.setInt('$key.savedAt', DateTime.now().millisecondsSinceEpoch);
      schema['_clientHomeSchemaCachedAtMs'] =
          DateTime.now().millisecondsSinceEpoch;
      _memoryCache[key] = schema;
      await LocalSchemaManifest.record(
        schemaKey: 'home:${userId ?? 0}',
        schemaType: 'home',
        revision: _schemaRevision(schema),
        contentHash: contentHashString(raw),
        schemaVersion: schema['schemaVersion']?.toString(),
        fileName: '$key.json',
      );
      logDebug(
        '[HomeSchemaRepository] CACHE SAVED user=$userId bytes=${raw.length}',
      );
    } catch (error) {
      logDebug('[HomeSchemaRepository] CACHE SAVE ERROR: $error');
    }
  }

  int? _schemaRevision(Map<String, dynamic> schema) {
    final v = schema['revision'] ?? schema['schemaRevision'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  Future<Map<String, dynamic>?> readFromCache({
    required int? userId,
    bool allowStale = true,
  }) {
    return _readCache(userId: userId, allowStale: allowStale);
  }

  /// Already-parsed Home schema for this user in the current process.
  /// Lets the Home screen paint immediately when revisiting in-session.
  static Map<String, dynamic>? peekMemory({int? userId}) {
    final cached = _memoryCache['efactor.home.server_schema.v4.user_${userId ?? 0}'];
    if (cached == null) return null;
    cached['_clientHomeSchemaCacheHit'] = true;
    return cached;
  }

  /// Clears in-memory cache for the specified user or all users.
  static void clearMemoryCache({int? userId}) {
    if (userId != null) {
      _memoryCache.remove('efactor.home.server_schema.v4.user_$userId');
      _inFlight.remove('$userId|live');
      _inFlight.remove('$userId|any');
    } else {
      _memoryCache.clear();
      _inFlight.clear();
    }
  }

  /// Clears in-memory and persisted cache for this user on logout.
  static Future<void> clearUserCache({required int? userId}) async {
    _memoryCache.clear();
    _inFlight.clear();
    final key = 'efactor.home.server_schema.v4.user_${userId ?? 0}';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      await prefs.remove('$key.savedAt');
      await SchemaDiskCache.remove('$key.json');
      logDebug('[HomeSchemaRepository] Cleared schema cache for user=$userId');
    } catch (error) {
      logDebug('[HomeSchemaRepository] Failed to clear user schema cache: $error');
    }
  }

  /// Completely purges all in-memory and disk cached Home schemas across all users.
  static Future<void> clearAllCache() async {
    _memoryCache.clear();
    _inFlight.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('efactor.home.')).toList();
      for (final k in keys) {
        await prefs.remove(k);
        await prefs.remove('$k.savedAt');
        await SchemaDiskCache.remove('$k.json');
      }
      logDebug('[HomeSchemaRepository] Cleared all home schema caches.');
    } catch (error) {
      logDebug('[HomeSchemaRepository] Failed to clear all home schema caches: $error');
    }
  }

  Future<void> saveToCache({
    required int? userId,
    required Map<String, dynamic> schema,
  }) async {
    final raw = jsonEncode(schema);
    await _writeCache(raw, userId: userId, schema: schema);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  /// Cache-first incremental revalidation.
  ///
  /// Uses schema-declared metadata/delta endpoints when present; otherwise
  /// performs a full HTTPS fetch that advertises the last sync state via
  /// `from_revision` / `updated_after` / `base_hash` query params. On network
  /// failure the previous cache is kept and returned unchanged.
  Future<SchemaSyncResult> revalidate({
    String? accessToken,
    int? userId,
    SchemaInvalidationEvent? event,
    bool forceFull = false,
  }) async {
    final token = accessToken?.trim() ?? '';
    if (token.isEmpty) {
      throw StateError(
        'Cannot revalidate the Home schema without an access token.',
      );
    }

    final cached =
        _memoryCache[_cacheKey(userId)] ??
        await _readCache(userId: userId, allowStale: true);

    if (cached == null) {
      final full = await _fetchAndStoreLive(
        forceRefresh: true,
        accessToken: token,
        userId: userId,
      );
      return SchemaSyncResult(
        schema: full,
        changed: true,
        usedDelta: false,
        source: 'full-no-cache',
      );
    }

    final hasDeltaEndpoints = cached['metadataEndpoint'] != null ||
        cached['deltaEndpoint'] != null;

    try {
      if (forceFull || !hasDeltaEndpoints) {
        final full = await _fetchAndStoreLive(
          forceRefresh: true,
          accessToken: token,
          userId: userId,
        );
        final changed =
            schemaFingerprint(cached) != schemaFingerprint(full);
        return SchemaSyncResult(
          schema: changed ? full : cached,
          changed: changed,
          usedDelta: false,
          source: forceFull ? 'full-forced' : 'full-no-delta-endpoints',
        );
      }

      return await SchemaIncrementalSync.revalidate(
        client: _client,
        localSchema: cached,
        accessToken: token,
        event: event,
        forceFull: forceFull,
        logTag: 'HomeSchemaSync',
        persist: (schema) async {
          schema['_clientHomeSchemaMode'] = schema['_clientHomeSchemaMode'] ??
              'incremental-sync';
          schema['_clientHomeSchemaCacheHit'] = true;
          schema['_clientHomeSchemaCachedAtMs'] =
              DateTime.now().millisecondsSinceEpoch;
          assignClientHash(schema, '_clientHomeSchemaHash');
          _memoryCache[_cacheKey(userId)] = schema;
          await saveToCache(userId: userId, schema: schema);
        },
        fetchFull: ({Map<String, String>? syncQuery}) async {
          return _fetchAndStoreLive(
            forceRefresh: true,
            accessToken: token,
            userId: userId,
            syncQuery: syncQuery,
          );
        },
      );
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      logDebug(
        '[HomeSchemaRepository] REVALIDATE OFFLINE — keeping cached schema',
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
    required String accessToken,
    required int? userId,
  }) async {
    if (accessToken.isEmpty) {
      throw StateError(
        'Cannot load the live Home schema because the authenticated access '
        'token is empty.',
      );
    }

    if (!forceRefresh) {
      final memory = _memoryCache[_cacheKey(userId)];
      if (memory != null) {
        memory['_clientHomeSchemaCacheHit'] = true;
        logDebug('[HomeSchemaRepository] MEMORY HIT user=$userId');
        return memory;
      }
      final cached = await _readCache(userId: userId, allowStale: true);
      if (cached != null) return cached;
    }

    try {
      return await _fetchAndStoreLive(
        forceRefresh: forceRefresh,
        accessToken: accessToken,
        userId: userId,
      );
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      final stale = await _readCache(userId: userId, allowStale: true);
      if (stale == null) rethrow;
      logDebug('[HomeSchemaRepository] OFFLINE FALLBACK to saved schema');
      return stale;
    }
  }

  Future<Map<String, dynamic>> _fetchAndStoreLive({
    required bool forceRefresh,
    required String accessToken,
    required int? userId,
    Map<String, String>? syncQuery,
  }) async {
    final rawUrl = _effectiveLiveUrl(userId: userId);
    final base = Uri.tryParse(rawUrl);

    if (base == null ||
        !base.hasScheme ||
        base.host.isEmpty ||
        base.scheme.toLowerCase() != 'https') {
      throw FormatException(
        'Home schema URL must be an absolute HTTPS URL; got "$rawUrl".',
      );
    }

    final query = <String, String>{
      ...base.queryParameters,
      if (syncQuery != null) ...syncQuery,
      if (forceRefresh) '_ts': DateTime.now().microsecondsSinceEpoch.toString(),
    };

    final requestUri = base.replace(queryParameters: query);

    logDebug('[HomeSchemaRepository] LIVE GET ${_redactUri(requestUri)}');

    final response = await _client
        .get(
          requestUri,
          headers: <String, String>{
            'Accept': 'application/json',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
            'Authorization': 'Bearer $accessToken',
          },
        )
        .timeout(const Duration(seconds: 30));

    logDebug(
      '[HomeSchemaRepository] HTTP ${response.statusCode} '
      'bytes=${response.bodyBytes.length}',
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Home schema request failed with HTTP ${response.statusCode}.',
        _redactUri(requestUri),
      );
    }

    // Incremental envelope from a sync-aware full endpoint.
    if (syncQuery != null && syncQuery.isNotEmpty) {
      try {
        final root = response.body.length > 50 * 1024
            ? await compute(_homeJsonDecodeAny, response.body)
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
            logDebug(
              '[HomeSchemaRepository] INCREMENTAL ENVELOPE on full URL',
            );
            return map;
          }
        }
      } catch (_) {
        // Fall through to normal schema decode.
      }
    }

    final schema = await _decode(
      response.body,
      _redactUri(requestUri).toString(),
      contentType: response.headers['content-type'],
    );

    await _validator.validate(
      schema,
      productionSecurity: _strictLiveSecurity,
      rawByteLength: response.bodyBytes.length,
    );

    schema['_clientHomeSchemaSource'] = _redactUri(requestUri).toString();
    schema['_clientHomeSchemaMode'] = 'live-server-only';
    schema['_clientHomeSchemaSecurityMode'] = _strictLiveSecurity
        ? 'production-strict'
        : 'production-structural';
    assignClientHash(
      schema,
      '_clientHomeSchemaHash',
      rawSource: response.body,
    );

    logDebug(
      '[HomeSchemaRepository] LIVE SCHEMA LOADED '
      'source=${_redactUri(requestUri)} '
      'bytes=${response.bodyBytes.length} '
      'hash=${schema['_clientHomeSchemaHash']} '
      'selectedPath=${schema['_clientHomeSchemaSelectedPath'] ?? '-'} '
      'schemaType=${schema['schemaType'] ?? '-'} '
      'schemaVersion=${schema['schemaVersion'] ?? '-'} '
      'adapter=${schema['_clientHomeSchemaAdapter'] ?? '-'}',
    );

    _memoryCache[_cacheKey(userId)] = schema;
    unawaited(_writeCache(response.body, userId: userId, schema: schema));
    return schema;
  }

  Future<Map<String, dynamic>> _decode(
    String raw,
    String source, {
    String? contentType,
  }) async {
    ensureDecodableJson(body: raw, contentType: contentType, source: source);
    dynamic decoded;

    try {
      decoded = await compute(_homeJsonDecodeAny, raw);
    } on FormatException catch (error) {
      throw FormatException(
        'Home API did not return valid JSON. source=$source; '
        '${error.message}',
      );
    }

    if (decoded is! Map) {
      throw FormatException(
        'Home API root must be a JSON object. source=$source',
      );
    }

    final root = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());

    final success = root['success'];
    if (success == false) {
      final message = root['message']?.toString().trim();
      throw StateError(
        'Home schema API returned success=false'
        '${message == null || message.isEmpty ? '' : ': $message'}',
      );
    }

    Map<String, dynamic>? accept(dynamic value, String path) {
      final candidate = _decodeMapOrJsonString(value);
      if (candidate == null || candidate.isEmpty) return null;
      if (!_adapter.supports(candidate)) return null;

      final normalized = _adapter.normalize(candidate);
      normalized['_clientHomeSchemaSelectedPath'] = path;
      return normalized;
    }

    // Prefer the documented response locations, but only when the object has
    // enough Home-schema capabilities to be normalized. A wrapper called
    // "schema" is no longer accepted merely because it is non-empty.
    final direct = accept(root['schema'], r'$.schema');
    if (direct != null) return direct;

    final data = _map(root['data']);
    if (data != null) {
      for (final key in const <String>['schema', 'schema_json', 'schemaJson']) {
        final nested = accept(data[key], r'$.data.' + key);
        if (nested != null) return nested;
      }
    }

    for (final key in const <String>['schema_json', 'schemaJson']) {
      final nested = accept(root[key], r'$.' + key);
      if (nested != null) return nested;
    }

    // Some endpoints return the schema itself as the root object.
    final rootSchema = accept(root, r'$');
    if (rootSchema != null) return rootSchema;

    final selected = _locateSchema(root);
    if (selected != null) {
      final path = selected['_clientHomeSchemaSelectedPath']?.toString() ?? r'$';
      final normalized = _adapter.normalize(selected);
      normalized['_clientHomeSchemaSelectedPath'] = path;
      return normalized;
    }

    final topKeys = root.keys.take(20).join(', ');
    final message = root['message']?.toString().trim();

    throw FormatException(
      'Home schema API response does not contain a supported Home SDUI '
      'schema. source=$source; topLevelKeys=[$topKeys]'
      '${message == null || message.isEmpty ? '' : '; message=$message'}',
    );
  }

  Map<String, dynamic>? _decodeMapOrJsonString(dynamic value) {
    final mapped = _map(value);
    if (mapped != null) return mapped;

    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      try {
        return _map(jsonDecode(trimmed));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Map<String, dynamic>? _locateSchema(dynamic root) {
    final candidates = <_SchemaCandidate>[];

    void visit(dynamic value, String path, int depth) {
      if (value == null || depth > 16) return;

      if (value is String) {
        final trimmed = value.trim();
        if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
            (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
          try {
            visit(jsonDecode(trimmed), '$path<json>', depth + 1);
          } catch (_) {}
        }
        return;
      }

      if (value is List) {
        for (var i = 0; i < value.length; i++) {
          visit(value[i], '$path[$i]', depth + 1);
        }
        return;
      }

      if (value is! Map) return;

      final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());

      final score = _capabilityScore(map);
      if (score > 0) {
        candidates.add(_SchemaCandidate(path: path, schema: map, score: score));
      }

      for (final entry in map.entries) {
        final child = entry.value;
        if (child is Map || child is List || child is String) {
          visit(child, '$path.${entry.key}', depth + 1);
        }
      }
    }

    visit(root, r'$', 0);

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.path.length.compareTo(b.path.length);
    });

    final selected = candidates.first;
    if (selected.score < 100) return null;

    selected.schema['_clientHomeSchemaSelectedPath'] = selected.path;
    return selected.schema;
  }

  int _capabilityScore(Map<String, dynamic> map) {
    var score = 0;

    final schemaType = map['schemaType']?.toString().trim();
    if (schemaType == 'server-driven-mobile-app') score += 300;
    if (_adapter.supports(map)) score += 220;
    if (map['schemaVersion'] != null) score += 20;
    if (map['schemaId'] != null) score += 20;
    if (map['components'] is Map && (map['components'] as Map).isNotEmpty) {
      score += 120;
    }
    if (map['pages'] is Map && (map['pages'] as Map).isNotEmpty) score += 100;
    if (map['routes'] is Map && (map['routes'] as Map).isNotEmpty) score += 80;
    if (map['actionRegistry'] is Map) score += 70;
    if (map['rendererRequirements'] is Map) score += 50;
    if (map['designTokens'] is Map) score += 30;
    if (map['state'] is Map) score += 25;
    if (map['navigation'] is Map) score += 25;
    if (map['appShell'] is Map) score += 25;
    if (map['componentDefinitions'] is Map) score += 20;

    final meta = _map(map['meta']);
    final layoutSnapshot = _map(meta?['layoutSnapshot']);
    if (layoutSnapshot != null) {
      if (layoutSnapshot['cards'] is List) score += 50;
      if (layoutSnapshot['theme'] is Map) score += 20;
    }

    final ui = _map(map['ui']);
    if (_map(ui?['widgetTree']) != null) score += 60;
    if (map['cards'] is List) score += 35;

    return score;
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  Uri _redactUri(Uri uri) {
    final query = <String, String>{...uri.queryParameters};
    for (final key in query.keys.toList()) {
      if (key.toLowerCase().contains('token')) {
        query[key] = '<redacted>';
      }
    }
    return uri.replace(queryParameters: query);
  }

  void dispose() {
    _client.close();
  }
}

class _SchemaCandidate {
  const _SchemaCandidate({
    required this.path,
    required this.schema,
    required this.score,
  });

  final String path;
  final Map<String, dynamic> schema;
  final int score;
}
