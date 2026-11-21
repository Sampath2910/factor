import 'dart:convert';

/// The effective Tracking Policy the device must follow, as returned by
/// `GET /effective-policy`. Phase 0 is interval-only; richer fields (geofence,
/// adaptive modes) arrive in later phases and are read defensively.
class TrackingPolicy {
  const TrackingPolicy({
    required this.version,
    this.id,
    this.name,
    this.mode = 'interval',
    this.intervalSeconds = 5,
    this.geofence,
    this.batchMaxPoints = 50,
    this.batchMaxIntervalSeconds = 60,
    this.wifiOnly = false,
    this.checkInOutEnabled = true,
    this.retentionDays = 90,
    this.backgroundEnabled = false,
    this.backgroundIntervalSeconds,
    this.backgroundDistanceMeters,
    this.backgroundMode = 'same',
  });

  /// Opaque version string (`v`) used for cheap 304 refresh. Backend sends it
  /// as a string (e.g. "1"), so we keep it as a string.
  final String version;

  final int? id;
  final String? name;
  final String mode;
  final int intervalSeconds;
  final Map<String, dynamic>? geofence;

  final int batchMaxPoints;
  final int batchMaxIntervalSeconds;
  final bool wifiOnly;

  final bool checkInOutEnabled;
  final int retentionDays;

  /// Server background/power policy (v2+). Config only until the native
  /// background engine (Android foreground service / iOS background location)
  /// ships — parsed now so no later refetch/migration is needed.
  final bool backgroundEnabled;

  /// null means "use the top-level [intervalSeconds]".
  final int? backgroundIntervalSeconds;

  /// For distance mode; null when unused.
  final int? backgroundDistanceMeters;

  /// interval | distance | same.
  final String backgroundMode;

  static int _asInt(dynamic v, int fallback) =>
      v is num ? v.toInt() : (int.tryParse(v?.toString() ?? '') ?? fallback);

  /// Parses the full `GET /effective-policy` 200 response body.
  factory TrackingPolicy.fromResponse(Map<String, dynamic> json) {
    final version = json['v']?.toString() ?? '';
    final policy = (json['policy'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final upload = (policy['upload'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final events = (policy['events'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final background = (policy['background'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    return TrackingPolicy(
      version: version,
      id: policy['id'] is num ? (policy['id'] as num).toInt() : null,
      name: policy['name']?.toString(),
      mode: policy['mode']?.toString() ?? 'interval',
      intervalSeconds: _asInt(policy['interval_seconds'], 5),
      geofence: (policy['geofence'] as Map?)?.cast<String, dynamic>(),
      batchMaxPoints: _asInt(upload['batch_max_points'], 50),
      batchMaxIntervalSeconds: _asInt(upload['batch_max_interval_seconds'], 60),
      wifiOnly: upload['wifi_only'] == true,
      checkInOutEnabled: events['check_in_out_enabled'] != false,
      retentionDays: _asInt(policy['retention_days'], 90),
      backgroundEnabled: background['enabled'] == true,
      backgroundIntervalSeconds: _asIntOrNull(background['interval_seconds']),
      backgroundDistanceMeters: _asIntOrNull(background['distance_meters']),
      backgroundMode: background['mode']?.toString() ?? 'same',
    );
  }

  static int? _asIntOrNull(dynamic v) =>
      v == null ? null : (v is num ? v.toInt() : int.tryParse(v.toString()));

  /// Serialization for the on-device policy cache (so a 304 keeps the last one).
  Map<String, dynamic> toCacheJson() => <String, dynamic>{
        'v': version,
        'policy': <String, dynamic>{
          'id': id,
          'name': name,
          'mode': mode,
          'interval_seconds': intervalSeconds,
          'geofence': geofence,
          'upload': <String, dynamic>{
            'batch_max_points': batchMaxPoints,
            'batch_max_interval_seconds': batchMaxIntervalSeconds,
            'wifi_only': wifiOnly,
          },
          'events': <String, dynamic>{
            'check_in_out_enabled': checkInOutEnabled,
          },
          'background': <String, dynamic>{
            'enabled': backgroundEnabled,
            'interval_seconds': backgroundIntervalSeconds,
            'distance_meters': backgroundDistanceMeters,
            'mode': backgroundMode,
          },
          'retention_days': retentionDays,
        },
      };

  factory TrackingPolicy.fromCacheJson(Map<String, dynamic> json) =>
      TrackingPolicy.fromResponse(json);

  String encode() => jsonEncode(toCacheJson());

  static TrackingPolicy? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) return TrackingPolicy.fromCacheJson(map);
    } catch (_) {}
    return null;
  }

  @override
  String toString() =>
      'TrackingPolicy(v=$version, mode=$mode, interval=${intervalSeconds}s, '
      'batch=$batchMaxPoints/${batchMaxIntervalSeconds}s, wifiOnly=$wifiOnly)';
}
