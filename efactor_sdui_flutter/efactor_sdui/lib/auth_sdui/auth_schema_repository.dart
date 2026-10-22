import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/json_http.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_offline.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'auth_json_patch.dart';
import 'auth_schema_cache.dart';
import 'auth_temporary_api_overlay.dart';

class AuthSchemaSyncResult {
  const AuthSchemaSyncResult({
    required this.schema,
    required this.changed,
    required this.usedDelta,
    required this.source,
  });

  final Map<String, dynamic> schema;
  final bool changed;
  final bool usedDelta;
  final String source;
}

/// Loads and synchronizes the Authentication SDUI schema.
///
/// Production behavior for schemas that publish the v8 synchronization
/// contract:
/// - first successful fetch -> validate + persist the full schema locally;
/// - later app starts -> render the validated local schema immediately;
/// - revalidation -> call the schema-declared lightweight metadata endpoint;
/// - changed revision -> apply the schema-declared delta when it is a valid
///   RFC-6902-style patch, otherwise fall back to the full schema;
/// - WebSocket remains notify-only; this repository always obtains the
///   authoritative schema/delta over HTTPS.
///
/// Older schemas remain compatible. If they do not allow persistent caching or
/// do not declare sync endpoints, the repository falls back to the existing
/// full HTTPS schema fetch.
class AuthSchemaRepository {
  AuthSchemaRepository({http.Client? client, AuthSchemaCache? cache})
    : _client = client ?? http.Client(),
      _cache = cache ?? AuthSchemaCache();

  static const String _configuredUrl = String.fromEnvironment(
    'AUTH_SCHEMA_URL',
    defaultValue: 'https://efactor.tech/v8/api_auth_schema.php',
  );

  static const int _timeoutMs = int.fromEnvironment(
    'AUTH_SCHEMA_TIMEOUT_MS',
    defaultValue: 30000,
  );

  final http.Client _client;
  final AuthSchemaCache _cache;

  /// Cached-first load used at app startup.
  ///
  /// `forceRefresh=true` is reserved for explicit retry/full-refresh paths and
  /// bypasses the local schema cache.
  Future<Map<String, dynamic>> load({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _readUsableCache();
      if (cached != null) {
        return _finalize(
          _cloneMap(cached.schema),
          source: 'local-auth-schema-cache',
          cacheHit: true,
        );
      }

      final bundled = await _loadBundledAsset();
      if (bundled != null) {
        return _finalize(
          _cloneMap(bundled),
          source: 'asset://assets/auth_ui_schema.json',
          cacheHit: true,
        );
      }
    }

    try {
      final canonical = await _fetchFullCanonical(forceRefresh: forceRefresh);
      await _storeIfAllowed(canonical);
      return _finalize(
        _cloneMap(canonical),
        source: _fullSchemaUri(canonical).toString(),
        cacheHit: false,
      );
    } catch (error) {
      final bundled = await _loadBundledAsset();
      if (bundled != null) {
        return _finalize(
          _cloneMap(bundled),
          source: 'asset://assets/auth_ui_schema.json-fallback',
          cacheHit: true,
        );
      }
      if (!isTransientNetworkFailure(error)) rethrow;
      final stale = await _readUsableCache(allowStale: true);
      if (stale == null) rethrow;
      debugPrint('[AuthSchemaRepository] OFFLINE FALLBACK to saved schema');
      return _finalize(
        _cloneMap(stale.schema),
        source: 'local-auth-schema-cache-stale',
        cacheHit: true,
      );
    }
  }

  Future<Map<String, dynamic>?> _loadBundledAsset() async {
    try {
      final raw = await rootBundle.loadString('assets/auth_ui_schema.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
        final schema = _asMap(map['schema']) ?? map;
        await _storeIfAllowed(schema);
        return schema;
      }
    } catch (e) {
      debugPrint('[AuthSchemaRepository] Bundled asset load error: $e');
    }
    return null;
  }

