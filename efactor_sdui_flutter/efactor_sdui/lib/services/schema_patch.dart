import 'dart:convert';
import 'json_http.dart';

/// Id-keyed merge of two SDUI schema maps.
///
/// Unchanged nodes keep their existing object identity so Flutter can skip
/// re-rendering them. No device, page, or component names are hardcoded.
class SchemaPatchResult {
  const SchemaPatchResult({
    required this.unchanged,
    required this.structural,
    required this.changedNodeIds,
    required this.schema,
  });

  final bool unchanged;
  final bool structural;
  final Set<String> changedNodeIds;
  final Map<String, dynamic> schema;

  bool get dataSourcesChanged => changedNodeIds.contains(r'$.dataSources');
}

class SchemaPatch {
  static const _listCollections = <String>{
    'pages',
    'controls',
    'components',
    'children',
  };

  static const _mapCollections = <String>{
    'pages',
    'routes',
    'components',
    'dataSources',
  };

  static const _structuralKeys = <String>{
    'navigation',
    'layout',
    'appShell',
    'theme',
    'themes',
    'typography',
    'icons',
    'iconRegistry',
    'responsive',
  };

  static SchemaPatchResult merge(
    Map<String, dynamic> current,
    Map<String, dynamic> incoming,
  ) {
    if (identical(current, incoming)) {
      return SchemaPatchResult(
        unchanged: true,
        structural: false,
        changedNodeIds: const <String>{},
        schema: current,
      );
    }

    final currentControlsCount = (current['controls'] as List?)?.length ?? 0;
    final incomingControlsCount = (incoming['controls'] as List?)?.length ?? 0;
    final currentPagesCount = (current['pages'] as List?)?.length ?? 0;
    final incomingPagesCount = (incoming['pages'] as List?)?.length ?? 0;

    final controlsOrPagesDiffer =
        currentControlsCount != incomingControlsCount ||
        currentPagesCount != incomingPagesCount;

    if (!controlsOrPagesDiffer &&
        schemaFingerprint(current) == schemaFingerprint(incoming)) {
      _copyClientMeta(current, incoming);
      return SchemaPatchResult(
        unchanged: true,
        structural: false,
        changedNodeIds: const <String>{},
        schema: current,
      );
    }

    final changed = <String>{};
    var structural = false;
    void markStructural() => structural = true;

    _mergeMap(
      current,
      incoming,
      path: r'$',
      changed: changed,
      markStructural: markStructural,
      depth: 0,
    );
    _copyClientMeta(current, incoming);

    return SchemaPatchResult(
      unchanged: false,
      structural: structural,
      changedNodeIds: changed,
      schema: current,
    );
  }

  static String nodeFingerprint(Object? node) {
    if (node is Map<String, dynamic>) {
      return schemaFingerprint(node);
    }
    if (node is Map) {
      return schemaFingerprint(
        Map<String, dynamic>.from(node.cast<dynamic, dynamic>()),
      );
    }
    return contentHash(node);
  }

