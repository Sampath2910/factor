/// A device discovered on the local network via mDNS.
class EfLocalDevice {
  EfLocalDevice({
    required this.nodeId,
    required this.ip,
    required this.port,
    this.mac,
  });

  final String nodeId;
  final String ip;
  final int port;
  final String? mac;

  factory EfLocalDevice.fromMap(Map<dynamic, dynamic> m) => EfLocalDevice(
        nodeId: m['nodeId'] as String? ?? '',
        ip: m['ip'] as String? ?? '',
        port: (m['port'] as num?)?.toInt() ?? 0,
        mac: m['mac'] as String?,
      );

  @override
  String toString() => 'EfLocalDevice($nodeId @ $ip:$port)';
}

/// A discovery event: a device was found (available) or lost.
class EfDiscoveryEvent {
  EfDiscoveryEvent({required this.found, required this.nodeId, this.ip, this.port});

  final bool found;
  final String nodeId;
  final String? ip;
  final int? port;

  factory EfDiscoveryEvent.fromMap(Map<dynamic, dynamic> m) => EfDiscoveryEvent(
        found: (m['type'] as String?) == 'found',
        nodeId: m['nodeId'] as String? ?? '',
        ip: m['ip'] as String?,
        port: (m['port'] as num?)?.toInt(),
      );

  @override
  String toString() => found
      ? 'EfDiscoveryEvent(found $nodeId @ $ip:$port)'
      : 'EfDiscoveryEvent(lost $nodeId)';
}