  /// Revalidates the cached Auth schema using only the contracts declared by
  /// the currently cached schema.
  ///
  /// If a delta is unavailable, malformed, unverifiable, or rejected by the
  /// backend, a full HTTPS fetch is used automatically. A failed patch is never
  /// written to disk.
  Future<AuthSchemaSyncResult> revalidate({
    SchemaInvalidationEvent? event,
    String? accessToken,
    bool forceFull = false,
  }) async {
    final cached = await _readUsableCache();

    if (cached == null) {
      final full = await _fetchFullCanonical(forceRefresh: true);
      await _storeIfAllowed(full, syncToken: event?.syncToken);
      return AuthSchemaSyncResult(
        schema: _finalize(
          _cloneMap(full),
          source: _fullSchemaUri(full).toString(),
          cacheHit: false,
        ),
        changed: true,
        usedDelta: false,
        source: 'full-no-cache',
      );
    }

    final localSchema = cached.schema;
    final localRevision = _revision(localSchema);
    final localHash = _contentHash(localSchema);

    if (forceFull) {
      debugPrint('[AuthSchemaRepository] FULL_REVALIDATE forceFull');
      return _fullSyncAgainst(
        cached,
        event: event,
        source: 'full-forced',
      );
    }

    final metadataConfig = _asMap(localSchema['metadataEndpoint']);
    if (metadataConfig == null) {
      // The saved auth schema stays on screen. Without metadataEndpoint and
      // deltaEndpoint the server cannot send a patch, so the full document
      // is not downloaded again.
      debugPrint(
        '[AuthSchemaRepository] LOCAL KEPT — no metadataEndpoint on schema',
      );
      return AuthSchemaSyncResult(
        schema: _finalize(
          _cloneMap(localSchema),
          source: 'local-auth-schema-cache',
          cacheHit: true,
        ),
        changed: false,
        usedDelta: false,
        source: 'local-no-delta-contract',
      );
    }

    Map<String, dynamic> metadata;
    try {
      metadata = await _fetchMetadata(
        metadataConfig,
        accessToken: accessToken,
      );
    } catch (error, stackTrace) {
      debugPrint('[AuthSchemaRepository] META_FALLBACK $error');
      debugPrintStack(stackTrace: stackTrace);
      return AuthSchemaSyncResult(
        schema: _finalize(
          _cloneMap(localSchema),
          source: 'local-auth-schema-cache',
          cacheHit: true,
        ),
        changed: false,
        usedDelta: false,
        source: 'metadata-offline-local-kept',
      );
    }

    final responseConfig = _asMap(metadataConfig['response']);
    final revisionField =
        responseConfig?['revisionField']?.toString().trim() ?? 'revision';
    final hashField =
        responseConfig?['hashField']?.toString().trim() ?? 'contentHash';
    final syncTokenField =
        responseConfig?['syncTokenField']?.toString().trim() ?? 'syncToken';

    final remoteRevision =
        _intValue(_responseValue(metadata, revisionField)) ?? event?.revision;
    final remoteHash =
        _nonEmpty(_responseValue(metadata, hashField)?.toString()) ??
        event?.contentHash;
    final remoteSyncToken =
        _nonEmpty(_responseValue(metadata, syncTokenField)?.toString()) ??
        event?.syncToken ??
        cached.syncToken;

    if (_isUnchanged(
      localRevision: localRevision,
      localHash: localHash,
      remoteRevision: remoteRevision,
      remoteHash: remoteHash,
    )) {
      await _cache.updateSyncToken(remoteSyncToken);
      return AuthSchemaSyncResult(
        schema: _finalize(
          _cloneMap(localSchema),
          source: 'local-auth-schema-cache-revalidated',
          cacheHit: true,
        ),
        changed: false,
        usedDelta: false,
        source: 'metadata-unchanged',
      );
    }

    final deltaConfig = _asMap(localSchema['deltaEndpoint']);
    if (deltaConfig != null &&
        localRevision != null &&
        localHash != null &&
        remoteRevision != null &&
        remoteRevision > localRevision) {
      try {
        final deltaResult = await _tryDelta(
          localSchema: localSchema,
          localRevision: localRevision,
          localHash: localHash,
          remoteRevision: remoteRevision,
          remoteHash: remoteHash,
          remoteSyncToken: remoteSyncToken,
          deltaConfig: deltaConfig,
          accessToken: accessToken,
        );
        if (deltaResult != null) return deltaResult;
      } catch (error, stackTrace) {
        debugPrint('[AuthSchemaRepository] DELTA_FALLBACK $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    debugPrint(
      '[AuthSchemaRepository] LOCAL KEPT — delta was not applied',
    );
    return AuthSchemaSyncResult(
      schema: _finalize(
        _cloneMap(localSchema),
        source: 'local-auth-schema-cache',
        cacheHit: true,
      ),
      changed: false,
      usedDelta: false,
      source: 'delta-unavailable-local-kept',
    );
  }

  Future<AuthSchemaSyncResult?> _tryDelta({
    required Map<String, dynamic> localSchema,
    required int localRevision,
    required String localHash,
    required int remoteRevision,
    required String? remoteHash,
    required String? remoteSyncToken,
    required Map<String, dynamic> deltaConfig,
    String? accessToken,
  }) async {
    final method = deltaConfig['method']?.toString().trim().toUpperCase();
    if (method != null && method.isNotEmpty && method != 'GET') {
      throw UnsupportedError('Auth deltaEndpoint currently supports GET only.');
    }

    final uri = _httpsUri(deltaConfig['url'], source: 'deltaEndpoint.url');

    final query = <String, String>{...uri.queryParameters};
    query['from_revision'] = localRevision.toString();
    query['to_revision'] = remoteRevision.toString();
    query['base_hash'] = localHash;

    // target_hash is deliberately not sent. The schema text describes it as
    // "in response", and a client cannot know a target hash before fetching
    // the target revision.
    final requestUri = uri.replace(queryParameters: query);

    debugPrint(
      '[AuthSchemaRepository] DELTA GET '
      '${requestUri.replace(queryParameters: <String, String>{...requestUri.queryParameters, if (requestUri.queryParameters.containsKey('base_hash')) 'base_hash': '<sha256>'})}',
    );

    final response = await _client
        .get(
          requestUri,
          headers: _headers(
            accessToken: accessToken,
            bearer: deltaConfig['auth']?.toString().toLowerCase() == 'bearer',
          ),
        )
        .timeout(const Duration(milliseconds: _timeoutMs));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Auth delta HTTP ${response.statusCode}.');
    }

    final root = _decodeObject(response.body, source: requestUri.toString());
    final payload = _responsePayload(root);

    final responseMap = _asMap(deltaConfig['response']);
    final patchField = responseMap?['patchField']?.toString().trim() ?? 'patch';
    final fromRevisionField =
        responseMap?['fromRevisionField']?.toString().trim() ?? 'from_revision';
    final toRevisionField =
        responseMap?['toRevisionField']?.toString().trim() ?? 'to_revision';
    final baseHashField =
        responseMap?['baseHashField']?.toString().trim() ?? 'base_hash';
    final targetHashField =
        responseMap?['targetHashField']?.toString().trim() ?? 'target_hash';
    final fullRequiredField =
        responseMap?['fullRequiredField']?.toString().trim() ?? 'full_required';

    final status = payload['status']?.toString().trim().toLowerCase();
    final fullRequired =
        payload[fullRequiredField] == true ||
        status == 'full_required' ||
        root[fullRequiredField] == true;
    if (fullRequired) return null;

    final responseFromRevision = _intValue(payload[fromRevisionField]);
    final responseToRevision =
        _intValue(payload[toRevisionField]) ?? remoteRevision;
    final responseBaseHash =
        _nonEmpty(payload[baseHashField]?.toString()) ?? localHash;
    final responseTargetHash =
        _nonEmpty(payload[targetHashField]?.toString()) ?? remoteHash;

    if (responseFromRevision != null && responseFromRevision != localRevision) {
      throw StateError(
        'Auth delta base revision mismatch: local=$localRevision '
        'response=$responseFromRevision.',
      );
    }
    if (responseBaseHash != localHash) {
      throw StateError('Auth delta base_hash does not match cached schema.');
    }

    final patch = payload[patchField];
    if (patch is! List || patch.isEmpty) {
      throw const FormatException('Auth delta patch[] is missing or empty.');
    }

    final patched = AuthJsonPatch.apply(localSchema, patch);
    _validate(patched);

    final patchedRevision = _revision(patched);
    if (patchedRevision != responseToRevision) {
      throw StateError(
        'Patched Auth revision mismatch: schema=$patchedRevision '
        'target=$responseToRevision.',
      );
    }

    final patchedHash = _contentHash(patched);
    if (responseTargetHash != null && patchedHash != responseTargetHash) {
      throw StateError('Patched Auth contentHash does not equal target_hash.');
    }

    await _storeIfAllowed(patched, syncToken: remoteSyncToken);

    debugPrint(
      '[AuthSchemaRepository] DELTA_APPLIED '
      '$localRevision->$responseToRevision',
    );

    return AuthSchemaSyncResult(
      schema: _finalize(
        _cloneMap(patched),
        source: 'auth-delta:${requestUri.toString()}',
        cacheHit: true,
      ),
      changed: true,
      usedDelta: true,
      source: 'delta',
    );
  }

  Future<AuthSchemaSyncResult> _fullSyncAgainst(
    AuthSchemaCacheEntry cached, {
    SchemaInvalidationEvent? event,
    String? syncToken,
    required String source,
  }) async {
    final full = await _fetchFullCanonical(
      forceRefresh: true,
      schemaHint: cached.schema,
    );

    final changed = !_documentsEqual(cached.schema, full);
    await _storeIfAllowed(
      full,
      syncToken: syncToken ?? event?.syncToken ?? cached.syncToken,
    );

    return AuthSchemaSyncResult(
      schema: _finalize(
        _cloneMap(full),
        source: _fullSchemaUri(full).toString(),
        cacheHit: false,
      ),
      changed: changed,
      usedDelta: false,
      source: source,
    );
  }

  Future<AuthSchemaCacheEntry?> _readUsableCache({
    bool allowStale = false,
  }) async {
    final cached = await _cache.read();
    if (cached == null) return null;

    try {
      _validate(cached.schema);
    } catch (_) {
      await _cache.clear();
      return null;
    }

    if (!_persistentCacheAllowed(cached.schema)) {
      await _cache.clear();
      return null;
    }

    if (!allowStale) {
      final staleMaxAge = _staleMaxAgeSeconds(cached.schema);
      if (staleMaxAge != null && staleMaxAge >= 0) {
        final age = DateTime.now().toUtc().difference(cached.savedAt.toUtc());
        if (age > Duration(seconds: staleMaxAge)) {
          return null;
        }
      }
    }

    return cached;
  }

  Future<Map<String, dynamic>> _fetchFullCanonical({
    required bool forceRefresh,
    Map<String, dynamic>? schemaHint,
  }) async {
    final base = schemaHint == null
        ? _configuredBootstrapUri()
        : _fullSchemaUri(schemaHint);

    final query = <String, String>{...base.queryParameters};
    if (forceRefresh) {
      query['_ts'] = DateTime.now().microsecondsSinceEpoch.toString();
    }
    final uri = base.replace(queryParameters: query);

    debugPrint('[AuthSchemaRepository] LIVE GET $uri');

    final response = await _client
        .get(
          uri,
          headers: const <String, String>{
            'Accept': 'application/json',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
        )
        .timeout(const Duration(milliseconds: _timeoutMs));

    debugPrint('[AuthSchemaRepository] HTTP ${response.statusCode}');

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Auth schema HTTP ${response.statusCode}.');
    }

    final schema = _decodeSchemaOnly(response.body, uri.toString());
    _validate(schema);
    return schema;
  }

  Future<Map<String, dynamic>> _fetchMetadata(
    Map<String, dynamic> config, {
    String? accessToken,
  }) async {
    final method = config['method']?.toString().trim().toUpperCase();
    if (method != null && method.isNotEmpty && method != 'GET') {
      throw UnsupportedError(
        'Auth metadataEndpoint currently supports GET only.',
      );
    }

    final uri = _httpsUri(config['url'], source: 'metadataEndpoint.url');
    debugPrint('[AuthSchemaRepository] META GET $uri');

    final response = await _client
        .get(
          uri,
          headers: _headers(
            accessToken: accessToken,
            bearer: config['auth']?.toString().toLowerCase() == 'bearer',
          ),
        )
        .timeout(const Duration(milliseconds: _timeoutMs));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Auth metadata HTTP ${response.statusCode}.');
    }

    return _decodeObject(response.body, source: uri.toString());
  }

