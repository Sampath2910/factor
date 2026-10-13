import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'json_http.dart';

/// Durable last-known live parameter values for one device (model + node).
///
/// Cloud telemetry (`auto_get_nodes_params`) arrives sporadically. The schema
/// snapshot still publishes `"--"` placeholders. Caching the last real values
/// keeps power / speed / direction / voltage visible across restarts and
/// between pushes, and only rewrites a key when the value actually changes.
class DeviceParameterStore {
  DeviceParameterStore({
    required this.modelId,
    required this.nodeId,
  });

  final String modelId;
  final String nodeId;

  static const String _prefsPrefix = 'efactor.device.live_params.v1.';

  /// Wipes all stored live device parameters from disk/SharedPreferences on logout.
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefsPrefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
      logDebug('[DEVICE_PARAMS][CACHE] cleared ${keys.length} parameter caches');
    } catch (e) {
      logDebug('[DEVICE_PARAMS][CACHE] clearAll failed: $e');
    }
  }

  String get _prefsKey {
    final model = Uri.encodeComponent(modelId.trim());
    final node = Uri.encodeComponent(nodeId.trim());
    return '$_prefsPrefix$model.$node';
  }

  /// Reads the last stored parameter map, or null when nothing was saved.
  Future<Map<String, dynamic>?> read() async {
    if (modelId.trim().isEmpty || nodeId.trim().isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
    } catch (error) {
      logDebug('[DEVICE_PARAMS][CACHE] read failed: $error');
      return null;
    }
  }

  /// Persists [parameters] only when the encoded payload differs from disk.
  ///
  /// Returns `true` when a write happened.
  Future<bool> writeIfChanged(Map<String, dynamic> parameters) async {
    if (modelId.trim().isEmpty || nodeId.trim().isEmpty) return false;
    if (parameters.isEmpty) return false;

    // Drop unset placeholders so we never re-hydrate `"--"`.
    final cleaned = <String, dynamic>{};
    for (final entry in parameters.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty) continue;
      final value = entry.value;
      if (_isUnset(value)) continue;
      cleaned[key] = value;
    }
    if (cleaned.isEmpty) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(cleaned);
      final previous = prefs.getString(_prefsKey);
      if (previous == encoded) return false;
      await prefs.setString(_prefsKey, encoded);
      logDebug(
        '[DEVICE_PARAMS][CACHE] saved model=$modelId node=$nodeId '
        'keys=${cleaned.length}',
      );
      return true;
    } catch (error) {
      logDebug('[DEVICE_PARAMS][CACHE] write failed: $error');
      return false;
    }
  }

  static bool _isUnset(dynamic value) {
    if (value == null) return true;
    if (value is String) {
      final text = value.trim().toLowerCase();
      return text.isEmpty ||
          text == '--' ||
          text == '-' ||
          text == 'n/a' ||
          text == 'na' ||
          text == 'null' ||
          text == 'undefined' ||
          text == 'nil';
    }
    return false;
  }
}
