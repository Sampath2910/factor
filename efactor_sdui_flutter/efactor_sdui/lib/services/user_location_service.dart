import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../auth_sdui/auth_secure_storage.dart';

/// Service responsible for sending location telemetry to eFactor backend APIs:
///
/// 1. `user_currentLocation`
///    Payload: latitude, longitude, app_version, handset_id, handset_name, model, os
///    Invoked when location permissions/services are ready on app startup and home entry.
///
/// 2. `user_signupLocation`
///    Payload: latitude, longitude, app_version, email, mobile_number
///    Invoked during user registration/signup verification.
///
/// Both endpoints are designed for dual-platform compatibility on Android and iOS.
class UserLocationService {
  UserLocationService._({http.Client? client, DeviceInfoPlugin? deviceInfo})
      : _client = client ?? http.Client(),
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  static final UserLocationService instance = UserLocationService._();

  final http.Client _client;
  final DeviceInfoPlugin _deviceInfo;

  static const String _baseUrl = 'https://efactor.tech/v8/api.php';
  static const String appVersion = 'v5.2';

  DateTime? _lastCurrentLocationSentAt;
  static const Duration _currentLocationThrottle = Duration(minutes: 15);
  bool _isSendingCurrentLocation = false;

  String? _lastReportedSignupEmail;

