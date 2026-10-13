import 'package:flutter/services.dart';

class WifiRuntimeNetwork {
  const WifiRuntimeNetwork({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.securityLabel,
    required this.security,
    required this.isOpen,
  });

  final String ssid;
  final String bssid;
  final int rssi;
  final int frequency;
  final String securityLabel;
  final String security;
  final bool isOpen;

  factory WifiRuntimeNetwork.fromMap(Map<dynamic, dynamic> map) {
    final securityLabel = map['securityLabel']?.toString() ?? '';
    final security = map['security']?.toString() ?? securityLabel;
    final explicitOpen = map['open'];
    final isOpen = explicitOpen is bool
        ? explicitOpen
        : security.trim().toLowerCase() == 'open' ||
              securityLabel.trim().toLowerCase() == 'open';

    return WifiRuntimeNetwork(
      ssid: map['ssid']?.toString() ?? '',
      bssid: map['bssid']?.toString() ?? '',
      rssi: (map['rssi'] as num?)?.toInt() ?? -100,
      frequency: (map['frequency'] as num?)?.toInt() ?? 0,
      securityLabel: securityLabel,
      security: security,
      isOpen: isOpen,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'ssid': ssid,
    'bssid': bssid,
    'rssi': rssi,
    'frequency': frequency,
    'securityLabel': securityLabel,
    'security': security,
    'open': isOpen,
  };
}

/// Phone OS Wi-Fi adapter used by the schema-driven Wi-Fi renderer.
///
/// Android implements full SoftAP scan/join via `WifiNativeBridge.kt`.
/// iOS implements the same MethodChannel in `WifiNativeBridge.swift` using
/// HotspotConfiguration + current-SSID (wifi-info); Apple does not allow
/// arbitrary nearby-network scanning.
///
/// UI, labels, screen flow, filtering rules and device-specific values do not
/// live here. Filter values are supplied by the live schema renderer.
class WifiNativeService {
  WifiNativeService._();

  static final WifiNativeService instance = WifiNativeService._();

  static const MethodChannel _channel = MethodChannel(
    'tech.efactor.studio/wifi_native',
  );

  Future<List<WifiRuntimeNetwork>> scanRouterNetworks({
    String? excludeSsidPrefix,
    int? minFrequencyMHz,
    int? maxFrequencyMHz,
  }) async {
    final raw = await _channel
        .invokeListMethod<dynamic>('scanRouterNetworks', <String, dynamic>{
          if (excludeSsidPrefix != null && excludeSsidPrefix.trim().isNotEmpty)
            'excludeSsidPrefix': excludeSsidPrefix.trim(),
          if (minFrequencyMHz != null) 'minFrequencyMHz': minFrequencyMHz,
          if (maxFrequencyMHz != null) 'maxFrequencyMHz': maxFrequencyMHz,
        });

    return (raw ?? const <dynamic>[])
        .whereType<Map>()
        .map(WifiRuntimeNetwork.fromMap)
        .where((network) => network.ssid.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<WifiRuntimeNetwork> scanDeviceSoftAp({
    String? expectedSsid,
    String? ssidPrefix,
    int? minimumRssiDbm,
  }) async {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
      'scanDeviceSoftAp',
      <String, dynamic>{
        if (expectedSsid != null && expectedSsid.trim().isNotEmpty)
          'expectedSsid': expectedSsid.trim(),
        if (ssidPrefix != null && ssidPrefix.trim().isNotEmpty)
          'ssidPrefix': ssidPrefix.trim(),
        if (minimumRssiDbm != null) 'minimumRssiDbm': minimumRssiDbm,
      },
    );

    if (raw == null) {
      throw StateError('Native Wi-Fi scan did not return a device SoftAP.');
    }

    return WifiRuntimeNetwork.fromMap(raw);
  }

  Future<List<WifiRuntimeNetwork>> scanDeviceSoftApCandidates({
    String? ssidPrefix,
    int? minimumRssiDbm,
  }) async {
    final raw = await _channel.invokeListMethod<dynamic>(
      'scanDeviceSoftApCandidates',
      <String, dynamic>{
        if (ssidPrefix != null && ssidPrefix.trim().isNotEmpty)
          'ssidPrefix': ssidPrefix.trim(),
        if (minimumRssiDbm != null) 'minimumRssiDbm': minimumRssiDbm,
      },
    );

    return (raw ?? const <dynamic>[])
        .whereType<Map>()
        .map(WifiRuntimeNetwork.fromMap)
        .where((network) => network.ssid.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<void> connectDeviceSoftAp(String ssid, {String? bssid}) async {
    await _channel.invokeMethod<void>('connectDeviceSoftAp', <String, dynamic>{
      'ssid': ssid.trim(),
      if (bssid != null && bssid.trim().isNotEmpty) 'bssid': bssid.trim(),
    });
  }

  Future<void> disconnectDeviceSoftAp() {
    return _channel.invokeMethod<void>('disconnectDeviceSoftAp');
  }

  /// iOS only: exercise Local Network privacy before SoftAP HTTP sessions.
  ///
  /// On Android this is a no-op success. On iOS it triggers the system Local
  /// Network permission prompt required to reach `192.168.4.1`.
  Future<void> primeLocalNetworkAccess() async {
    try {
      await _channel.invokeMethod<void>('primeLocalNetworkAccess');
    } on MissingPluginException {
      // Android / desktop have no handler — SoftAP session does not need it.
    } on PlatformException {
      // Priming is best-effort; provisioning still proceeds.
    }
  }

  /// iOS only: wait until SoftAP gateway accepts TCP (default 192.168.4.1:80).
  Future<void> waitForSoftApGateway({
    String host = '192.168.4.1',
    int port = 80,
    int timeoutMs = 20000,
  }) async {
    try {
      await _channel.invokeMethod<void>('waitForSoftApGateway', <String, dynamic>{
        'host': host,
        'port': port,
        'timeoutMs': timeoutMs,
      });
    } on MissingPluginException {
      // Android SoftAP path is owned by the provisioning library.
    }
  }

  /// Current associated Wi‑Fi SSID when the platform can report it.
  Future<String?> currentWifiSsid() async {
    try {
      final value = await _channel.invokeMethod<String>('currentWifiSsid');
      final ssid = value?.trim() ?? '';
      return ssid.isEmpty ? null : ssid;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
