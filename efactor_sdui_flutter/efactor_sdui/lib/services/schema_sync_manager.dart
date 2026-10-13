import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../data/schema_repository.dart';
import 'json_http.dart';
import 'schema_incremental_sync.dart';
import 'schema_offline.dart';
import 'schema_patch.dart';

/// Notification emitted when a background sync successfully updates a schema.
class SchemaUpdateNotification {
  const SchemaUpdateNotification({
    required this.schemaType,
    required this.schemaKey,
    required this.schema,
    required this.usedDelta,
    required this.structural,
    required this.changedNodeIds,
  });

  final String schemaType;
  final String schemaKey;
  final Map<String, dynamic> schema;
  final bool usedDelta;
  final bool structural;
  final Set<String> changedNodeIds;
}

/// Central orchestrator for local-first schema caching and background delta updates.
class SchemaSyncManager {
  SchemaSyncManager._();
  static final SchemaSyncManager instance = SchemaSyncManager._();

  final http.Client _client = http.Client();
  final StreamController<SchemaUpdateNotification> _updateController =
      StreamController<SchemaUpdateNotification>.broadcast();

  Stream<SchemaUpdateNotification> get updates => _updateController.stream;

  final Set<String> _syncInProgress = <String>{};

  /// Dispatches a background check and incremental update for a device schema.
  Future<void> syncDeviceSchemaInBackground({
    required String modelId,
    required String nodeId,
    required Map<String, dynamic> currentSchema,
    String? accessToken,
  }) async {
    final key = 'device:$modelId:$nodeId';
    if (_syncInProgress.contains(key)) return;
    _syncInProgress.add(key);

    try {
      // Never mutate the live UI schema map during sync. Merge/diff against a
      // deep clone so in-flight widget builds cannot observe half-updated props
      // (e.g. slider inactiveColor disappearing mid-frame).
      final localSnapshot = _deepCloneMap(currentSchema);

      final result = await SchemaIncrementalSync.revalidate(
        client: _client,
        localSchema: localSnapshot,
        accessToken: accessToken,
        logTag: 'SchemaSyncManager',
        persist: (schema) async {
          final repo = SchemaRepository();
          await repo.saveToCache(
            modelId: modelId,
            nodeId: nodeId,
            schema: schema,
          );
          await LocalSchemaManifest.record(
            schemaKey: key,
            schemaType: 'device',
            revision: SchemaIncrementalSync.revisionOf(schema),
            contentHash:
                SchemaIncrementalSync.contentHashOf(schema) ??
                schemaFingerprint(schema),
            schemaVersion: schema['schemaVersion']?.toString(),
            fileName:
                'efactor.device.server_schema.v1.${_hashKey(modelId, nodeId)}.json',
          );
        },
        fetchFull: ({Map<String, String>? syncQuery}) async {
          final repo = SchemaRepository();
          return repo.load(
            modelId: modelId,
            nodeId: nodeId,
            forceRefresh: true,
          );
        },
      );

      if (!result.changed) {
        logDebug('[SchemaSyncManager] DEVICE CACHE IS UP-TO-DATE $key');
        return;
      }

      // Diff against a fresh clone of the pre-sync UI schema — never the live
      // map reference that DeviceUiScreen / AppState still hold.
      final patchResult = SchemaPatch.merge(
        _deepCloneMap(currentSchema),
        result.schema,
      );
      _updateController.add(
        SchemaUpdateNotification(
          schemaType: 'device',
          schemaKey: key,
          schema: _deepCloneMap(result.schema),
          usedDelta: result.usedDelta,
          structural: patchResult.structural,
          changedNodeIds: patchResult.changedNodeIds,
        ),
      );
      logDebug(
        '[SchemaSyncManager] SYNC APPLIED for $key '
        'delta=${result.usedDelta} source=${result.source} '
        'nodes=${patchResult.changedNodeIds.length}',
      );
    } catch (e) {
      logDebug('[SchemaSyncManager] Sync failed for $key: $e');
    } finally {
      _syncInProgress.remove(key);
    }
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> source) {
    return Map<String, dynamic>.from(
      (jsonDecode(jsonEncode(source)) as Map).cast<dynamic, dynamic>(),
    );
  }

  static String _hashKey(String modelId, String nodeId) {
    final raw = '$modelId|$nodeId';
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(raw)) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16);
  }

  void dispose() {
    _client.close();
    _updateController.close();
  }
}
