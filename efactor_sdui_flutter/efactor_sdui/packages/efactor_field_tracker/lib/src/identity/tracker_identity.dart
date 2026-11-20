import 'package:shared_preferences/shared_preferences.dart';

import '../util/uuid.dart';

/// The four scope values every track request carries.
class TrackerIdentity {
  const TrackerIdentity({
    required this.appId,
    required this.tenantId,
    required this.userId,
    required this.deviceId,
  });

  final String appId;
  final String tenantId;
  final String userId;
  final String deviceId;

  /// Identity fields merged into request bodies.
  Map<String, dynamic> get body => <String, dynamic>{
        'app_id': appId,
        'tenant_id': tenantId,
        'device_id': deviceId,
        'user_id': userId,
      };

  /// Identity fields as query params for GET /effective-policy.
  Map<String, String> get query => <String, String>{
        'app_id': appId,
        'tenant_id': tenantId,
        'device_id': deviceId,
        'user_id': userId,
      };
}

/// Resolves and persists the stable per-install `device_id`. It survives
/// logout/login and is regenerated only on reinstall (cleared storage) — the
/// same stability contract as the Circle Connect installation id.
class TrackerIdentityStore {
  TrackerIdentityStore({this.appId = 'efactor_field_tracker'});

  final String appId;

  static const String _kDeviceId = 'efactor.field_tracker.device_id';

  Future<String> ensureDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generateUuidV4();
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  /// Builds the full identity. `tenantId`/`userId` come from the host app
  /// (session / profile); for Phase 0 integration the backend seed is used.
  Future<TrackerIdentity> resolve({
    required String tenantId,
    required String userId,
  }) async {
    final deviceId = await ensureDeviceId();
    return TrackerIdentity(
      appId: appId,
      tenantId: tenantId,
      userId: userId,
      deviceId: deviceId,
    );
  }
}
