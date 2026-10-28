import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks call lifecycle states to prevent:
/// 1. Double ringing when a call ends or is answered/declined.
/// 2. Ringing when an ongoing call is already active.
/// 3. Re-ringing for completed/cancelled/missed calls.
class CallLifecycleTracker {
  CallLifecycleTracker._();

  static const String _finishedCallsPrefsKey = 'efactor_finished_call_ids_v1';
  static const String _ongoingCallActiveKey = 'efactor_ongoing_call_active_v1';
  static const String _ongoingCallIdKey = 'efactor_ongoing_call_id_v1';
  static const String _ongoingCallStartTsKey = 'efactor_ongoing_call_start_ts_v1';

  /// TTL for keeping finished call IDs (10 minutes as specified).
  static const int kFinishedCallTtlMs = 10 * 60 * 1000;

  /// Stale threshold for ongoing call marker (6 hours).
  static const int kOngoingCallMaxDurationMs = 6 * 60 * 60 * 1000;

  /// Call event types that represent the end / termination of a call ring.
  static const Set<String> kEndCallTypes = <String>{
    'MISSED_CALL',
    'CALL_MISSED',
    'CALL_HANDLED',
    'CALL_CANCELLED',
    'CANCEL_CALL',
    'REJECTED',
    'HANGUP',
    'CALL_ENDED',
  };

  /// Call event types that represent an incoming ringing call.
  static const Set<String> kRingCallTypes = <String>{
    'INCOMING_CALL',
    'CALL',
    'VOIP_CALL',
    'CALL_REQUEST',
    'RINGING',
  };

  /// In-memory cache of finished call IDs mapped to expiration timestamp.
  static final Map<String, int> _memoryFinishedCalls = <String, int>{};

  /// Hook for the foreground OngoingCallService singleton to report active call status.
  static bool Function()? isForegroundCallActive;

  /// Synchronous fast-path check against in-memory finished calls.
  static bool isCallFinishedSync(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return false;
    final ts = _memoryFinishedCalls[id];
    if (ts == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - ts < kFinishedCallTtlMs) {
      return true;
    }
    _memoryFinishedCalls.remove(id);
    return false;
  }

  /// Checks if a callId is marked as finished (kept for 10 minutes).
  /// Checks memory cache first, then SharedPreferences (reloaded from disk).
  static Future<bool> isCallFinished(String callId) async {
    final id = callId.trim();
    if (id.isEmpty) return false;

    if (isCallFinishedSync(id)) {
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_finishedCallsPrefsKey);
      if (raw == null || raw.isEmpty) return false;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (decoded.containsKey(id)) {
        final ts = (decoded[id] as num?)?.toInt() ?? 0;
        if (now - ts < kFinishedCallTtlMs) {
          _memoryFinishedCalls[id] = ts;
          return true;
        }
      }
    } catch (e) {
      debugPrint('[CallLifecycleTracker] isCallFinished error: $e');
    }
    return false;
  }

  /// Adds a callId to the saved finished call IDs list (kept for 10 minutes).
  /// Prunes expired call IDs older than 10 minutes.
  static Future<void> markCallFinished(String callId) async {
    final id = callId.trim();
    if (id.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    _memoryFinishedCalls[id] = now;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_finishedCallsPrefsKey);
      final Map<String, dynamic> map = <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          map.addAll(Map<String, dynamic>.from(decoded));
        }
      }

      map[id] = now;

      // Prune entries older than 10 minutes
      map.removeWhere((k, v) {
        final ts = (v as num?)?.toInt() ?? 0;
        return now - ts > kFinishedCallTtlMs;
      });

      await prefs.setString(_finishedCallsPrefsKey, jsonEncode(map));
      debugPrint('[CallLifecycleTracker] Marked call finished: $id (total tracked: ${map.length})');
    } catch (e) {
      debugPrint('[CallLifecycleTracker] markCallFinished error: $e');
    }
  }

  /// Updates ongoing call active state in SharedPreferences.
  static Future<void> setOngoingCallActive(bool active, {String? callId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await prefs.setBool(_ongoingCallActiveKey, active);
      if (active) {
        if (callId != null && callId.isNotEmpty) {
          await prefs.setString(_ongoingCallIdKey, callId.trim());
          await markCallFinished(callId);
        }
        await prefs.setInt(_ongoingCallStartTsKey, now);
      } else {
        await prefs.remove(_ongoingCallIdKey);
        await prefs.remove(_ongoingCallStartTsKey);
        if (callId != null && callId.isNotEmpty) {
          await markCallFinished(callId);
        }
      }
      debugPrint('[CallLifecycleTracker] setOngoingCallActive: active=$active, callId=$callId');
    } catch (e) {
      debugPrint('[CallLifecycleTracker] setOngoingCallActive error: $e');
    }
  }

  /// Checks if OngoingCallService has an active call.
  /// Checks both memory singleton hook and persistent SharedPreferences.
  static Future<bool> isOngoingCallActive() async {
    if (isForegroundCallActive?.call() == true) {
      return true;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final active = prefs.getBool(_ongoingCallActiveKey) ?? false;
      if (!active) return false;

      final startTs = prefs.getInt(_ongoingCallStartTsKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (startTs > 0 && now - startTs > kOngoingCallMaxDurationMs) {
        await prefs.setBool(_ongoingCallActiveKey, false);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[CallLifecycleTracker] isOngoingCallActive error: $e');
      return false;
    }
  }

  /// Testing helper to reset in-memory cache and SharedPreferences keys.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    _memoryFinishedCalls.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_finishedCallsPrefsKey);
      await prefs.remove(_ongoingCallActiveKey);
      await prefs.remove(_ongoingCallIdKey);
      await prefs.remove(_ongoingCallStartTsKey);
    } catch (_) {}
  }
}
