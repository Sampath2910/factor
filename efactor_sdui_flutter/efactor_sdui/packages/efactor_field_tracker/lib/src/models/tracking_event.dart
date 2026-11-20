import '../util/uuid.dart';

/// A check-in / check-out event, matching `POST /events`.
enum TrackingEventType { checkIn, checkOut }

extension TrackingEventTypeWire on TrackingEventType {
  String get wire =>
      this == TrackingEventType.checkIn ? 'check_in' : 'check_out';
}

class TrackingEvent {
  TrackingEvent({
    String? clientUuid,
    required this.type,
    required this.recordedAt,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.siteId,
    this.note,
  }) : clientUuid = clientUuid ?? generateUuidV4();

  final String clientUuid;
  final TrackingEventType type;
  final DateTime recordedAt;
  final double lat;
  final double lng;
  final double? accuracyM;
  final String? siteId;
  final String? note;

  /// Body fields specific to the event (identity fields are added by the API
  /// client so this stays identity-agnostic).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'client_uuid': clientUuid,
        'type': type.wire,
        // Backend prefers UTC with a trailing Z (offset form also accepted).
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
        if (accuracyM != null) 'accuracy_m': accuracyM,
        if (siteId != null) 'site_id': siteId,
        if (note != null) 'note': note,
      };
}
