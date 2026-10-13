import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Transport failures may use a saved schema. HTTP 4xx and invalid-schema
/// errors stay visible.
bool isTransientNetworkFailure(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException ||
      error is OSError) {
    return true;
  }

  if (error is http.ClientException) {
    return _isTransientHttpStatus(error.message) ?? true;
  }

  final text = error.toString().toLowerCase();
  final status = _isTransientHttpStatus(text);
  if (status != null) return status;

  return text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('network is unreachable') ||
      text.contains('connection refused') ||
      text.contains('connection reset') ||
      text.contains('timed out') ||
      text.contains('no address associated');
}

bool? _isTransientHttpStatus(String text) {
  final match = RegExp(r'http\s+(\d{3})').firstMatch(text.toLowerCase());
  if (match == null) return null;
  final code = int.tryParse(match.group(1) ?? '') ?? 0;
  if (code >= 500 || code == 408 || code == 429) return true;
  if (code >= 400) return false;
  return null;
}

class DeviceIdentityRef {
  const DeviceIdentityRef({required this.modelId, required this.nodeId});

  final String modelId;
  final String nodeId;

  @override
  bool operator ==(Object other) {
    return other is DeviceIdentityRef &&
        other.modelId == modelId &&
        other.nodeId == nodeId;
  }

  @override
  int get hashCode => Object.hash(modelId, nodeId);
}

List<DeviceIdentityRef> extractDeviceIdentities(
  dynamic root, {
  int maxDepth = 12,
  int maxItems = 50,
}) {
  final found = <DeviceIdentityRef>{};

  void visit(dynamic value, int depth) {
    if (value == null || depth > maxDepth || found.length >= maxItems) return;
    if (value is Map) {
      final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
      final model = _firstString(map, const <String>[
        'model_no',
        'modelNo',
        'modelNumber',
        'modelId',
        'model_id',
      ]);
      final node = _firstString(map, const <String>['node_id', 'nodeId']);
      if (model != null && node != null) {
        found.add(DeviceIdentityRef(modelId: model, nodeId: node));
      }
      for (final child in map.values) {
        if (child is Map || child is List) visit(child, depth + 1);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        visit(item, depth + 1);
      }
    }
  }

  visit(root, 0);
  return found.toList(growable: false);
}

/// Large schemas (device/IoT) do not fit reliably in SharedPreferences.
class SchemaDiskCache {
  static Directory? testDirectory;

