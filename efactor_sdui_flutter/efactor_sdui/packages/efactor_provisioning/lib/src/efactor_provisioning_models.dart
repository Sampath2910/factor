/// Terminal status of a provisioning attempt.
enum EfProvStatus {
  /// Device locally confirmed it joined the target network.
  success,

  /// Credentials were applied and the device left its SoftAP, but the local
  /// poll could not confirm the join (common on real devices). NOT a failure —
  /// confirm the node is online via the cloud to finalize success.
  appliedUnconfirmed,

  /// A definite failure. See [EfProvisioningEvent.code] for the reason.
  failed,

  /// Still in progress (not a terminal result).
  inProgress,
}

/// A provisioning event from the automatic chain.
///
/// Two kinds arrive on the stream:
///  - progress updates ([stage] set, [status] == inProgress)
///  - a single terminal result ([status] one of success/appliedUnconfirmed/failed)
class EfProvisioningEvent {
  EfProvisioningEvent({
    required this.status,
    this.stage,
    this.code,
    this.detail,
  });

  final EfProvStatus status;

  /// Progress stage name (e.g. createDevice, connect, wifiConfigApplied). Progress only.
  final String? stage;

  /// Machine-readable failure reason when [status] == failed:
  /// AUTH_FAILED, NETWORK_NOT_FOUND, DEVICE_DISCONNECTED, CONNECT_FAILED,
  /// CONFIG_FAILED, UNKNOWN.
  final String? code;

  /// Human-readable detail (may be null).
  final String? detail;

  bool get isTerminal => status != EfProvStatus.inProgress;
  bool get isSuccess => status == EfProvStatus.success;
  bool get isAppliedUnconfirmed => status == EfProvStatus.appliedUnconfirmed;
  bool get isFailure => status == EfProvStatus.failed;

  factory EfProvisioningEvent.fromMap(Map<dynamic, dynamic> m) {
    final kind = m['kind'] as String? ?? 'progress';
    if (kind == 'result') {
      final s = (m['status'] as String? ?? '').toUpperCase();
      final status = switch (s) {
        'SUCCESS' => EfProvStatus.success,
        'APPLIED_UNCONFIRMED' => EfProvStatus.appliedUnconfirmed,
        'FAILED' => EfProvStatus.failed,
        _ => EfProvStatus.failed,
      };
      return EfProvisioningEvent(
        status: status,
        code: m['code'] as String?,
        detail: m['detail'] as String?,
      );
    }
    // progress
    return EfProvisioningEvent(
      status: EfProvStatus.inProgress,
      stage: m['stage'] as String?,
      detail: m['detail'] as String?,
    );
  }

  @override
  String toString() {
    return switch (status) {
      EfProvStatus.success => 'Provision: SUCCESS',
      EfProvStatus.appliedUnconfirmed =>
        'Provision: APPLIED (unconfirmed — verify via cloud)',
      EfProvStatus.failed => 'Provision: FAILED [${code ?? "?"}]${detail != null ? " — $detail" : ""}',
      EfProvStatus.inProgress => 'Provision: $stage${detail != null ? " ($detail)" : ""}',
    };
  }
}
