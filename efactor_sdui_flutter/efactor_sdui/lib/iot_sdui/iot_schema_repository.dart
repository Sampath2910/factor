import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../services/device_page_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/json_http.dart';
import '../services/schema_incremental_sync.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_offline.dart';
import '../sdui/sdui_network_image_cache.dart';

// Top-level functions required for compute() — must not be closures.
dynamic _iotJsonDecodeAny(String raw) => jsonDecode(raw);

/// IoT SDUI server source configuration.
///
/// Live server source configuration. Temporary asset-test mode is handled
/// by [IotSchemaRepository] and does not change this source contract.
class IotSchemaSource {
  const IotSchemaSource({this.url, this.apiBaseUrl});

  final String? url;
  final String? apiBaseUrl;

  static const String _environmentUrl = String.fromEnvironment(
    'IOT_SCHEMA_URL',
    defaultValue:
        'https://efactor.tech/v8/iot_api_creation.php?action=get_iot_schema',
  );

  static const String _environmentApiBaseUrl = String.fromEnvironment(
    'IOT_API_BASE_URL',
    defaultValue: 'https://efactor.tech',
  );

  factory IotSchemaSource.fromEnvironment() {
    return IotSchemaSource(
      url: _environmentUrl.trim().isEmpty ? null : _environmentUrl.trim(),
      apiBaseUrl: _environmentApiBaseUrl.trim().isEmpty
          ? null
          : _environmentApiBaseUrl.trim(),
    );
  }

  /// Accepts a server-provided IoT schema source when one is present.
  /// Missing fields fall back to the live environment endpoint. Temporary
  /// asset-test mode bypasses this URL only inside [IotSchemaRepository].
  factory IotSchemaSource.fromMap(Map<String, dynamic> map) {
    String? firstNonEmpty(Iterable<dynamic> values) {
      for (final value in values) {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
      return null;
    }

    final live = IotSchemaSource.fromEnvironment();
    final mappedUrl = firstNonEmpty(<dynamic>[
      map['url'],
      map['schemaUrl'],
      map['schema_url'],
      map['endpoint'],
    ]);
    final mappedBase = firstNonEmpty(<dynamic>[
      map['apiBaseUrl'],
      map['api_base_url'],
      map['baseUrl'],
      map['base_url'],
    ]);

    return IotSchemaSource(
      url: mappedUrl ?? live.url,
      apiBaseUrl: mappedBase ?? live.apiBaseUrl,
    );
  }

  Uri? get resolvedApiBaseUri {
    final explicit = apiBaseUrl?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      final uri = Uri.tryParse(explicit);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        return uri;
      }
    }

    final schemaUrl = url?.trim();
    if (schemaUrl != null && schemaUrl.isNotEmpty) {
      final uri = Uri.tryParse(schemaUrl);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        return uri.replace(path: '/', query: null, fragment: null);
      }
    }

    return null;
  }
}

/// Capability-driven IoT schema loader.
///
/// TEMPORARY TEST MODE:
///   IOT_SCHEMA_MODE=asset-test
///   assets/iot_schema_test.json
///
/// Live mode:
///   IOT_SCHEMA_MODE=live
///   Uses the existing server endpoint from [IotSchemaSource].
///
/// The asset path is only for temporary schema testing. Rendering, actions,
/// datasource execution, device control and API resolution remain unchanged.
class IotSchemaRepository {
  static const String _schemaMode = String.fromEnvironment(
    'IOT_SCHEMA_MODE',
    defaultValue: 'live',
  );