  /// Sends the current device location and hardware details to `user_currentLocation`.
  /// Fully cross-platform: handles Android build details and iOS machine/vendor IDs.
  Future<bool> sendCurrentLocation({
    bool force = false,
    String? accessToken,
    String? userId,
    String? email,
    String? username,
  }) async {
    if (_isSendingCurrentLocation) {
      debugPrint(
        '[UserLocationService] sendCurrentLocation skipped: already in flight',
      );
      return false;
    }

    final rawToken = accessToken ??
        (await AuthSecureStorage().readSession())['accessToken'];
    if (rawToken == null || rawToken.trim().isEmpty) {
      debugPrint(
        '[UserLocationService] Skipped user_currentLocation: not authenticated (no access token)',
      );
      return false;
    }

    final token = rawToken
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

    final now = DateTime.now();
    if (!force &&
        _lastCurrentLocationSentAt != null &&
        now.difference(_lastCurrentLocationSentAt!) < _currentLocationThrottle) {
      debugPrint(
        '[UserLocationService] current location throttled (sent recently)',
      );
      return false;
    }

    _isSendingCurrentLocation = true;
    try {
      final position = await _resolvePosition();
      if (position == null) {
        debugPrint(
          '[UserLocationService] current location unavailable (permission/service off)',
        );
        return false;
      }

      final deviceMeta = await _resolveDeviceMetadata();

      final payload = <String, dynamic>{
        'latitude': position.latitude.toString(),
        'longitude': position.longitude.toString(),
        'app_version': appVersion,
        'handset_id': deviceMeta['handset_id'] ?? '',
        'handset_name': deviceMeta['handset_name'] ?? '',
        'model': deviceMeta['model'] ?? '',
        'os': deviceMeta['os'] ?? '',
        'access_token': token,
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
        if (email != null && email.isNotEmpty) 'email': email,
        if (username != null && username.isNotEmpty) 'username': username,
      };

      final uri = Uri.parse('$_baseUrl?action=user_currentLocation');
      debugPrint(
        '[UserLocationService] POST user_currentLocation ($uri): $payload',
      );

      final response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': token,
              'access_token': token,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint(
        '[UserLocationService] user_currentLocation response '
        'status=${response.statusCode} body=${response.body}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final bodyStr = response.body.toLowerCase();
        if (!bodyStr.contains('"error"') && !bodyStr.contains('not valid')) {
          _lastCurrentLocationSentAt = now;
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('[UserLocationService] Failed to send current location: $e');
      return false;
    } finally {
      _isSendingCurrentLocation = false;
    }
  }

  /// Sends user registration coordinates to `user_signupLocation`.
  /// Captures latitude, longitude, app_version, email, and mobile_number.
  Future<bool> sendSignupLocation({
    required String email,
    required String mobileNumber,
    String? accessToken,
  }) async {
    final cleanEmail = email.trim();
    final cleanMobile = mobileNumber.trim();

    if (cleanEmail.isEmpty && cleanMobile.isEmpty) {
      debugPrint(
        '[UserLocationService] Skipped signup location: email and mobile are empty',
      );
      return false;
    }

    if (_lastReportedSignupEmail == cleanEmail && cleanEmail.isNotEmpty) {
      debugPrint(
        '[UserLocationService] Signup location already reported for $cleanEmail',
      );
      return false;
    }

    try {
      final position = await _resolvePosition();
      final lat = position?.latitude.toString() ?? '';
      final lng = position?.longitude.toString() ?? '';

      final rawToken = accessToken ??
          (await AuthSecureStorage().readSession())['accessToken'];
      final token = rawToken
          ?.trim()
          .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

      final payload = <String, dynamic>{
        'latitude': lat,
        'longitude': lng,
        'app_version': appVersion,
        'email': cleanEmail,
        'mobile_number': cleanMobile,
        if (token != null && token.isNotEmpty) 'access_token': token,
      };

      final uri = Uri.parse('$_baseUrl?action=user_signupLocation');
      debugPrint(
        '[UserLocationService] POST user_signupLocation ($uri): $payload',
      );

      final response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (token != null && token.isNotEmpty) ...<String, String>{
                'Authorization': token,
                'access_token': token,
              },
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint(
        '[UserLocationService] user_signupLocation response '
        'status=${response.statusCode} body=${response.body}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final bodyStr = response.body.toLowerCase();
        if (!bodyStr.contains('"error"') && !bodyStr.contains('not valid')) {
          _lastReportedSignupEmail = cleanEmail;
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('[UserLocationService] Failed to send signup location: $e');
      return false;
    }
  }

  /// Resolves GPS position safely with non-blocking checks.
  /// Background services MUST NOT prompt user permissions via requestPermission().
  Future<Position?> _resolvePosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      if (!serviceEnabled) return null;

      final permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 2),
        onTimeout: () => LocationPermission.denied,
      );
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }

      try {
        return await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 5),
        );
      } catch (_) {
        return await Geolocator.getLastKnownPosition().timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
      }
    } catch (e) {
      debugPrint('[UserLocationService] Location resolution error: $e');
      return null;
    }
  }

  /// Extracts platform-specific device metadata for both Android and iOS.
  Future<Map<String, String>> _resolveDeviceMetadata() async {
    if (Platform.isAndroid) {
      try {
        final info = await _deviceInfo.androidInfo;
        final brand = info.brand.trim();
        final manufacturer = info.manufacturer.trim();
        final model = info.model.trim();
        final name = manufacturer.isNotEmpty
            ? (model.startsWith(manufacturer) ? model : '$manufacturer $model')
            : (brand.isNotEmpty ? '$brand $model' : model);

        return <String, String>{
          'handset_id': info.id.isNotEmpty ? info.id : info.fingerprint,
          'handset_name': name,
          'model': model,
          'os': 'Android ${info.version.release}',
        };
      } catch (e) {
        debugPrint('[UserLocationService] Error reading Android device info: $e');
      }
    } else if (Platform.isIOS) {
      try {
        final info = await _deviceInfo.iosInfo;
        return <String, String>{
          'handset_id': info.identifierForVendor ?? 'ios-device',
          'handset_name': info.name,
          'model': info.utsname.machine,
          'os': 'iOS ${info.systemVersion}',
        };
      } catch (e) {
        debugPrint('[UserLocationService] Error reading iOS device info: $e');
      }
    }

    return <String, String>{
      'handset_id': 'unknown',
      'handset_name': Platform.operatingSystem,
      'model': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion,
    };
  }
}
