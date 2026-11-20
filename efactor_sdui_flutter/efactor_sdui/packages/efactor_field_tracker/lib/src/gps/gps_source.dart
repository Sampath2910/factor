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
      return GpsFix(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyM: pos.accuracy,
        speedMps: pos.speed,
        heading: pos.heading,
        altitudeM: pos.altitude,
        provider: 'gps',
        recordedAt: pos.timestamp,
      );
    } catch (_) {
      return null;
    }
  }
}