  static String? nodeId(Object? node, {String? mapKey}) {
    if (node is Map) {
      for (final key in const [
        'id',
        'controlId',
        'pageId',
        'routeId',
        'componentId',
        'sourceId',
      ]) {
        final value = node[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }
    final fallback = mapKey?.trim() ?? '';
    return fallback.isEmpty ? null : fallback;
  }

  static void _mergeMap(
    Map<String, dynamic> current,
    Map incoming,
    {
    required String path,
    required Set<String> changed,
    required void Function() markStructural,
    required int depth,
  }) {
    if (depth > 10) {
      current
        ..clear()
        ..addAll(Map<String, dynamic>.from(incoming.cast<dynamic, dynamic>()));
      changed.add(path);
      return;
    }

    final incomingKeys = incoming.keys.map((key) => key.toString()).toSet();
    final currentKeys = current.keys.toSet();

    for (final key in currentKeys) {
      if (key.startsWith('_client')) continue;
      if (!incomingKeys.contains(key)) {
        current.remove(key);
        if (_structuralKeys.contains(key) ||
            _listCollections.contains(key) ||
            _mapCollections.contains(key)) {
          markStructural();
        }
        changed.add('$path.$key');
      }
    }

    for (final rawKey in incoming.keys) {
      final key = rawKey.toString();
      if (key.startsWith('_client')) continue;
      final next = incoming[rawKey];
      final prev = current[key];
      final childPath = '$path.$key';

      if (_listCollections.contains(key) && next is List) {
        final prevList = prev is List ? prev : const <dynamic>[];
        current[key] = _mergeList(
          prevList,
          next,
          path: childPath,
          changed: changed,
          markStructural: markStructural,
          depth: depth + 1,
        );
        continue;
      }

      if (_mapCollections.contains(key) && next is Map && prev is Map) {
        final prevMap = Map<String, dynamic>.from(prev);
        current[key] = prevMap;
        _mergeKeyedMap(
          prevMap,
          next,
          path: childPath,
          changed: changed,
          markStructural: markStructural,
          depth: depth + 1,
        );
        if (key == 'dataSources' &&
            (changed.contains(childPath) ||
                changed.any((id) => id.startsWith('$childPath.')))) {
          changed.add(r'$.dataSources');
        }
        continue;
      }

      if (_mapCollections.contains(key) && next is Map && prev == null) {
        current[key] = Map<String, dynamic>.from(next.cast<dynamic, dynamic>());
        markStructural();
        changed.add(childPath);
        if (key == 'dataSources') changed.add(r'$.dataSources');
        continue;
      }

      if (prev is Map && next is Map) {
        final prevMap = Map<String, dynamic>.from(prev);
        current[key] = prevMap;
        if (nodeFingerprint(prevMap) == nodeFingerprint(next)) {
          continue;
        }
        _mergeMap(
          prevMap,
          next,
          path: childPath,
          changed: changed,
          markStructural: markStructural,
          depth: depth + 1,
        );
        final id = nodeId(prevMap, mapKey: key);
        if (id != null) changed.add(id);
        if (_structuralKeys.contains(key)) markStructural();
        continue;
      }

      if (!_valuesEqual(prev, next)) {
        current[key] = next;
        changed.add(childPath);
        final id = nodeId(next, mapKey: key) ?? nodeId(prev, mapKey: key);
        if (id != null) changed.add(id);
        if (_structuralKeys.contains(key)) markStructural();
      }
    }
  }

  static void _mergeKeyedMap(
    Map<String, dynamic> current,
    Map incoming, {
    required String path,
    required Set<String> changed,
    required void Function() markStructural,
    required int depth,
  }) {
    final incomingKeys = incoming.keys.map((key) => key.toString()).toSet();
    final removed = current.keys
        .where((key) => !key.startsWith('_client') && !incomingKeys.contains(key))
        .toList(growable: false);
    if (removed.isNotEmpty) {
      for (final key in removed) {
        current.remove(key);
      }
      markStructural();
    }

    for (final rawKey in incoming.keys) {
      final key = rawKey.toString();
      final next = incoming[rawKey];
      final prev = current[key];
      final childPath = '$path.$key';
      final id = nodeId(next, mapKey: key) ?? key;

      if (prev == null) {
        current[key] = next is Map
            ? Map<String, dynamic>.from(next.cast<dynamic, dynamic>())
            : next;
        markStructural();
        changed.add(id);
        continue;
      }

      if (prev is Map && next is Map) {
        if (nodeFingerprint(prev) == nodeFingerprint(next)) {
          continue;
        }
        final prevMap = Map<String, dynamic>.from(prev);
        current[key] = prevMap;
        _mergeMap(
          prevMap,
          next,
          path: childPath,
          changed: changed,
          markStructural: markStructural,
          depth: depth + 1,
        );
        changed.add(id);
        continue;
      }

      if (!_valuesEqual(prev, next)) {
        current[key] = next;
        changed.add(id);
      }
    }
  }

  static List<dynamic> _mergeList(
    List current,
    List incoming, {
    required String path,
    required Set<String> changed,
    required void Function() markStructural,
    required int depth,
  }) {
    final currentById = <String, dynamic>{};
    for (final item in current) {
      final id = nodeId(item);
      if (id != null) currentById[id] = item;
    }

    final incomingIds = <String>{};
    final result = <dynamic>[];

    for (var i = 0; i < incoming.length; i++) {
      final item = incoming[i];
      final id = nodeId(item);
      if (id == null) {
        result.add(item);
        if (!_valuesEqual(i < current.length ? current[i] : null, item)) {
          changed.add('$path[$i]');
        }
        continue;
      }
      incomingIds.add(id);
      final prev = currentById[id];
      if (prev is Map && item is Map && nodeFingerprint(prev) == nodeFingerprint(item)) {
        result.add(prev);
        continue;
      }
      if (prev is Map && item is Map) {
        final prevMap = Map<String, dynamic>.from(prev);
        _mergeMap(
          prevMap,
          item,
          path: '$path.$id',
          changed: changed,
          markStructural: markStructural,
          depth: depth + 1,
        );
        result.add(prevMap);
        changed.add(id);
        continue;
      }
      result.add(item);
      changed.add(id);
    }

    final previousIds = currentById.keys.toSet();
    if (previousIds.difference(incomingIds).isNotEmpty ||
        incomingIds.difference(previousIds).isNotEmpty) {
      markStructural();
    }

    return result;
  }

  static bool _valuesEqual(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      return nodeFingerprint(left) == nodeFingerprint(right);
    }
    if (left is List && right is List) {
      return contentHash(left) == contentHash(right);
    }
    return left == right;
  }

  static void _copyClientMeta(
    Map<String, dynamic> current,
    Map incoming,
  ) {
    for (final entry in incoming.entries) {
      final key = entry.key.toString();
      if (key.startsWith('_client')) {
        current[key] = entry.value;
      }
    }
    for (final key in const [
      'schemaVersion',
      'revision',
      'schemaRevision',
      'updatedAt',
      'generatedAt',
    ]) {
      if (incoming.containsKey(key)) {
        current[key] = incoming[key];
      }
    }
  }

  /// Applies an incremental delta payload onto a base schema.
  ///
  /// Supports:
  /// 1. Map delta patch: merges changed keys, replaces or appends controls/pages
  ///    by ID, and removes items where `_op == 'delete'` or `_delete == true`.
  /// 2. List of JSON operations (`op`: 'replace'|'add'|'remove', `path`, `value`).
  ///
  /// Returns a new updated schema map with updated revision / hash.
  static Map<String, dynamic> applyDeltaPatch(
    Map<String, dynamic> baseSchema,
    dynamic deltaPatch, {
    int? targetRevision,
    String? targetHash,
  }) {
    final cloned = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(baseSchema)) as Map,
    );