  static const String _testAssetPath = 'assets/iot_schema_test.json';
  IotSchemaRepository({
    required this.source,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const Duration _cacheMaxAge = Duration(hours: 24);
  static const Duration _freshCacheRevalidateAfter = Duration(minutes: 15);
  static final Map<String, Future<Map<String, dynamic>>> _inFlight =
      <String, Future<Map<String, dynamic>>>{};
  static final Map<String, Map<String, dynamic>> _memoryCache =
      <String, Map<String, dynamic>>{};

  final IotSchemaSource source;
  final String accessToken;
  final http.Client _client;

  Future<Map<String, dynamic>> load({bool forceRefresh = false}) async {
    final mode = _schemaMode.trim().toLowerCase();

    if (mode == 'asset-test' || mode == 'asset' || mode == 'local-test') {
      return _loadTestAsset();
    }

    if (mode != 'live' && mode != 'server') {
      throw StateError(
        'Unsupported IOT_SCHEMA_MODE "$_schemaMode". '
        'Use "asset-test" for temporary local schema testing or "live" '
        'for the server schema.',
      );
    }

    if (accessToken.trim().isEmpty) {
      throw StateError(
        'IoT live schema request requires the current authenticated access token.',
      );
    }

    final flightKey =
        '${source.url ?? ''}|${accessToken.trim()}|${forceRefresh ? 'live' : 'any'}';
    final existing = _inFlight[flightKey] ??
        (forceRefresh ? null : _inFlight['${source.url ?? ''}|${accessToken.trim()}|live']);
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

  static bool isFreshCache(Map<String, dynamic> schema) {
    if (schema['_clientIotSchemaCacheHit'] != true) return false;
    final raw = schema['_clientIotSchemaCachedAtMs'];
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

  Future<Map<String, dynamic>> _loadUncoalesced({
    required bool forceRefresh,
  }) async {
    if (!forceRefresh) {
      final memory = _memoryCache[_cacheKey];
      if (memory != null) {
        memory['_clientIotSchemaCacheHit'] = true;
        logDebug('[IOT_SDUI][FETCH_SCHEMA] MEMORY HIT');
        return memory;
      }
      final cached = await _readCache(allowStale: true);
      if (cached != null) return cached;
    }

    try {
      return await _loadLive(forceRefresh: forceRefresh);
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      final stale = await _readCache(allowStale: true);
      if (stale == null) rethrow;
      logDebug('[IOT_SDUI][FETCH_SCHEMA] OFFLINE FALLBACK to saved schema');
      return stale;
    }
  }

  Future<Map<String, dynamic>> _loadTestAsset() async {
    logDebug(
      '[IOT_SDUI][FETCH_SCHEMA] mode=asset-test asset=$_testAssetPath',
    );

    final raw = await rootBundle.loadString(_testAssetPath);

    final decoded = await _decode(raw, sourceName: 'asset://$_testAssetPath');

    _validateCapabilities(decoded.schema);

    decoded.schema['_clientIotSchemaMode'] = 'asset-test';
    decoded.schema['_clientIotSchemaCacheHit'] = false;
    decoded.schema['_clientIotSchemaSource'] = 'asset://$_testAssetPath';
    assignClientHash(
      decoded.schema,
      '_clientIotSchemaHash',
      rawSource: raw,
    );

    _log(decoded, mode: 'asset-test');
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(decoded.schema));

    return decoded.schema;
  }

  Future<Map<String, dynamic>> _loadLive({
    required bool forceRefresh,
    Map<String, String>? syncQuery,
  }) async {
    final rawUrl = source.url?.trim() ?? '';
    if (rawUrl.isEmpty) {
      throw const FormatException(
        'IOT_SCHEMA_URL is empty. IoT schemas are server-only; configure the '
        'live IoT schema endpoint instead of using an asset.',
      );
    }

    final baseUri = Uri.tryParse(rawUrl);
    if (baseUri == null ||
        !baseUri.hasScheme ||
        baseUri.host.isEmpty ||
        baseUri.scheme.toLowerCase() != 'https') {
      throw const FormatException(
        'IOT_SCHEMA_URL must be an absolute HTTPS URL.',
      );
    }

    final token = accessToken.trim();
    if (token.isEmpty) {
      throw StateError(
        'IoT live schema request requires the current authenticated access '
        'token.',
      );
    }

    final query = <String, String>{
      ...baseUri.queryParameters,
      'access_token': token,
      if (syncQuery != null) ...syncQuery,
    };

    if (forceRefresh) {
      query['_ts'] = DateTime.now().microsecondsSinceEpoch.toString();
    }

    final uri = baseUri.replace(queryParameters: query);

    logDebug('[IOT_SDUI][FETCH_SCHEMA] mode=live url=${_redactUri(uri)}');

    final response = await _client
        .get(
          uri,
          headers: const <String, String>{
            'Accept': 'application/json',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(seconds: 30));

    logDebug(
      '[IOT_SDUI][FETCH_SCHEMA] HTTP ${response.statusCode} '
      'bytes=${response.bodyBytes.length}',
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'IoT schema request failed with HTTP ${response.statusCode}.',
        _redactUri(uri),
      );
    }

    if (syncQuery != null && syncQuery.isNotEmpty) {
      try {
        final root = response.body.length > 50 * 1024
            ? await compute(_iotJsonDecodeAny, response.body)
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
            logDebug('[IOT_SDUI][FETCH_SCHEMA] INCREMENTAL ENVELOPE');
            return map;
          }
        }
      } catch (_) {}
    }

    final decoded = await _decode(
      response.body,
      sourceName: _redactUri(uri).toString(),
      contentType: response.headers['content-type'],
    );

    _validateCapabilities(decoded.schema);
    decoded.schema['_clientIotSchemaMode'] = 'live-server-only';
    decoded.schema['_clientIotSchemaCacheHit'] = false;
    decoded.schema['_clientIotSchemaCachedAtMs'] =
        DateTime.now().millisecondsSinceEpoch;
    assignClientHash(
      decoded.schema,
      '_clientIotSchemaHash',
      rawSource: response.body,
    );
    _log(decoded, mode: 'live');

    _memoryCache[_cacheKey] = decoded.schema;
    unawaited(_writeCache(decoded.schema, raw: response.body));
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(decoded.schema));
    return decoded.schema;
  }

