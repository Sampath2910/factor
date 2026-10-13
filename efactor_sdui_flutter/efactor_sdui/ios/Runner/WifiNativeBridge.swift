import Flutter
import Foundation
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import UIKit

/// iOS counterpart to Android `WifiNativeBridge`.
///
/// Apple does not allow arbitrary Wi‑Fi scanning. This bridge:
/// - Returns the phone's **current** Wi‑Fi SSID for router selection
///   (`com.apple.developer.networking.wifi-info`).
/// - Joins an open SoftAP via `NEHotspotConfiguration`
///   (`com.apple.developer.networking.HotspotConfiguration`).
/// - Primes Local Network permission before SoftAP HTTP sessions.
final class WifiNativeBridge: NSObject, NetServiceBrowserDelegate {
  static let channelName = "tech.efactor.studio/wifi_native"

  private var activeSoftApSsid: String?
  private var localNetworkConnection: NWConnection?
  private var localNetworkConnections: [NWConnection] = []
  private var bonjourBrowser: NetServiceBrowser?
  private var localNetworkPrimeResult: FlutterResult?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "WIFI_BRIDGE_GONE",
            message: "Wi-Fi native bridge was disposed.",
            details: nil
          )
        )
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "scanRouterNetworks":
      scanRouterNetworks(args: args, result: result)

    case "scanDeviceSoftAp":
      scanDeviceSoftAp(args: args, result: result)

    case "scanDeviceSoftApCandidates":
      scanDeviceSoftApCandidates(args: args, result: result)

    case "connectDeviceSoftAp":
      connectDeviceSoftAp(args: args, result: result)

    case "disconnectDeviceSoftAp":
      disconnectDeviceSoftAp(result: result)

    case "primeLocalNetworkAccess":
      primeLocalNetworkAccess(result: result)

    case "waitForSoftApGateway":
      waitForSoftApGateway(args: args, result: result)

    case "currentWifiSsid":
      fetchCurrentWifiSsid { ssid in
        result(ssid)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Local Network permission

  /// Triggers the iOS Local Network permission prompt via Bonjour browse of
  /// `_efactor._tcp` (declared in Info.plist). SoftAP session HTTP to
  /// `192.168.4.1` fails with "couldn't create session / appears offline"
  /// when this permission is denied.
  private func primeLocalNetworkAccess(result: @escaping FlutterResult) {
    cancelLocalNetworkProbes()
    localNetworkPrimeResult = result

    let browser = NetServiceBrowser()
    browser.delegate = self
    bonjourBrowser = browser
    browser.searchForServices(ofType: "_efactor._tcp.", inDomain: "local.")

    // Also poke SoftAP gateway IP so Local Network covers direct HTTP.
    let tcp = NWConnection(
      host: NWEndpoint.Host("192.168.4.1"),
      port: NWEndpoint.Port(rawValue: 80)!,
      using: .tcp
    )
    tcp.stateUpdateHandler = { (_: NWConnection.State) in }
    localNetworkConnection = tcp
    localNetworkConnections.append(tcp)
    tcp.start(queue: .main)

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.finishLocalNetworkPrime()
    }
  }

  private func finishLocalNetworkPrime() {
    bonjourBrowser?.stop()
    bonjourBrowser = nil
    cancelLocalNetworkProbes()
    if let result = localNetworkPrimeResult {
      localNetworkPrimeResult = nil
      result(true)
    }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    // Finding any service is enough to exercise Local Network privacy.
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    NSLog("WifiNativeBridge Bonjour browse failed: \(errorDict)")
  }

  private func cancelLocalNetworkProbes() {
    localNetworkConnection?.cancel()
    localNetworkConnection = nil
    for connection in localNetworkConnections {
      connection.cancel()
    }
    localNetworkConnections.removeAll()
  }

  /// Polls until TCP port 80 on SoftAP gateway responds (or timeout).
  private func waitForSoftApGateway(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let host = ((args["host"] as? String) ?? "192.168.4.1")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let portValue = (args["port"] as? NSNumber)?.uint16Value ?? 80
    let port = NWEndpoint.Port(rawValue: portValue) ?? NWEndpoint.Port(rawValue: 80)!
    let timeoutMs = max(
      1000,
      (args["timeoutMs"] as? NSNumber)?.intValue ?? 20000
    )
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    var finished = false

    func complete(_ value: Any?) {
      guard !finished else { return }
      finished = true
      cancelLocalNetworkProbes()
      result(value)
    }

    func attempt() {
      guard !finished else { return }
      cancelLocalNetworkProbes()

      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: port,
        using: .tcp
      )
      localNetworkConnection = connection
      localNetworkConnections.append(connection)
      var probeSettled = false

      connection.stateUpdateHandler = { (state: NWConnection.State) in
        switch state {
        case .ready:
          guard !probeSettled else { return }
          probeSettled = true
          complete(true)
        case .failed:
          guard !probeSettled else { return }
          probeSettled = true
          connection.cancel()
          if Date() >= deadline {
            complete(
              FlutterError(
                code: "SOFTAP_GATEWAY_UNREACHABLE",
                message:
                  "Device SoftAP gateway \(host) is not reachable. "
                  + "Join the EWIFI_ network when prompted, allow Local "
                  + "Network access, and keep the device in provisioning mode.",
                details: nil
              )
            )
          } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
              attempt()
            }
          }
        default:
          break
        }
      }
      connection.start(queue: .main)

      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        guard !finished, !probeSettled else { return }
        probeSettled = true
        connection.cancel()
        if Date() >= deadline {
          complete(
            FlutterError(
              code: "SOFTAP_GATEWAY_UNREACHABLE",
              message:
                "Device SoftAP gateway \(host) is not reachable. "
                + "Join the EWIFI_ network when prompted, allow Local "
                + "Network access, and keep the device in provisioning mode.",
              details: nil
            )
          )
        } else {
          attempt()
        }
      }
    }

    attempt()
  }

  // MARK: - Router networks (current Wi‑Fi only on iOS)

  private func scanRouterNetworks(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let excludePrefix = ((args["excludeSsidPrefix"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    fetchCurrentWifiSsid { [weak self] ssid in
      guard let self else {
        result([])
        return
      }

      guard let ssid, !ssid.isEmpty else {
        result(
          FlutterError(
            code: "WIFI_SSID_UNAVAILABLE",
            message:
              "iOS cannot scan nearby Wi‑Fi networks. Connect this iPhone to "
              + "your home Wi‑Fi in Settings, enable Local Network for this "
              + "app, then return here. The current network will be offered "
              + "as the router.",
            details: nil
          )
        )
        return
      }

      if !excludePrefix.isEmpty,
         ssid.lowercased().hasPrefix(excludePrefix.lowercased()) {
        result([])
        return
      }

      result([self.networkMap(ssid: ssid, open: false)])
    }
  }

  // MARK: - SoftAP discovery

  private func scanDeviceSoftAp(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let expected = ((args["expectedSsid"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = ((args["ssidPrefix"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !expected.isEmpty {
      result(networkMap(ssid: expected, open: true))
      return
    }

    // iOS cannot enumerate SoftAPs. Prefer the phone's current SSID when it
    // already matches the provisioning prefix (user joined SoftAP in Settings).
    fetchCurrentWifiSsid { [weak self] ssid in
      guard let self else {
        result(
          FlutterError(
            code: "EFACTOR_DEVICE_NOT_FOUND",
            message: "No matching provisioning network was found.",
            details: nil
          )
        )
        return
      }

      if let ssid,
         !ssid.isEmpty,
         prefix.isEmpty || ssid.lowercased().hasPrefix(prefix.lowercased()) {
        result(self.networkMap(ssid: ssid, open: true))
        return
      }

      result(
        FlutterError(
          code: "EFACTOR_DEVICE_NOT_FOUND",
          message:
            "iOS cannot scan for SoftAP networks. Join the device Wi‑Fi "
            + (prefix.isEmpty ? "" : "(\"\(prefix)…\") ")
            + "in Settings → Wi‑Fi, or provide the exact SoftAP SSID from the "
            + "device QR / schema, then retry.",
          details: nil
        )
      )
    }
  }

  private func scanDeviceSoftApCandidates(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let prefix = ((args["ssidPrefix"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    fetchCurrentWifiSsid { [weak self] ssid in
      guard let self else {
        result([])
        return
      }

      guard let ssid, !ssid.isEmpty else {
        result([])
        return
      }

      if !prefix.isEmpty, !ssid.lowercased().hasPrefix(prefix.lowercased()) {
        result([])
        return
      }

      result([self.networkMap(ssid: ssid, open: true)])
    }
  }

  // MARK: - SoftAP join / leave

  private func connectDeviceSoftAp(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let ssid = ((args["ssid"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let bssid = ((args["bssid"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !ssid.isEmpty else {
      result(
        FlutterError(
          code: "MISSING_DEVICE_SSID",
          message: "Device SoftAP SSID is required.",
          details: nil
        )
      )
      return
    }

    let configuration = NEHotspotConfiguration(ssid: ssid)
    // Keep association for the full SoftAP session — joinOnce can drop mid-flow.
    configuration.joinOnce = false

    NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
      if let error = error as NSError? {
        // Already associated is success for SoftAP provisioning.
        if error.domain == NEHotspotConfigurationErrorDomain,
           error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
          self?.activeSoftApSsid = ssid
          self?.confirmSoftApAssociation(
            expectedSsid: ssid,
            bssid: bssid,
            result: result
          )
          return
        }

        result(
          FlutterError(
            code: "DEVICE_SOFTAP_CONNECT_FAILED",
            message:
              "iOS could not join SoftAP '\(ssid)'. \(error.localizedDescription) "
              + "Approve the system Wi‑Fi join prompt if shown, keep the device "
              + "in provisioning mode, and stay close to it.",
            details: nil
          )
        )
        return
      }

      self?.activeSoftApSsid = ssid
      self?.confirmSoftApAssociation(
        expectedSsid: ssid,
        bssid: bssid,
        result: result
      )
    }
  }

  /// After HotspotConfiguration apply, wait until wifi-info reports the SoftAP
  /// SSID (or timeout). Association callbacks can fire before the interface is
  /// ready for HTTP to 192.168.4.1.
  private func confirmSoftApAssociation(
    expectedSsid: String,
    bssid: String,
    result: @escaping FlutterResult
  ) {
    let deadline = Date().addingTimeInterval(12)
    let expectedLower = expectedSsid.lowercased()

    func poll() {
      fetchCurrentWifiSsid { current in
        if let current,
           !current.isEmpty,
           current.lowercased() == expectedLower {
          result([
            "connected": true,
            "ssid": current,
            "bssid": bssid,
            "verified": true,
          ])
          return
        }

        if Date() >= deadline {
          // Hotspot apply succeeded; SSID may still be unavailable without
          // Location. Proceed — SoftAP gateway wait is the hard gate.
          result([
            "connected": true,
            "ssid": expectedSsid,
            "bssid": bssid,
            "verified": false,
          ])
          return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          poll()
        }
      }
    }

    poll()
  }

  private func disconnectDeviceSoftAp(result: @escaping FlutterResult) {
    if let ssid = activeSoftApSsid, !ssid.isEmpty {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      activeSoftApSsid = nil
    }
    result(nil)
  }

  // MARK: - Helpers

  private func networkMap(ssid: String, open: Bool) -> [String: Any] {
    [
      "ssid": ssid,
      "bssid": "",
      "rssi": -50,
      "frequency": 0,
      "securityLabel": open ? "Open" : "WPA2",
      "security": open ? "Open" : "WPA2",
      "open": open,
    ]
  }

  private func fetchCurrentWifiSsid(completion: @escaping (String?) -> Void) {
    if #available(iOS 14.0, *) {
      NEHotspotNetwork.fetchCurrent { network in
        if let ssid = network?.ssid, !ssid.isEmpty {
          completion(ssid)
          return
        }
        completion(self.legacyCaptiveSsid())
      }
      return
    }

    completion(legacyCaptiveSsid())
  }

  private func legacyCaptiveSsid() -> String? {
    guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
      return nil
    }
    for name in interfaces {
      guard
        let info = CNCopyCurrentNetworkInfo(name as CFString) as? [String: Any],
        let ssid = info[kCNNetworkInfoKeySSID as String] as? String,
        !ssid.isEmpty
      else {
        continue
      }
      return ssid
    }
    return nil
  }
}
