import 'dart:convert';

import '../util/uuid.dart';

/// One GPS breadcrumb, matching the backend `POST /breadcrumbs/batch` point
/// shape exactly.
class Breadcrumb {
  Breadcrumb({
    String? clientUuid,
    required this.recordedAt,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedMps,
    this.heading,
    this.altitudeM,
    this.batteryPct,
    this.provider = 'gps',
  }) : clientUuid = clientUuid ?? generateUuidV4();

  final String clientUuid;
  final DateTime recordedAt;
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedMps;
  final double? heading;
  final double? altitudeM;
  final int? batteryPct;
  final String provider;

  /// Wire shape sent to the server (omits null optionals).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'client_uuid': clientUuid,
        // Backend prefers UTC with a trailing Z (offset form also accepted).
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
        if (accuracyM != null) 'accuracy_m': accuracyM,
        if (speedMps != null) 'speed_mps': speedMps,
        if (heading != null) 'heading': heading,
        if (altitudeM != null) 'altitude_m': altitudeM,
        if (batteryPct != null) 'battery_pct': batteryPct,
        'provider': provider,
      };

  /// Persisted shape for the local outbox (keeps recordedAt as an ISO string).
  Map<String, dynamic> toStore() => <String, dynamic>{
        'client_uuid': clientUuid,
        'recorded_at': recordedAt.toIso8601String(),
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
        'speed_mps': speedMps,
        'heading': heading,
        'altitude_m': altitudeM,
        'battery_pct': batteryPct,
        'provider': provider,
      };

  factory Breadcrumb.fromStore(Map<String, dynamic> json) => Breadcrumb(
        clientUuid: json['client_uuid']?.toString(),
        recordedAt: DateTime.tryParse(json['recorded_at']?.toString() ?? '') ??
            DateTime.now(),
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0,
        accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
        speedMps: (json['speed_mps'] as num?)?.toDouble(),
        heading: (json['heading'] as num?)?.toDouble(),
        altitudeM: (json['altitude_m'] as num?)?.toDouble(),
        batteryPct: (json['battery_pct'] as num?)?.toInt(),
        provider: json['provider']?.toString() ?? 'gps',
      );

  String encodeStore() => jsonEncode(toStore());
}
