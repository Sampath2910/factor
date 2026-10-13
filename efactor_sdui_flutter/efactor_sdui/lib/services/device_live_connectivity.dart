import 'package:flutter/foundation.dart';

import '../iot_sdui/iot_schema_repository.dart';
import '../iot_sdui/iot_sdui_state.dart';

/// Resolves the opened device's live online flag using the same IoT schema
/// datasources that render the My Devices list. No URL, action, model, or
/// node value is hardcoded here.
class DeviceLiveConnectivity {
  static Future<bool?> resolve({
    required String accessToken,
    required String nodeId,
  }) async {
    final token = accessToken.trim();
    final target = nodeId.trim();
    if (token.isEmpty || target.isEmpty) return null;

    final source = IotSchemaSource.fromEnvironment();
    final repository = IotSchemaRepository(source: source, accessToken: token);
    try {
      final schema = await repository.load(forceRefresh: false);
      final state = IotSduiState(
        schema: schema,
        accessToken: token,
        apiBaseUri: source.resolvedApiBaseUri,
      );
      try {
        await state.loadInitialData();
        for (final device in state.devices) {
          if (!_matchesNode(device, target)) continue;
          return _asBool(device['online']) ??
              (device['status']?.toString().trim().toLowerCase() == 'online'
                  ? true
                  : device['status']?.toString().trim().toLowerCase() ==
                        'offline'
                  ? false
                  : null);
        }
        return null;
      } finally {
        state.dispose();
      }
    } catch (error) {
      debugPrint('[DEVICE_SDUI][LIVE_ONLINE] $error');
      return null;
    } finally {
      repository.dispose();
    }
  }

  static bool _matchesNode(Map<String, dynamic> device, String nodeId) {
    final target = nodeId.trim().toLowerCase();
    if (target.isEmpty) return false;

    for (final key in const <String>[
      'node_id',
      'nodeId',
      'control_id',
      'controlId',
      'id',
    ]) {
      final value = device[key]?.toString().trim().toLowerCase();
      if (value != null && value.isNotEmpty && value == target) {
        return true;
      }
    }
    return false;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'online' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'offline' || text == 'off') {
      return false;
    }
    return null;
  }
}
