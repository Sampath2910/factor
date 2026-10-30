import AudioToolbox
import AVFoundation
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let wifiNativeBridge = WifiNativeBridge()
  private var isBridgeRegistered = false
  private var incomingRingPlayer: AVAudioPlayer?
  private var incomingRingTimer: Timer?
  private var isOngoingCallAudioActive = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required for FCM / APNs when GoogleService-Info.plist is present.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    application.registerForRemoteNotifications()

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if !isBridgeRegistered, let controller = window?.rootViewController as? FlutterViewController {
      GeneratedPluginRegistrant.register(with: self)
      wifiNativeBridge.register(with: controller.binaryMessenger)
      registerCircleConnectBridge(with: controller.binaryMessenger)
      isBridgeRegistered = true
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if !isBridgeRegistered {
      let messenger = engineBridge.applicationRegistrar.messenger()
      wifiNativeBridge.register(with: messenger)
      registerCircleConnectBridge(with: messenger)
      isBridgeRegistered = true
    }
  }

  private func registerCircleConnectBridge(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tech.efactor/circle_connect", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "getCookies":
        let urlStr = (call.arguments as? [String: Any])?["url"] as? String ?? "https://efactor.tech"
        if let url = URL(string: urlStr), let cookies = HTTPCookieStorage.shared.cookies(for: url) {
          let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
          result(cookieHeader)
        } else {
          result("")
        }
      case "startIncomingRing":
        self.startIncomingRing()
        result(true)
      case "stopIncomingRing":
        self.stopIncomingRing()
        result(true)
      case "startOngoingCallService":
        self.startOngoingCallAudioSession()
        result(true)
      case "stopOngoingCallService":
        self.stopOngoingCallAudioSession()
        result(true)
      case "isOngoingCallActive":
        result(self.isOngoingCallAudioActive)
      case "openNotificationChannelSettings":
        if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
          result(true)
        } else {
          result(false)
        }
      case "getDeviceManufacturer":
        result("apple")
      case "wakeAndUnlock":
        result(true)
      case "canDrawOverlays", "isIgnoringBatteryOptimizations":
        result(true)
      case "openOverlaySettings", "openAutostartSettings", "requestIgnoreBatteryOptimizations", "openFullScreenIntentSettings":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func startOngoingCallAudioSession() {
    isOngoingCallAudioActive = true
    stopIncomingRing()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
      try session.setActive(true)
    } catch {
      NSLog("[AppDelegate] Failed to activate AVAudioSession for ongoing call: \(error.localizedDescription)")
    }
  }

  private func stopOngoingCallAudioSession() {
    isOngoingCallAudioActive = false
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      NSLog("[AppDelegate] Failed to deactivate AVAudioSession for ongoing call: \(error.localizedDescription)")
    }
  }

  private func startIncomingRing() {
    stopIncomingRing()
    guard let url = Bundle.main.url(forResource: "call_ringtone", withExtension: "aiff") else {
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      let player = try AVAudioPlayer(contentsOf: url)
      player.numberOfLoops = -1
      player.play()
      incomingRingPlayer = player
    } catch {
      NSLog("Incoming ring failed: \(error.localizedDescription)")
    }
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    incomingRingTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
  }

  private func stopIncomingRing() {
    incomingRingTimer?.invalidate()
    incomingRingTimer = nil
    incomingRingPlayer?.stop()
    incomingRingPlayer = nil
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