  Future<Map<String, dynamic>?> readFromCache({bool allowStale = true}) {
    return _readCache(allowStale: allowStale);
  }

  /// Already-parsed IoT schema for this source URL in the current process.
  Map<String, dynamic>? peekMemory() {
    final cached = _memoryCache[_cacheKey];
    if (cached == null) return null;
    cached['_clientIotSchemaCacheHit'] = true;
    return cached;
  }

  Future<void> saveToCache(Map<String, dynamic> schema) async {
    final raw = jsonEncode(schema);
    schema['_clientIotSchemaCachedAtMs'] =
        DateTime.now().millisecondsSinceEpoch;
    await _writeCache(schema, raw: raw);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  /// Cache-first incremental revalidation for IoT schemas.
  Future<SchemaSyncResult> revalidate({
    SchemaInvalidationEvent? event,
    bool forceFull = false,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw StateError(
        'Cannot revalidate the IoT schema without an access token.',
      );
    }

    final cached =
        _memoryCache[_cacheKey] ?? await _readCache(allowStale: true);

    if (cached == null) {
      final full = await _loadLive(forceRefresh: true);
      return SchemaSyncResult(
        schema: full,
        changed: true,
        usedDelta: false,
        source: 'full-no-cache',
      );
    }

    try {
      return await SchemaIncrementalSync.revalidate(
        client: _client,
        localSchema: cached,
        accessToken: token,
        event: event,
        forceFull: forceFull,
        logTag: 'IotSchemaSync',
        persist: (schema) async {
          schema['_clientIotSchemaMode'] =
              schema['_clientIotSchemaMode'] ?? 'incremental-sync';
          schema['_clientIotSchemaCacheHit'] = true;
          assignClientHash(schema, '_clientIotSchemaHash');
          await saveToCache(schema);
        },
        fetchFull: ({Map<String, String>? syncQuery}) async {
          return _loadLive(forceRefresh: true, syncQuery: syncQuery);
        },
      );
    } catch (error) {
      if (!isTransientNetworkFailure(error)) rethrow;
      logDebug(
        '[IOT_SDUI][FETCH_SCHEMA] REVALIDATE OFFLINE — keeping cached schema',
      );
      return SchemaSyncResult(
        schema: cached,
        changed: false,
        usedDelta: false,
        source: 'offline-cache-retained',
      );
    }
  }

  String get _cacheKey {
    final rawUrl = source.url?.trim() ?? '';
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(rawUrl)) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return 'efactor.iot.server_schema.v2.${hash.toRadixString(16)}';
  }