  Future<void> _storeIfAllowed(
    Map<String, dynamic> canonical, {
    String? syncToken,
  }) async {
    if (!_persistentCacheAllowed(canonical)) {
      await _cache.clear();
      return;
    }

    try {
      await _cache.write(canonical, syncToken: syncToken);
    } catch (error, stackTrace) {
      // A disk cache failure must not block rendering the live Auth schema.
      debugPrint('[AuthSchemaRepository] CACHE_WRITE_FAILED $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Map<String, dynamic> _finalize(
    Map<String, dynamic> schema, {
    required String source,
    required bool cacheHit,
  }) {
    _validate(schema);

    schema['_clientAuthSchemaSource'] = source;
    schema['_clientAuthSchemaMode'] = cacheHit
        ? 'persistent-cache'
        : 'live-server';
    schema['_clientAuthSchemaCacheHit'] = cacheHit;

    // Existing application-owned auth API transport remains intentionally
    // preserved. The server schema still owns UI, validation, and actions.
    final effective = AuthTemporaryApiOverlay.apply(schema);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(effective));

    debugPrint(
      '[AuthSchemaRepository] LOADED '
      'version=${effective['schemaVersion']} '
      'revision=${effective['revision'] ?? '-'} '
      'pages=${(effective['pages'] as List).length} '
      'source=$source '
      'cacheHit=$cacheHit '
      'mobileAdapter=${AuthTemporaryApiOverlay.enabled}',
    );

    return effective;
  }

  Map<String, dynamic> _decodeSchemaOnly(String raw, String source) {
    final root = _decodeObject(raw, source: source);

    if (root['status'] == false || root['success'] == false) {
      throw StateError(
        'Auth schema API failure: ${root['message'] ?? 'unknown error'}',
      );
    }

    return _unwrap(root);
  }

  Map<String, dynamic> _decodeObject(String raw, {required String source}) {
    ensureDecodableJson(body: raw, source: source);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('JSON root must be an object. source=$source');
    }
    return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> root) {
    if (root['schemaType'] != null) {
      return Map<String, dynamic>.from(root);
    }

    final rootSchema = _asMap(root['schema']);
    if (rootSchema != null) return rootSchema;

    final data = root['data'];
    if (data is Map) {
      final nested = _asMap(data['schema_json'] ?? data['schema']);
      if (nested != null) return nested;
    }

    throw const FormatException(
      'Unable to locate auth-ui schema at root, root.schema, '
      'data.schema_json or data.schema.',
    );
  }

