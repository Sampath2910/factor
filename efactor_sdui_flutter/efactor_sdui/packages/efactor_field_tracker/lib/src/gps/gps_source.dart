import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// A single GPS fix, transport-agnostic.
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedMps,
    this.heading,
    this.altitudeM,
    this.provider = 'gps',
    this.recordedAt,
  });

  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedMps;
  final double? heading;
  final double? altitudeM;
  final String provider;
  final DateTime? recordedAt;
}

/// Produces GPS fixes. An interface so tests (and future adaptive providers)
/// can supply fixes without the device sensor.
abstract interface class GpsSource {
  /// Ensures location permission/service is available. Returns false if the
  /// device can't provide location (denied / disabled).
  Future<bool> ensureAvailable();

  /// A single current fix, or null if unavailable.
  Future<GpsFix?> currentFix();

  /// A continuous stream of fixes. In interval mode ([distanceMeters] null) it
  /// emits roughly every [intervalSeconds]; in distance mode it emits once the
  /// device moves [distanceMeters]. On Android this runs behind a foreground
  /// service and on iOS with background updates, so fixes keep arriving while
  /// the app is backgrounded during duty.
  Stream<GpsFix> fixStream({required int intervalSeconds, int? distanceMeters});
}

/// Default geolocator-backed source.
class GeolocatorGpsSource implements GpsSource {
  const GeolocatorGpsSource({this.accuracy = LocationAccuracy.high});

  final LocationAccuracy accuracy;

  @override
  Future<bool> ensureAvailable() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  @override
  Future<GpsFix?> currentFix() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: accuracy,
      );
      return _toFix(pos);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<GpsFix> fixStream({required int intervalSeconds, int? distanceMeters}) =>
      Geolocator.getPositionStream(
        locationSettings: _streamSettings(intervalSeconds, distanceMeters),
      ).map(_toFix);

  LocationSettings _streamSettings(int intervalSeconds, int? distanceMeters) {
    final distance = distanceMeters ?? 0; // 0 = time/continuous (interval mode)
    if (kIsWeb) {
      return LocationSettings(accuracy: accuracy, distanceFilter: distance);
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // The foreground service (started while the app is visible via
        // startDuty) keeps location flowing after the app is backgrounded.
        return AndroidSettings(
          accuracy: accuracy,
          distanceFilter: distance,
          intervalDuration: Duration(seconds: intervalSeconds),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'On-duty location',
            notificationText: 'Sharing your location while you are on duty.',
            enableWakeLock: true,
          ),
        );
      case TargetPlatform.iOS:
        // Keeps the app alive in the background during an active duty session
        // (blue status-bar indicator). iOS has no time interval; in interval
        // mode the field tracker gates by time. Requires UIBackgroundModes:
        // location.
        return AppleSettings(
          accuracy: accuracy,
          activityType: ActivityType.otherNavigation,
          distanceFilter: distance,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        );
      default:
        return LocationSettings(accuracy: accuracy, distanceFilter: distance);
    }
  }

  static GpsFix _toFix(Position pos) => GpsFix(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyM: pos.accuracy,
        speedMps: pos.speed,
        heading: pos.heading,
        altitudeM: pos.altitude,
        provider: 'gps',
        recordedAt: pos.timestamp,
      );
}