  Future<Map<String, dynamic>?> _readCache({bool allowStale = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKey;
    var savedAtMs = prefs.getInt('$key.savedAt');
    String? raw;
    try {
      raw = await SchemaDiskCache.readString('$key.json');
    } catch (error) {
      logDebug('[IOT_SDUI][FETCH_SCHEMA] DISK CACHE READ FAILED: $error');
    }
    raw ??= prefs.getString(key);
    savedAtMs ??= await SchemaDiskCache.modifiedAtMs('$key.json');
    if (raw == null || savedAtMs == null) return null;

    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(savedAtMs),
    );
    if (age > _cacheMaxAge && !allowStale) {
      return null;
    }

    try {
      final decoded = await _decode(raw, sourceName: 'validated-server-cache');
      _validateCapabilities(decoded.schema);
      decoded.schema['_clientIotSchemaMode'] = age > _cacheMaxAge
          ? 'validated-server-cache-stale'
          : 'validated-server-cache';
      decoded.schema['_clientIotSchemaCacheHit'] = true;
      decoded.schema['_clientIotSchemaCachedAtMs'] = savedAtMs;
      assignClientHash(
        decoded.schema,
        '_clientIotSchemaHash',
        rawSource: raw,
      );
      _memoryCache[key] = decoded.schema;
      unawaited(SduiNetworkImageCache.prefetchSchemaImages(decoded.schema));
      logDebug(
        '[IOT_SDUI][FETCH_SCHEMA] CACHE HIT '
        'age=${age.inSeconds}s stale=${age > _cacheMaxAge}',
      );
      return decoded.schema;
    } catch (error) {
      logDebug('[IOT_SDUI][FETCH_SCHEMA] CACHE INVALID: $error');
      await prefs.remove(key);
      await prefs.remove('$key.savedAt');
      try {
        await SchemaDiskCache.remove('$key.json');
      } catch (_) {}
      return null;
    }
  }