  Map<String, dynamic> _responsePayload(Map<String, dynamic> root) {
    final data = _asMap(root['data']);
    return data ?? root;
  }

  dynamic _responseValue(Map<String, dynamic> root, String field) {
    if (root.containsKey(field)) return root[field];

    final data = _asMap(root['data']);
    if (data != null && data.containsKey(field)) return data[field];

    final schema = _asMap(root['schema']);
    if (schema != null && schema.containsKey(field)) return schema[field];

    return null;
  }

  Map<String, String> _headers({String? accessToken, required bool bearer}) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };

    final token = _nonEmpty(accessToken);
    if (bearer && token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Uri _configuredBootstrapUri() {
    return _httpsUri(_configuredUrl, source: 'AUTH_SCHEMA_URL');
  }

  Uri _fullSchemaUri(Map<String, dynamic> schema) {
    final policy = _asMap(schema['fullRequiredPolicy']);
    final declared = policy?['fullSchemaUrl'];
    if (declared != null) {
      try {
        return _httpsUri(declared, source: 'fullRequiredPolicy.fullSchemaUrl');
      } catch (_) {
        // Never switch to an invalid/non-HTTPS schema URL. The bootstrap URL
        // remains the trusted fallback.
      }
    }
    return _configuredBootstrapUri();
  }

  Uri _httpsUri(dynamic raw, {required String source}) {
    final text = raw?.toString().trim() ?? '';
    final uri = Uri.tryParse(text);
    if (text.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.scheme.toLowerCase() != 'https') {
      throw FormatException(
        '$source must be an absolute HTTPS URL; got "$text".',
      );
    }
    return uri;
  }

  bool _persistentCacheAllowed(Map<String, dynamic> schema) {
    final policy = _asMap(_asMap(schema['cachePolicy'])?['schema']);
    final strategy = policy?['strategy']?.toString().trim().toLowerCase();
    return strategy == 'stale-while-revalidate' ||
        strategy == 'persistent-versioned' ||
        strategy == 'cache-first';
  }

  int? _staleMaxAgeSeconds(Map<String, dynamic> schema) {
    final policy = _asMap(_asMap(schema['cachePolicy'])?['schema']);
    return _intValue(policy?['staleMaxAge'] ?? policy?['staleMaxAgeSeconds']);
  }

  bool _isUnchanged({
    required int? localRevision,
    required String? localHash,
    required int? remoteRevision,
    required String? remoteHash,
  }) {
    if (localHash == null || remoteHash == null) return false;
    if (localRevision != null &&
        remoteRevision != null &&
        remoteRevision < localRevision) {
      return localHash == remoteHash;
    }
    return localHash == remoteHash;
  }

  bool _documentsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    return jsonEncode(_publicationView(a)) == jsonEncode(_publicationView(b));
  }

  Map<String, dynamic> _publicationView(Map<String, dynamic> schema) {
    final copy = _cloneMap(schema);
    copy.removeWhere(
      (key, _) => key.startsWith('_client') || key == 'syncToken',
    );
    return copy;
  }

  int? _revision(Map<String, dynamic> schema) {
    return _intValue(schema['revision'] ?? schema['schemaRevision']);
  }

  String? _contentHash(Map<String, dynamic> schema) {
    for (final raw in <dynamic>[
      schema['contentHash'],
      schema['content_hash'],
      schema['schema_hash'],
    ]) {
      final value = _nonEmpty(raw?.toString());
      if (value != null) return value;
    }
    return null;
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }

    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      }
    }

    return null;
  }

  int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  String? _nonEmpty(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  Map<String, dynamic> _cloneMap(Map<String, dynamic> value) {
    return Map<String, dynamic>.from(
      (jsonDecode(jsonEncode(value)) as Map).cast<dynamic, dynamic>(),
    );
  }

  void _validate(Map<String, dynamic> schema) {
    if (schema['schemaType']?.toString() != 'auth-ui') {
      throw FormatException(
        'Expected schemaType auth-ui, got ${schema['schemaType']}.',
      );
    }

    final required = schema['contract']?['requiredTopLevelKeys'];
    if (required is List) {
      for (final rawKey in required) {
        final key = rawKey.toString();
        if (!schema.containsKey(key)) {
          throw FormatException('Auth schema required key "$key" is missing.');
        }
      }
    }

    for (final key in const <String>[
      'app',
      'theme',
      'icons',
      'assets',
      'state',
      'forms',
      'validationRules',
      'actions',
    ]) {
      if (schema[key] is! Map) {
        throw FormatException('auth schema $key is required.');
      }
    }

    final pages = schema['pages'];
    if (pages is! List || pages.isEmpty) {
      throw const FormatException('auth schema pages[] is required.');
    }

    final initial = schema['app']?['initialPageId']?.toString().trim();
    if (initial == null || initial.isEmpty) {
      throw const FormatException('app.initialPageId is required.');
    }

    if (!pages.any(
      (page) => page is Map && page['id']?.toString() == initial,
    )) {
      throw FormatException(
        'app.initialPageId "$initial" is not present in pages[].',
      );
    }
  }

  void dispose() {
    _client.close();
  }
}
