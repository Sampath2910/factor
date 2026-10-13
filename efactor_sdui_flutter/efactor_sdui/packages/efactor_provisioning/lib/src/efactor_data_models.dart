/// Result of a sendData call. Carries the RAW response from the device (local)
/// or cloud — the app interprets it.
class EfSendDataResult {
  EfSendDataResult({required this.ok, this.errorKind, required this.raw});

  /// true if the send succeeded (device/cloud returned success).
  final bool ok;

  /// When [ok] is false: "response" (server/device rejected) or "network"
  /// (couldn't reach). null on success.
  final String? errorKind;

  /// The raw response as a map (from the native response Bundle). App-interpreted.
  final Map<String, dynamic> raw;

  factory EfSendDataResult.fromMap(Map<dynamic, dynamic> m) => EfSendDataResult(
        ok: m['ok'] == true,
        errorKind: m['errorKind'] as String?,
        raw: (m['raw'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ?? {},
      );

  @override
  String toString() =>
      ok ? 'SendData OK: $raw' : 'SendData FAILED ($errorKind): $raw';
}
