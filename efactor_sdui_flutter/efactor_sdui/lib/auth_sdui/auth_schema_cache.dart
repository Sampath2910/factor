import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AuthSchemaCacheEntry {
  const AuthSchemaCacheEntry({
    required this.schema,
    required this.savedAt,
    this.syncToken,
  });

  final Map<String, dynamic> schema;
  final DateTime savedAt;
  final String? syncToken;

  int? get revision {
    final raw = schema['revision'] ?? schema['schemaRevision'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  String? get contentHash {
    for (final raw in <dynamic>[
      schema['contentHash'],
      schema['content_hash'],
      schema['schema_hash'],
    ]) {
      final value = raw?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}

/// Persistent cache for the public Auth UI schema.
///
/// The Auth schema does not contain account-specific data, so it is safe to
/// cache globally. Session/access tokens are never written here.
class AuthSchemaCache {
  static const String _cacheVersion = 'v1';
  Future<void> _writeTail = Future<void>.value();

  Future<AuthSchemaCacheEntry?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;

      final root = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final rawSchema = root['schema'];
      final rawSavedAt = root['savedAt']?.toString();
      if (rawSchema is! Map || rawSavedAt == null) return null;

      final savedAt = DateTime.tryParse(rawSavedAt);
      if (savedAt == null) return null;

      final syncToken = root['syncToken']?.toString().trim();
      return AuthSchemaCacheEntry(
        schema: Map<String, dynamic>.from(rawSchema.cast<dynamic, dynamic>()),
        savedAt: savedAt,
        syncToken: syncToken == null || syncToken.isEmpty ? null : syncToken,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Map<String, dynamic> schema, {String? syncToken}) {
    final previous = _writeTail;
    final done = Completer<void>();
    _writeTail = done.future;
    return () async {
      try {
        await previous;
        await _writeUncoalesced(schema, syncToken: syncToken);
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }();
  }

  Future<void> _writeUncoalesced(
    Map<String, dynamic> schema, {
    String? syncToken,
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);

    final payload = jsonEncode(<String, dynamic>{
      'cacheVersion': _cacheVersion,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'syncToken': _nonEmpty(syncToken),
      'schema': schema,
    });

    await _atomicWrite(file, payload);
  }

  Future<void> updateSyncToken(String? syncToken) async {
    final token = _nonEmpty(syncToken);
    if (token == null) return;

    final existing = await read();
    if (existing == null || existing.syncToken == token) return;
    await write(existing.schema, syncToken: token);
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File(
      '${base.path}${Platform.pathSeparator}efactor'
      '${Platform.pathSeparator}schema_cache'
      '${Platform.pathSeparator}$_cacheVersion'
      '${Platform.pathSeparator}auth_schema.json',
    );
  }

  Future<void> _atomicWrite(File target, String payload) async {
    final dir = target.parent;
    await dir.create(recursive: true);

    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );

    try {
      await temp.writeAsString(payload, flush: true);
      await dir.create(recursive: true);

      try {
        if (await target.exists()) {
          await target.delete();
        }
        await temp.rename(target.path);
      } on FileSystemException catch (error) {
        debugPrint('[AuthSchemaCache] RENAME_FALLBACK $error');
        await dir.create(recursive: true);
        await target.writeAsString(payload, flush: true);
        if (await temp.exists()) await temp.delete();
      }
    } catch (error) {
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  String? _nonEmpty(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
