import 'dart:convert';

import 'package:efactor_field_tracker/efactor_field_tracker.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A remote field-tracking command delivered via a silent FCM data push
/// (`type == "field_tracking"`). Every value on the wire is a string.
///
/// Backend contract: `action` is `start` or `stop`; `device_id` empty means
/// every device of the user; `command_id` + `issued_at` drive idempotency.
@immutable
class FieldTrackingCommand {
  const FieldTrackingCommand({
    required this.action,
    required this.appId,
    required this.tenantId,
    required this.userId,
    required this.deviceId,
    required this.commandId,
    required this.issuedAt,
  });

  final String action;
  final String appId;
  final String tenantId;
  final String userId;
  final String deviceId;
  final String commandId;

  /// Unix seconds; 0 when absent/unparseable.
  final int issuedAt;

  bool get isStart => action == 'start';
  bool get isStop => action == 'stop';

  /// Per-user scope key (app + tenant + user) for the last-applied watermark.
  String get scopeKey => '$appId|$tenantId|$userId';

  /// Returns the command when [data] is a field_tracking push, else null.
  static FieldTrackingCommand? tryParse(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['event'] ?? '').toString().toLowerCase();
    if (type != 'field_tracking') return null;
    String s(String k) => (data[k] ?? '').toString().trim();
    return FieldTrackingCommand(
      action: s('action').toLowerCase(),
      appId: s('app_id'),
      tenantId: s('tenant_id'),
      userId: s('user_id'),
      deviceId: s('device_id'),
      commandId: s('command_id'),
      issuedAt: int.tryParse(s('issued_at')) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'action': action,
        'app_id': appId,
        'tenant_id': tenantId,
        'user_id': userId,
        'device_id': deviceId,
        'command_id': commandId,
        'issued_at': issuedAt.toString(),
      };

  static FieldTrackingCommand? fromJson(Map<String, dynamic> json) =>
      tryParse(<String, dynamic>{'type': 'field_tracking', ...json});
}

/// Pure idempotency decision (no I/O) — fully unit-testable.
///
/// Apply the command only when: it targets this device (empty target = all, a
/// non-empty target must equal our [ourDeviceId]); its [FieldTrackingCommand.commandId]
/// was not already applied; and its `issued_at` is newer than the last applied
/// one for the same app+tenant+user scope (drops stale / out-of-order pushes).
bool shouldApplyFieldTrackingCommand({
  required FieldTrackingCommand cmd,
  required String? ourDeviceId,
  required int? lastAppliedIssuedAt,
  required Set<String> appliedCommandIds,
}) {
  if (cmd.action != 'start' && cmd.action != 'stop') return false;
  if (cmd.deviceId.isNotEmpty && cmd.deviceId != (ourDeviceId ?? '')) {
    return false;
  }
  if (cmd.commandId.isNotEmpty && appliedCommandIds.contains(cmd.commandId)) {
    return false;
  }
  if (lastAppliedIssuedAt != null && cmd.issuedAt <= lastAppliedIssuedAt) {
    return false;
  }
  return true;
}

/// SharedPreferences-backed state for the idempotency gate and the
/// background→foreground pending-command handoff. Disk-backed so a command
/// received in the FCM background isolate is visible to the main isolate.
class FieldTrackingCommandStore {
  FieldTrackingCommandStore._();
  static final FieldTrackingCommandStore instance =
      FieldTrackingCommandStore._();

  static const String _kLastIssued = 'efactor.field_tracker.cmd.last_issued_v1';
  static const String _kAppliedIds = 'efactor.field_tracker.cmd.applied_ids_v1';
  static const String _kPending = 'efactor.field_tracker.cmd.pending_v1';

  /// shortcut: keep only the most recent ids per scope so the dedupe set cannot
  /// grow unbounded; raise if commands ever arrive faster than this window.
  static const int _maxAppliedIdsPerScope = 50;

  Future<SharedPreferences> get _prefs async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // cross-isolate freshness
    return p;
  }

  Future<String?> readOurDeviceId() async {
    try {
      final p = await _prefs;
      return p.getString(TrackerIdentityStore.deviceIdPrefsKey);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<int?> readLastIssuedAt(String scopeKey) async {
    final p = await _prefs;
    final map = _decodeMap(p.getString(_kLastIssued));
    final v = map[scopeKey];
    return v is num ? v.toInt() : null;
  }

  Future<Set<String>> readAppliedIds(String scopeKey) async {
    final p = await _prefs;
    final map = _decodeMap(p.getString(_kAppliedIds));
    final list = map[scopeKey];
    if (list is List) return list.map((e) => e.toString()).toSet();
    return <String>{};
  }

  /// Records a command as applied: advances the scope watermark and appends its
  /// id (capped).
  Future<void> markApplied(FieldTrackingCommand cmd) async {
    try {
      final p = await _prefs;

      final issued = _decodeMap(p.getString(_kLastIssued));
      final prev = issued[cmd.scopeKey];
      final prevInt = prev is num ? prev.toInt() : 0;
      if (cmd.issuedAt > prevInt) issued[cmd.scopeKey] = cmd.issuedAt;
      await p.setString(_kLastIssued, jsonEncode(issued));

      if (cmd.commandId.isNotEmpty) {
        final applied = _decodeMap(p.getString(_kAppliedIds));
        final list = (applied[cmd.scopeKey] is List)
            ? List<String>.from(
                (applied[cmd.scopeKey] as List).map((e) => e.toString()))
            : <String>[];
        if (!list.contains(cmd.commandId)) list.add(cmd.commandId);
        if (list.length > _maxAppliedIdsPerScope) {
          list.removeRange(0, list.length - _maxAppliedIdsPerScope);
        }
        applied[cmd.scopeKey] = list;
        await p.setString(_kAppliedIds, jsonEncode(applied));
      }
    } catch (e) {
      debugPrint('[FieldTracking] markApplied error: $e');
    }
  }

  /// Stores a command for the main isolate to apply on next resume, keeping the
  /// newest when several arrive while backgrounded.
  Future<void> writePendingIfNewer(FieldTrackingCommand cmd) async {
    try {
      final p = await _prefs;
      final existing = FieldTrackingCommand.fromJson(
          _decodeMap(p.getString(_kPending)));
      if (existing != null && existing.issuedAt >= cmd.issuedAt) return;
      await p.setString(_kPending, jsonEncode(cmd.toJson()));
    } catch (e) {
      debugPrint('[FieldTracking] writePending error: $e');
    }
  }

  Future<FieldTrackingCommand?> readPending() async {
    try {
      final p = await _prefs;
      final map = _decodeMap(p.getString(_kPending));
      if (map.isEmpty) return null;
      return FieldTrackingCommand.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPending() async {
    try {
      final p = await _prefs;
      await p.remove(_kPending);
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kLastIssued);
      await p.remove(_kAppliedIds);
      await p.remove(_kPending);
    } catch (_) {}
  }
}