    if (deltaPatch == null) return cloned;

    if (deltaPatch is List) {
      _applyJsonPatchOps(cloned, deltaPatch);
    } else if (deltaPatch is Map) {
      _applyMapDelta(cloned, deltaPatch);
    }

    if (targetRevision != null) {
      cloned['revision'] = targetRevision;
      cloned['schemaRevision'] = targetRevision;
    }
    if (targetHash != null && targetHash.isNotEmpty) {
      cloned['contentHash'] = targetHash;
      cloned['_clientSchemaHash'] = targetHash;
    } else {
      cloned['_clientSchemaHash'] = schemaFingerprint(cloned);
    }
    cloned['_clientSchemaPatchedAtMs'] = DateTime.now().millisecondsSinceEpoch;

    return cloned;
  }

  static void _applyMapDelta(
    Map<String, dynamic> target,
    Map delta,
  ) {
    for (final entry in delta.entries) {
      final key = entry.key.toString();
      final value = entry.value;

      if (key == '_op' || key == '_delete') continue;

      if (value == null) {
        target.remove(key);
        continue;
      }

      if (_listCollections.contains(key) && value is List) {
        final currentList = target[key] is List ? target[key] as List : <dynamic>[];
        target[key] = _patchCollectionList(currentList, value);
        continue;
      }

      if (target[key] is Map && value is Map) {
        _applyMapDelta(
          target[key] as Map<String, dynamic>,
          value,
        );
      } else if (value is Map) {
        target[key] = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
      } else {
        target[key] = value;
      }
    }
  }

  static List<dynamic> _patchCollectionList(
    List current,
    List deltaList,
  ) {
    final result = <dynamic>[...current];

    for (final item in deltaList) {
      if (item is! Map) {
        result.add(item);
        continue;
      }

      final isDelete = item['_op'] == 'delete' || item['_delete'] == true;
      final id = nodeId(item);

      if (id == null || id.isEmpty) {
        if (!isDelete) result.add(item);
        continue;
      }

      final existingIndex = result.indexWhere((el) => nodeId(el) == id);
      if (isDelete) {
        if (existingIndex >= 0) result.removeAt(existingIndex);
      } else if (existingIndex >= 0) {
        final existing = result[existingIndex];
        if (existing is Map) {
          final merged = Map<String, dynamic>.from(existing.cast<dynamic, dynamic>());
          _applyMapDelta(merged, item);
          result[existingIndex] = merged;
        } else {
          result[existingIndex] = item;
        }
      } else {
        result.add(item);
      }
    }

    return result;
  }

  static void _applyJsonPatchOps(
    Map<String, dynamic> root,
    List operations,
  ) {
    for (final op in operations) {
      if (op is! Map) continue;
      final type = op['op']?.toString().toLowerCase().trim();
      final rawPath = op['path']?.toString().trim() ?? '';
      final value = op['value'];

      if (type == null || rawPath.isEmpty) continue;

      final segments = rawPath.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;

      dynamic current = root;
      for (int i = 0; i < segments.length - 1; i++) {
        final seg = segments[i];
        if (current is Map) {
          current = current[seg];
        } else if (current is List) {
          final idx = int.tryParse(seg);
          if (idx != null && idx >= 0 && idx < current.length) {
            current = current[idx];
          } else {
            current = null;
            break;
          }
        } else {
          current = null;
          break;
        }
      }

      if (current == null) continue;
      final lastKey = segments.last;

      if (current is Map) {
        if (type == 'remove') {
          current.remove(lastKey);
        } else {
          current[lastKey] = value;
        }
      } else if (current is List) {
        final idx = int.tryParse(lastKey);
        if (idx != null && idx >= 0 && idx <= current.length) {
          if (type == 'remove' && idx < current.length) {
            current.removeAt(idx);
          } else if (type == 'replace' && idx < current.length) {
            current[idx] = value;
          } else if (type == 'add') {
            current.insert(idx, value);
          }
        }
      }
    }
  }
}

