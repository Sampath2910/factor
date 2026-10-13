import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth_sdui/auth_json_patch.dart';
import 'json_http.dart';
import 'schema_invalidation_event.dart';
import 'schema_patch.dart';

/// Result of a cache-first incremental (or full-fallback) schema revalidation.
class SchemaSyncResult {
  const SchemaSyncResult({
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

/// Shared incremental synchronization for SDUI schemas.
///
/// Contract (matches Auth / Device):
/// 1. Call schema-declared [metadataEndpoint] when present.
/// 2. If unchanged → keep local cache (no full download).
/// 3. If changed → apply [deltaEndpoint] patch / record delta when available.
/// 4. Otherwise fall back to [fetchFull].
///
/// When endpoints are not declared, [fetchFull] is invoked with optional
/// `from_revision` / `updated_after` / `base_hash` hints via [syncQueryParams]
/// so backends can start returning deltas without a client rewrite.
///
/// Network failures are never written to disk; callers keep showing cache.
class SchemaIncrementalSync {
  SchemaIncrementalSync._();

  static Future<SchemaSyncResult> revalidate({
    required http.Client client,
    required Map<String, dynamic> localSchema,
    required Future<Map<String, dynamic>> Function({
      Map<String, String>? syncQuery,
    })
    fetchFull,
    required Future<void> Function(Map<String, dynamic> schema) persist,
    String? accessToken,
    SchemaInvalidationEvent? event,
    bool forceFull = false,
    Duration timeout = const Duration(seconds: 20),
    String logTag = 'SchemaIncrementalSync',
  }) async {
    final localRevision = revisionOf(localSchema);
    final localHash = contentHashOf(localSchema);
    final localUpdatedAt = updatedAtOf(localSchema);

    if (forceFull) {
      return _full(
        fetchFull: fetchFull,
        persist: persist,
        localSchema: localSchema,
        syncQuery: syncQueryParams(
          revision: localRevision,
          contentHash: localHash,
          updatedAt: localUpdatedAt,
        ),
        source: 'full-forced',
        logTag: logTag,
      );
    }

    final metadataConfig = asMap(localSchema['metadataEndpoint']);
    if (metadataConfig != null &&
        (metadataConfig['url']?.toString().trim().isNotEmpty ?? false)) {
      try {
        final metadata = await _fetchJson(
          client: client,
          config: metadataConfig,
          accessToken: accessToken,
          timeout: timeout,
          logTag: logTag,
          kind: 'META',
        );

        final responseConfig = asMap(metadataConfig['response']);
        final revisionField =
            responseConfig?['revisionField']?.toString().trim() ?? 'revision';
        final hashField =
            responseConfig?['hashField']?.toString().trim() ?? 'contentHash';
        final updatedAtField =
            responseConfig?['updatedAtField']?.toString().trim() ??
            'updated_at';

        final remoteRevision =
            intValue(responseValue(metadata, revisionField)) ?? event?.revision;
        final remoteHash =
            nonEmpty(responseValue(metadata, hashField)?.toString()) ??
            event?.contentHash;
        final remoteUpdatedAt = nonEmpty(
          responseValue(metadata, updatedAtField)?.toString(),
        );

        if (isUnchanged(
          localRevision: localRevision,
          localHash: localHash,
          localUpdatedAt: localUpdatedAt,
          remoteRevision: remoteRevision,
          remoteHash: remoteHash,
          remoteUpdatedAt: remoteUpdatedAt,
        )) {
          logDebug('[$logTag] META unchanged rev=${localRevision ?? '-'}');
          return SchemaSyncResult(
            schema: localSchema,
            changed: false,
            usedDelta: false,
            source: 'metadata-unchanged',
          );
        }

        final deltaConfig = asMap(localSchema['deltaEndpoint']);
        if (deltaConfig != null &&
            (deltaConfig['url']?.toString().trim().isNotEmpty ?? false) &&
            localRevision != null &&
            remoteRevision != null &&
            remoteRevision > localRevision) {
          final delta = await _tryDelta(
            client: client,
            localSchema: localSchema,
            localRevision: localRevision,
            localHash: localHash ?? schemaFingerprint(localSchema),
            remoteRevision: remoteRevision,
            remoteHash: remoteHash,
            deltaConfig: deltaConfig,
            accessToken: accessToken,
            timeout: timeout,
            persist: persist,
            logTag: logTag,
          );
          if (delta != null) return delta;
        }
      } catch (error, stackTrace) {
        logDebug('[$logTag] META_FALLBACK $error');
        debugPrintStackSafe(stackTrace);
        return SchemaSyncResult(
          schema: localSchema,
          changed: false,
          usedDelta: false,
          source: 'metadata-offline-local-kept',
        );
      }
    }

    // A saved schema is shown as-is until the document publishes
    // metadataEndpoint and deltaEndpoint. The full document is not
    // downloaded again on open, resume, or a timer.
    logDebug(
      '[$logTag] LOCAL KEPT — no metadataEndpoint/deltaEndpoint on schema',
    );
    return SchemaSyncResult(
      schema: localSchema,
      changed: false,
      usedDelta: false,
      source: 'local-no-delta-contract',
    );
  }

  /// Query params advertising the last successful sync state.
  /// Unknown params are ignored by older PHP endpoints.
  static Map<String, String> syncQueryParams({
    int? revision,
    String? contentHash,
    String? updatedAt,
  }) {
    final query = <String, String>{};
    if (revision != null) {
      query['from_revision'] = revision.toString();
      query['since_revision'] = revision.toString();
    }
    if (contentHash != null && contentHash.isNotEmpty) {
      query['base_hash'] = contentHash;
      query['content_hash'] = contentHash;
    }
    if (updatedAt != null && updatedAt.isNotEmpty) {
      query['updated_after'] = updatedAt;
      query['since'] = updatedAt;
    }
    return query;
  }

  /// Applies an incremental payload onto [base] when the response is shaped as
  /// a delta (patch / created+updated+deleted). Returns null if [payload] is a
  /// full schema document that should replace the cache instead.
  static Map<String, dynamic>? tryApplyIncrementalPayload({
    required Map<String, dynamic> base,
    required Map<String, dynamic> payload,
  }) {
    final data = asMap(payload['data']) ?? payload;

    final fullRequired =
        data['full_required'] == true ||
        data['fullRequired'] == true ||
        payload['full_required'] == true ||
        data['status']?.toString().toLowerCase() == 'full_required';
    if (fullRequired) return null;

    final unchanged =
        data['unchanged'] == true ||
        data['not_modified'] == true ||
        data['status']?.toString().toLowerCase() == 'not_modified';
    if (unchanged) {
      return Map<String, dynamic>.from(base);
    }

    final patch = data['patch'] ?? payload['patch'];
    if (patch != null) {
      final targetRev = intValue(data['to_revision'] ?? data['revision']);
      final targetHash = nonEmpty(
        (data['target_hash'] ?? data['contentHash'] ?? data['content_hash'])
            ?.toString(),
      );

      if (patch is List && _looksLikeRfc6902(patch)) {
        final patched = AuthJsonPatch.apply(base, patch);
        if (targetRev != null) {
          patched['revision'] = targetRev;
          patched['schemaRevision'] = targetRev;
        }
        if (targetHash != null) {
          patched['contentHash'] = targetHash;
        }
        return patched;
      }

      return SchemaPatch.applyDeltaPatch(
        base,
        patch,
        targetRevision: targetRev,
        targetHash: targetHash,
      );
    }

    final created = data['created'] ?? payload['created'];
    final updated = data['updated'] ?? payload['updated'];
    final deleted = data['deleted'] ?? payload['deleted'];
    if (created != null || updated != null || deleted != null) {
      return _applyRecordDelta(
        base,
        created: created,
        updated: updated,
        deleted: deleted,
        targetRevision: intValue(
          data['revision'] ?? data['to_revision'] ?? data['sync_version'],
        ),
        targetHash: nonEmpty(
          (data['contentHash'] ?? data['content_hash'] ?? data['sync_token'])
              ?.toString(),
        ),
        updatedAt: nonEmpty(
          (data['updated_at'] ?? data['updatedAt'])?.toString(),
        ),
      );
    }

    // Plain schema document (has typical SDUI shape) → not incremental.
    return null;
  }

  static Future<SchemaSyncResult> _full({
    required Future<Map<String, dynamic>> Function({
      Map<String, String>? syncQuery,
    })
    fetchFull,
    required Future<void> Function(Map<String, dynamic> schema) persist,
    required Map<String, dynamic> localSchema,
    required Map<String, String> syncQuery,
    required String source,
    required String logTag,
  }) async {
    final fresh = await fetchFull(
      syncQuery: syncQuery.isEmpty ? null : syncQuery,
    );

    // If fetchFull returned an incremental envelope (rare; usually decoded
    // schemas), apply it onto the local document instead of replacing blindly.
    final applied = tryApplyIncrementalPayload(
      base: localSchema,
      payload: fresh,
    );
    final effective = applied ?? fresh;

    final changed =
        schemaFingerprint(localSchema) != schemaFingerprint(effective);
    if (changed) {
      await persist(effective);
    }
    logDebug(
      '[$logTag] FULL_SYNC changed=$changed '
      'deltaEnvelope=${applied != null} source=$source',
    );
    return SchemaSyncResult(
      schema: changed ? effective : localSchema,
      changed: changed,
      usedDelta: applied != null,
      source: source,
    );
  }

  static Future<SchemaSyncResult?> _tryDelta({
    required http.Client client,
    required Map<String, dynamic> localSchema,
    required int localRevision,
    required String localHash,
    required int remoteRevision,
    required String? remoteHash,
    required Map<String, dynamic> deltaConfig,
    required String? accessToken,
    required Duration timeout,
    required Future<void> Function(Map<String, dynamic> schema) persist,
    required String logTag,
  }) async {
    final method = deltaConfig['method']?.toString().trim().toUpperCase();
    if (method != null && method.isNotEmpty && method != 'GET') {
      throw UnsupportedError('deltaEndpoint currently supports GET only.');
    }

    final baseUri = httpsUri(deltaConfig['url'], source: 'deltaEndpoint.url');
    final query = <String, String>{
      ...baseUri.queryParameters,
      'from_revision': localRevision.toString(),
      'to_revision': remoteRevision.toString(),
      'base_hash': localHash,
    };
    final uri = baseUri.replace(queryParameters: query);

    logDebug('[$logTag] DELTA GET ${_redact(uri)}');

    final response = await client
        .get(
          uri,
          headers: headers(
            accessToken: accessToken,
            bearer: deltaConfig['auth']?.toString().toLowerCase() == 'bearer',
          ),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Delta HTTP ${response.statusCode}.');
    }

    final root = decodeObject(response.body, source: uri.toString());
    final applied = tryApplyIncrementalPayload(
      base: localSchema,
      payload: root,
    );
    if (applied == null) return null;

    final patchedRevision = revisionOf(applied);
    if (patchedRevision != null &&
        patchedRevision != remoteRevision &&
        remoteRevision > 0) {
      // Soft check — still accept if hash matches.
      final patchedHash = contentHashOf(applied);
      if (remoteHash != null &&
          patchedHash != null &&
          patchedHash != remoteHash) {
        throw StateError('Delta verification failed (revision/hash mismatch).');
      }
    }

    await persist(applied);
    logDebug('[$logTag] DELTA_APPLIED $localRevision->$remoteRevision');
    return SchemaSyncResult(
      schema: applied,
      changed: true,
      usedDelta: true,
      source: 'delta',
    );
  }

  static Future<Map<String, dynamic>> _fetchJson({
    required http.Client client,
    required Map<String, dynamic> config,
    required String? accessToken,
    required Duration timeout,
    required String logTag,
    required String kind,
  }) async {
    final method = config['method']?.toString().trim().toUpperCase();
    if (method != null && method.isNotEmpty && method != 'GET') {
      throw UnsupportedError('$kind endpoint currently supports GET only.');
    }

    final uri = httpsUri(config['url'], source: '$kind.url');
    logDebug('[$logTag] $kind GET ${_redact(uri)}');

    final response = await client
        .get(
          uri,
          headers: headers(
            accessToken: accessToken,
            bearer: config['auth']?.toString().toLowerCase() == 'bearer',
          ),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('$kind HTTP ${response.statusCode}.');
    }
    return decodeObject(response.body, source: uri.toString());
  }

  static Map<String, dynamic> _applyRecordDelta(
    Map<String, dynamic> base, {
    required dynamic created,
    required dynamic updated,
    required dynamic deleted,
    int? targetRevision,
    String? targetHash,
    String? updatedAt,
  }) {
    var working = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(base)) as Map,
    );

    final toUpsert = <dynamic>[
      if (created is List) ...created,
      if (updated is List) ...updated,
    ];

    if (toUpsert.isNotEmpty) {
      working = SchemaPatch.applyDeltaPatch(working, <String, dynamic>{
        for (final collection in const [
          'controls',
          'pages',
          'components',
          'children',
        ])
          if (working[collection] is List) collection: toUpsert,
      });
    }

    if (deleted is List && deleted.isNotEmpty) {
      final deleteIds = deleted
          .map((e) {
            if (e is Map) return SchemaPatch.nodeId(e);
            return e?.toString().trim();
          })
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();

      for (final key in const ['controls', 'pages', 'components', 'children']) {
        final list = working[key];
        if (list is! List) continue;
        working[key] = list
            .where((item) {
              final id = SchemaPatch.nodeId(item);
              return id == null || !deleteIds.contains(id);
            })
            .toList();
      }

      final components = working['components'];
      if (components is Map) {
        for (final id in deleteIds) {
          components.remove(id);
        }
      }
      final pages = working['pages'];
      if (pages is Map) {
        for (final id in deleteIds) {
          pages.remove(id);
        }
      }
    }

    if (targetRevision != null) {
      working['revision'] = targetRevision;
      working['schemaRevision'] = targetRevision;
    }
    if (targetHash != null) {
      working['contentHash'] = targetHash;
    }
    if (updatedAt != null) {
      working['updated_at'] = updatedAt;
      working['updatedAt'] = updatedAt;
    }
    return working;
  }

  static bool _looksLikeRfc6902(List patch) {
    if (patch.isEmpty) return false;
    for (final op in patch) {
      if (op is! Map) return false;
      final type = op['op']?.toString().trim().toLowerCase();
      final path = op['path']?.toString();
      if (type == null ||
          type.isEmpty ||
          path == null ||
          !const {
            'add',
            'remove',
            'replace',
            'move',
            'copy',
            'test',
          }.contains(type)) {
        return false;
      }
    }
    return true;
  }

  // ── shared helpers ──────────────────────────────────────────────────────

  static int? revisionOf(Map<String, dynamic> schema) {
    return intValue(schema['revision'] ?? schema['schemaRevision']);
  }

  static String? contentHashOf(Map<String, dynamic> schema) {
    for (final raw in <dynamic>[
      schema['contentHash'],
      schema['content_hash'],
      schema['schema_hash'],
      schema['_clientSchemaHash'],
      schema['_clientHomeSchemaHash'],
      schema['_clientIotSchemaHash'],
      schema['_clientGridSchemaHash'],
      schema['_clientAuthSchemaHash'],
    ]) {
      final value = nonEmpty(raw?.toString());
      if (value != null) return value;
    }
    return null;
  }

  static String? updatedAtOf(Map<String, dynamic> schema) {
    for (final raw in <dynamic>[
      schema['updated_at'],
      schema['updatedAt'],
      schema['generatedAt'],
      schema['generatedAtIso'],
    ]) {
      final value = nonEmpty(raw?.toString());
      if (value != null) return value;
    }
    return null;
  }

  static bool isUnchanged({
    required int? localRevision,
    required String? localHash,
    required String? localUpdatedAt,
    required int? remoteRevision,
    required String? remoteHash,
    required String? remoteUpdatedAt,
  }) {
    if (localHash != null && remoteHash != null) {
      if (localRevision != null &&
          remoteRevision != null &&
          remoteRevision < localRevision) {
        return localHash == remoteHash;
      }
      return localHash == remoteHash;
    }

    if (localRevision != null &&
        remoteRevision != null &&
        remoteRevision == localRevision) {
      return true;
    }

    if (localUpdatedAt != null &&
        remoteUpdatedAt != null &&
        localUpdatedAt == remoteUpdatedAt) {
      return true;
    }

    return false;
  }

  static Map<String, dynamic>? asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
        }
      } catch (_) {}
    }
    return null;
  }

  static int? intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static String? nonEmpty(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static dynamic responseValue(Map<String, dynamic> root, String field) {
    if (root.containsKey(field)) return root[field];
    final data = asMap(root['data']);
    if (data != null && data.containsKey(field)) return data[field];
    final schema = asMap(root['schema']);
    if (schema != null && schema.containsKey(field)) return schema[field];
    return null;
  }

  static Map<String, dynamic> decodeObject(String raw, {required String source}) {
    ensureDecodableJson(body: raw, source: source);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('JSON root must be an object. source=$source');
    }
    return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
  }

  static Uri httpsUri(dynamic raw, {required String source}) {
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

  static Map<String, String> headers({
    String? accessToken,
    required bool bearer,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
    final token = nonEmpty(accessToken);
    if (bearer && token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static Uri _redact(Uri uri) {
    final query = <String, String>{...uri.queryParameters};
    for (final key in query.keys.toList()) {
      final lower = key.toLowerCase();
      if (lower.contains('token') ||
          lower.contains('hash') ||
          lower == 'base_hash') {
        query[key] = '<redacted>';
      }
    }
    return uri.replace(queryParameters: query);
  }

  static void debugPrintStackSafe(StackTrace stackTrace) {
    // Avoid importing foundation solely for debugPrintStack in release paths.
    logDebug(stackTrace.toString().split('\n').take(6).join('\n'));
  }
}
