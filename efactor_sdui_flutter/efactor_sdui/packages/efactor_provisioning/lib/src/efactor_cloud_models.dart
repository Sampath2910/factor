/// Cloud WebSocket event types, mirroring EfactorCloudCallback.
enum EfCloudEventType { connected, message, disconnected, error }

/// A single cloud event delivered from native over the event stream.
class EfCloudEvent {
  EfCloudEvent({required this.type, this.message});

  final EfCloudEventType type;

  /// For [EfCloudEventType.message] the reshaped JSON payload;
  /// for [EfCloudEventType.error] the error text; otherwise null.
  final String? message;

  factory EfCloudEvent.fromMap(Map<dynamic, dynamic> m) {
    final t = m['type'] as String? ?? 'error';
    return EfCloudEvent(
      type: EfCloudEventType.values.firstWhere(
        (e) => e.name == t,
        orElse: () => EfCloudEventType.error,
      ),
      message: m['message'] as String?,
    );
  }

  @override
  String toString() =>
      'EfCloudEvent(${type.name}${message != null ? ': $message' : ''})';
}
