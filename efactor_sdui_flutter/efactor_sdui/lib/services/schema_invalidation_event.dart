import 'dart:convert';

class SchemaInvalidationEvent {
  const SchemaInvalidationEvent({
    required this.schemaId,
    this.scope,
    this.revision,
    this.contentHash,
    this.syncToken,
    this.changedAt,
    this.modelNo,
    this.nodeId,
  });

  final String schemaId;
  final String? scope;
  final int? revision;
  final String? contentHash;
  final String? syncToken;
  final DateTime? changedAt;
  final String? modelNo;
  final String? nodeId;

  static SchemaInvalidationEvent? tryParse(dynamic value) {
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return null;
      try {
        return tryParse(jsonDecode(text));
      } catch (_) {
        return null;
      }
    }

    final map = _asMap(value);
    if (map == null) return null;

    final action = _firstString(map, const <String>[
      'action',
      'event',
      'eventName',
      'type',
    ])?.toLowerCase();

    if (action != 'schema_changed') {
      for (final key in const <String>['data', 'payload', 'message']) {
        final nested = map[key];
        final parsed = tryParse(nested);
        if (parsed != null) return parsed;
      }
      return null;
    }

    var schemaId = _firstString(map, const <String>['schema_id', 'schemaId']);

    // Some Cloud transports wrap an event envelope as
    // {"event":"schema_changed","payload":{...schema fields...}}.
    // Preserve the validated event name while reading the declared payload
    // shape from the nested object instead of requiring schema_id at the
    // envelope root.
    if (schemaId == null || schemaId.isEmpty) {
      for (final key in const <String>['data', 'payload', 'message']) {
        final nested = _asMap(map[key]);
        if (nested == null) continue;
        final merged = <String, dynamic>{'action': 'schema_changed', ...nested};
        final parsed = tryParse(merged);
        if (parsed != null) return parsed;
      }
      return null;
    }

    return SchemaInvalidationEvent(
      schemaId: schemaId,
      scope: _firstString(map, const <String>['scope', 'schema_scope']),
      revision: _intValue(map['revision'] ?? map['schema_revision']),
      contentHash: _firstString(map, const <String>[
        'hash',
        'content_hash',
        'contentHash',
        'schema_hash',
      ]),
      syncToken: _firstString(map, const <String>['sync_token', 'syncToken']),
      changedAt: _dateTimeValue(
        map['changed_at'] ?? map['changedAt'] ?? map['updated_at'],
      ),
      modelNo: _firstString(map, const <String>[
        'model_no',
        'modelNo',
        'model_id',
        'modelId',
      ]),
      nodeId: _firstString(map, const <String>['node_id', 'nodeId']),
    );
  }

  bool matchesScope(String expected) {
    final normalized = scope?.trim().toLowerCase();
    return normalized != null && normalized == expected.trim().toLowerCase();
  }

  bool matchesSchemaId(String? currentSchemaId) {
    final current = currentSchemaId?.trim();
    return current != null && current.isNotEmpty && current == schemaId;
  }

  bool matchesDevice({required String modelNo, required String nodeId}) {
    final eventModel = this.modelNo?.trim();
    final eventNode = this.nodeId?.trim();

    // A model number alone is not enough to identify one Device UI because a
    // user can own multiple nodes of the same model. Require the runtime node
    // when matching by device identity; schema_id matching is handled
    // separately by the caller.
    if (eventNode == null || eventNode.isEmpty || eventNode != nodeId.trim()) {
      return false;
    }
    if (eventModel != null &&
        eventModel.isNotEmpty &&
        eventModel != modelNo.trim()) {
      return false;
    }

    return true;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static DateTime? _dateTimeValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text);
  }
}
