import 'dart:typed_data';

/// ESP security scheme used to establish the provisioning session.
/// Matches ESPProvision (iOS) / esp-idf-provisioning (Android) values.
enum EfSecurity { sec0, sec1, sec2 }

/// Transport for reaching the device. This plugin targets Wi-Fi SoftAP only,
/// but the enum leaves room without widening the native surface today.
enum EfTransport { softap }

/// High-level lifecycle of a provisioning attempt.
enum EfProvState {
  idle,
  connecting,
  connected,
  scanning,
  sendingCredentials,
  sendingCustomData,
  success,
  failure,
  disconnected,
}

/// A Wi-Fi network discovered by the device during scan.
class EfWifiNetwork {
  EfWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.auth,
    this.channel,
  });

  final String ssid;
  final int rssi;

  /// Auth mode as reported by the device (0 = open, etc.). Kept as int to avoid
  /// coupling to a specific SDK enum; interpret in UI as needed.
  final int auth;
  final int? channel;

  factory EfWifiNetwork.fromMap(Map<dynamic, dynamic> m) => EfWifiNetwork(
        ssid: m['ssid'] as String? ?? '',
        rssi: (m['rssi'] as num?)?.toInt() ?? 0,
        auth: (m['auth'] as num?)?.toInt() ?? 0,
        channel: (m['channel'] as num?)?.toInt(),
      );

  @override
  String toString() => 'EfWifiNetwork(ssid=$ssid, rssi=$rssi, auth=$auth)';
}

/// Result of the custom-endpoint round trip (your efactorprotov2 layer).
class EfCustomResponse {
  EfCustomResponse({required this.bytes});

  /// Raw protobuf-encoded response bytes from the device's custom endpoint.
  /// Decode these with your generated efactorprotov2 Dart bindings.
  final Uint8List bytes;

  factory EfCustomResponse.fromMap(Map<dynamic, dynamic> m) => EfCustomResponse(
        bytes: m['data'] is Uint8List
            ? m['data'] as Uint8List
            : Uint8List.fromList(List<int>.from(m['data'] as List? ?? const [])),
      );

  @override
  String toString() => 'EfCustomResponse(${bytes.length} bytes)';
}

/// Thrown when a native call fails. Carries the native code + step so failures
/// are easy to trace during testing.
class EfProvisioningException implements Exception {
  EfProvisioningException(this.code, this.message, {this.step, this.details});

  final String code;
  final String message;
  final EfProvState? step;
  final Object? details;

  @override
  String toString() =>
      'EfProvisioningException($code${step != null ? ' @${step!.name}' : ''}): $message';
}