  static Future<Directory> _directory() async {
    if (testDirectory != null) {
      await testDirectory!.create(recursive: true);
      return testDirectory!;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}efactor'
      '${Platform.pathSeparator}schema_cache'
      '${Platform.pathSeparator}v1',
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file(String name) async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static Future<void> writeString(String name, String payload) async {
    final file = await _file(name);
    final temp = File('${file.path}.tmp');
    try {
      // Ensure parent exists even if a previous failed write left the tree
      // in a partial state (seen on Android as PathNotFoundException).
      await temp.parent.create(recursive: true);
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      await temp.writeAsString(payload, flush: true);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // Another writer may have already replaced/removed the file.
        }
      }
      try {
        await temp.rename(file.path);
      } catch (_) {
        // Fallback when rename cannot replace across certain Android FS cases.
        await temp.copy(file.path);
        try {
          await temp.delete();
        } catch (_) {}
      }
    } catch (error) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Future<String?> readString(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  static Future<void> remove(String name) async {
    final file = await _file(name);
    if (await file.exists()) await file.delete();
  }

  static Future<int?> modifiedAtMs(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    return (await file.lastModified()).millisecondsSinceEpoch;
  }

  static Future<bool> exists(String name) async {
    final file = await _file(name);
    return file.exists();
  }

  /// Wipes all cached schema files and manifest entries on disk (e.g. on logout).
  static Future<void> clearAll() async {
    try {
      final dir = await _directory();
      if (await dir.exists()) {
        final entries = dir.listSync();
        for (final entry in entries) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// Metadata entry tracking a single locally-cached schema.
class SchemaManifestEntry {
  const SchemaManifestEntry({
    required this.schemaKey,
    required this.schemaType,
    this.revision,
    required this.contentHash,
    this.schemaVersion,
    required this.cachedAtMs,
    required this.fileName,
  });

  final String schemaKey;
  final String schemaType;
  final int? revision;
  final String contentHash;
  final String? schemaVersion;
  final int cachedAtMs;
  final String fileName;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaKey': schemaKey,
        'schemaType': schemaType,
        'revision': revision,
        'contentHash': contentHash,
        'schemaVersion': schemaVersion,
        'cachedAtMs': cachedAtMs,
        'fileName': fileName,
      };

  factory SchemaManifestEntry.fromJson(Map<String, dynamic> json) {
    return SchemaManifestEntry(
      schemaKey: json['schemaKey']?.toString() ?? '',
      schemaType: json['schemaType']?.toString() ?? 'unknown',
      revision: json['revision'] is int
          ? json['revision'] as int
          : int.tryParse(json['revision']?.toString() ?? ''),
      contentHash: json['contentHash']?.toString() ?? '',
      schemaVersion: json['schemaVersion']?.toString(),
      cachedAtMs: json['cachedAtMs'] is int
          ? json['cachedAtMs'] as int
          : int.tryParse(json['cachedAtMs']?.toString() ?? '') ?? 0,
      fileName: json['fileName']?.toString() ?? '',
    );
  }
}

/// Disk-backed manifest recording all schemas currently available offline.
class LocalSchemaManifest {
  static const String _manifestFile = 'schema_manifest.json';
  static Map<String, SchemaManifestEntry>? _memoryEntries;

  static Future<Map<String, SchemaManifestEntry>> getEntries() async {
    if (_memoryEntries != null) return Map.unmodifiable(_memoryEntries!);

    final raw = await SchemaDiskCache.readString(_manifestFile);
    if (raw == null || raw.trim().isEmpty) {
      _memoryEntries = <String, SchemaManifestEntry>{};
      return Map.unmodifiable(_memoryEntries!);
    }

    try {
      final map = <String, SchemaManifestEntry>{};
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        for (final entry in parsed.entries) {
          if (entry.value is Map) {
            map[entry.key.toString()] = SchemaManifestEntry.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      _memoryEntries = map;
      return Map.unmodifiable(map);
    } catch (_) {
      _memoryEntries = <String, SchemaManifestEntry>{};
      return Map.unmodifiable(_memoryEntries!);
    }
  }

  static Future<SchemaManifestEntry?> getEntry(String schemaKey) async {
    final entries = await getEntries();
    return entries[schemaKey];
  }

  static Future<void> record({
    required String schemaKey,
    required String schemaType,
    int? revision,
    required String contentHash,
    String? schemaVersion,
    required String fileName,
  }) async {
    final entries = Map<String, SchemaManifestEntry>.from(await getEntries());
    final entry = SchemaManifestEntry(
      schemaKey: schemaKey,
      schemaType: schemaType,
      revision: revision,
      contentHash: contentHash,
      schemaVersion: schemaVersion,
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
      fileName: fileName,
    );
    entries[schemaKey] = entry;
    _memoryEntries = entries;

    final jsonMap = <String, dynamic>{
      for (final e in entries.entries) e.key: e.value.toJson(),
    };
    await SchemaDiskCache.writeString(_manifestFile, jsonEncode(jsonMap));
  }

  static Future<void> remove(String schemaKey) async {
    final entries = Map<String, SchemaManifestEntry>.from(await getEntries());
    if (entries.remove(schemaKey) != null) {
      _memoryEntries = entries;
      final jsonMap = <String, dynamic>{
        for (final e in entries.entries) e.key: e.value.toJson(),
      };
      await SchemaDiskCache.writeString(_manifestFile, jsonEncode(jsonMap));
    }
  }

  static Future<Map<String, dynamic>> exportManifestPayload() async {
    final entries = await getEntries();
    return <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'schemas': <String, dynamic>{
        for (final e in entries.entries)
          e.key: <String, dynamic>{
            'type': e.value.schemaType,
            'revision': e.value.revision,
            'hash': e.value.contentHash,
            'version': e.value.schemaVersion,
            'cachedAt': e.value.cachedAtMs,
          },
      },
    };
  }
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

