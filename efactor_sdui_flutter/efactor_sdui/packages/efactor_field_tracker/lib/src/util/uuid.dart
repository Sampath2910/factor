import 'dart:math';

/// Generates a cryptographically secure lowercase RFC 4122 version 4 UUID.
///
/// Used for each breadcrumb/event `client_uuid` (server-side idempotency) and
/// for the stable per-install `device_id`.
String generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) buffer.write('-');
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString().toLowerCase();
}