  Future<void> _writeCache(Map<String, dynamic> schema, {required String raw}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _cacheKey;
      await SchemaDiskCache.writeString('$key.json', raw);
      await prefs.remove(key);
      await prefs.setInt('$key.savedAt', DateTime.now().millisecondsSinceEpoch);
      _memoryCache[key] = schema;
      unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
      logDebug(
        '[IOT_SDUI][FETCH_SCHEMA] CACHE SAVED bytes=${raw.length}',
      );
    } catch (error) {
      logDebug('[IOT_SDUI][FETCH_SCHEMA] DISK CACHE SAVE FAILED: $error');
    }
  }

  /// Clears in-memory and persisted IoT schemas on logout.
  static Future<void> clearCache() async {
    _memoryCache.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('efactor.iot.server_schema.v2.')) {
          await prefs.remove(key);
          await prefs.remove('$key.savedAt');
          await SchemaDiskCache.remove('$key.json');
        }
      }
      logDebug('[IotSchemaRepository] Cleared IoT schema cache');
    } catch (error) {
      logDebug('[IotSchemaRepository] Failed to clear IoT schema cache: $error');
    }
  }

  Future<_DecodedSchema> _decode(
    String raw, {
    required String sourceName,
    String? contentType,
  }) async {
    ensureDecodableJson(
      body: raw,
      contentType: contentType,
      source: sourceName,
    );

    dynamic decoded;

    try {
      // Parse IoT schema JSON on a background isolate to keep UI thread free.
      decoded = await compute(_iotJsonDecodeAny, raw);
    } on FormatException catch (error) {
      throw FormatException(
        'IoT response is not valid JSON. source=$sourceName; '
        '${error.message}',
      );
    }

    final root = _map(decoded);
    if (root == null) {
      throw FormatException(
        'IoT response root must be a JSON object. source=$sourceName',
      );
    }

    final wrapperVersion = _firstNonEmptyString(<dynamic>[
      root['schema_version'],
      root['schemaVersion'],
      _map(root['meta'])?['schema_version'],
      _map(root['meta'])?['schemaVersion'],
    ]);

    final candidates = <_SchemaCandidate>[];
    _collectCandidates(root, candidates, path: r'$', depth: 0);

    if (candidates.isEmpty) {
      throw FormatException(
        'No renderable IoT SDUI object was found in $sourceName. '
        'Required structural capabilities include page{} and components[].',
      );
    }

    candidates.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return a.depth.compareTo(b.depth);
    });

    final selected = candidates.first;

    logDebug(
      '[IOT_SDUI][DECODE] selectedPath=${selected.path} '
      'score=${selected.score} candidates=${candidates.length}',
    );

    return _DecodedSchema(
      schema: selected.value,
      wrapperVersion: wrapperVersion,
      selectedPath: selected.path,
    );
  }

  void _collectCandidates(
    dynamic value,
    List<_SchemaCandidate> output, {
    required String path,
    required int depth,
  }) {
    if (value == null || depth > 12) return;

    if (value is Map) {
      final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());

      final score = _capabilityScore(map);
      if (score > 0) {
        output.add(
          _SchemaCandidate(value: map, path: path, depth: depth, score: score),
        );
      }

      for (final entry in map.entries) {
        final childPath = '$path.${entry.key}';
        final child = entry.value;

        if (child is Map || child is List) {
          _collectCandidates(child, output, path: childPath, depth: depth + 1);
          continue;
        }

        if (child is String && child.trim().isNotEmpty) {
          final key = entry.key.toLowerCase();
          if (key.contains('schema') || key == 'payload' || key == 'data') {
            try {
              final nested = jsonDecode(child);
              _collectCandidates(
                nested,
                output,
                path: '$childPath(json)',
                depth: depth + 1,
              );
            } catch (_) {
              // Plain string; not nested JSON.
            }
          }
        }
      }
      return;
    }

    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _collectCandidates(
          value[i],
          output,
          path: '$path[$i]',
          depth: depth + 1,
        );
      }
    }
  }

  int _capabilityScore(Map<String, dynamic> map) {
    var score = 0;

    final page = _map(map['page']);
    final components = map['components'] ?? page?['components'];

    if (page != null) score += 120;
    if (components is List && components.isNotEmpty) score += 180;
    if (_map(map['theme']) != null || _map(page?['theme']) != null) {
      score += 45;
    }
    if (_map(map['layout']) != null) score += 30;
    if (_map(map['typography']) != null) score += 25;
    if (_map(map['icons']) != null) score += 25;
    if (_map(map['dataSources']) != null ||
        _map(page?['dataSources']) != null) {
      score += 35;
    }
    if (map['devices'] is List) score += 35;

    // Version/kind may help identify metadata but never drive rendering.
    if (map.containsKey('schemaVersion')) score += 5;
    if (map.containsKey('kind')) score += 5;

    // API wrappers must not outscore their nested schema.
    if (map.containsKey('success') && map.containsKey('schema')) {
      score -= 100;
    }

    return score;
  }

  void _validateCapabilities(Map<String, dynamic> schema) {
    final page = _map(schema['page']);
    if (page == null) {
      throw const FormatException('Missing IoT rendering capability: page{}.');
    }

    final components = schema['components'] ?? page['components'];
    if (components is! List || components.isEmpty) {
      throw const FormatException(
        'Missing IoT rendering capability: components[].',
      );
    }
  }

  void _log(_DecodedSchema decoded, {required String mode}) {
    final schema = decoded.schema;
    final page = _map(schema['page']);
    final components = schema['components'] ?? page?['components'];
    final devices = schema['devices'];
    final theme = _map(schema['theme']) ?? _map(page?['theme']);

    logDebug(
      '[IOT_SDUI][SCHEMA] '
      'mode=$mode '
      'selectedPath=${decoded.selectedPath} '
      'wrapperVersion=${decoded.wrapperVersion ?? '-'} '
      'schemaVersion=${schema['schemaVersion'] ?? '-'} '
      'kind=${schema['kind'] ?? '-'} '
      'theme=${theme != null} '
      'components=${components is List ? components.length : 0} '
      'devices=${devices is List ? devices.length : 0}',
    );
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

  String? _firstNonEmptyString(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  void dispose() {
    _client.close();
  }
}

class _SchemaCandidate {
  const _SchemaCandidate({
    required this.value,
    required this.path,
    required this.depth,
    required this.score,
  });

  final Map<String, dynamic> value;
  final String path;
  final int depth;
  final int score;
}

class _DecodedSchema {
  const _DecodedSchema({
    required this.schema,
    required this.wrapperVersion,
    required this.selectedPath,
  });

  final Map<String, dynamic> schema;
  final String? wrapperVersion;
  final String selectedPath;
}

/// Local copy of every page schema for every model the user opens.
///
/// Backed by [DevicePageCacheManager] which saves completely validated pages
/// to disk atomically, syncs remaining pages sequentially in the background
/// with cooperative yielding, and silently updates without blocking the UI.
class ModelSchemaCache {
  ModelSchemaCache._();

  static final ModelSchemaCache instance = ModelSchemaCache._();

  Future<void> open() async {
    // Disk storage is initialized on-demand.
  }

  /// Saves every page for [modelId] / [nodeId] sequentially.
  Future<List<int>> syncModel({
    required String modelId,
    required String nodeId,
    int activePageNo = 1,
    void Function(int pageNo, Map<String, dynamic> updatedSchema)? onPageUpdated,
  }) {
    return DevicePageCacheManager.instance.syncModelPagesSequentially(
      modelId: modelId,
      nodeId: nodeId,
      activePageNo: activePageNo,
      onPageUpdated: onPageUpdated,
    );
  }
}

