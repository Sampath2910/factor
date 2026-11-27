import AudioToolbox
import AVFoundation
import Flutter
import Photos
import QuickLook
import UIKit
import UserNotifications
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let wifiNativeBridge = WifiNativeBridge()
  private var isBridgeRegistered = false
  private var incomingRingPlayer: AVAudioPlayer?
  private var incomingRingTimer: Timer?
  private var isOngoingCallAudioActive = false
  private var documentInteractionController: UIDocumentInteractionController?
  private var previewAudioPlayer: AVAudioPlayer?

  // Call-audio contract: native owns OS audio session + physical output route;
  // publishes route snapshots to Dart via `onAudioRoutesChanged`.
  private var circleConnectChannel: FlutterMethodChannel?
  private var callAudioIsVideo = false
  private var callAudioActiveId: String?
  private var callAudioRouteObserver: NSObjectProtocol?

  // Notification-tap bridging. Because this app uses UIScene +
  // FlutterImplicitEngineDelegate, FLTFirebaseMessagingPlugin misses the tap
  // callbacks, so we capture taps natively and forward them to Dart over the
  // existing tech.efactor/circle_connect channel.
  private var pendingNotificationTapData: [String: Any]?
  private var isDartNotificationReady = false
  private var lastHandledTapKey: String?
  private var lastHandledTapAt: Date?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required for FCM / APNs when GoogleService-Info.plist is present.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    application.registerForRemoteNotifications()

    // Cold-start tap delivered via the classic launch-options key (non-scene
    // path / fallback). Buffered until Dart signals ready.
    if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      captureRemoteTap(remote, actionId: nil, input: nil)
    }

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if !isBridgeRegistered, let controller = (window?.rootViewController as? FlutterViewController) ?? (topViewController() as? FlutterViewController) {
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

  func ensureBridgeRegistered(with messenger: FlutterBinaryMessenger) {
    guard !isBridgeRegistered else { return }
    wifiNativeBridge.register(with: messenger)
    registerCircleConnectBridge(with: messenger)
    isBridgeRegistered = true
  }

  private func activeWindow() -> UIWindow? {
    if let window = self.window {
      return window
    }
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene {
        for window in windowScene.windows where window.isKeyWindow {
          return window
        }
        if let first = windowScene.windows.first {
          return first
        }
      }
    }
    return nil
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let root = base ?? activeWindow()?.rootViewController ?? self.window?.rootViewController
    guard let currentRoot = root else { return nil }

    if let nav = currentRoot as? UINavigationController {
      return topViewController(base: nav.visibleViewController ?? nav.topViewController)
    }
    if let tab = currentRoot as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = currentRoot.presentedViewController, !presented.isBeingDismissed {
      return topViewController(base: presented)
    }
    return currentRoot
  }

  private func registerCircleConnectBridge(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tech.efactor/circle_connect", binaryMessenger: messenger)
    self.circleConnectChannel = channel
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "startCallAudio":
        self.startCallAudioSession(callId: args?["callId"] as? String,
                                   video: (args?["video"] as? Bool) ?? false,
                                   preferredRoute: args?["preferredRoute"] as? String)
        result(true)
      case "getCallAudioRoutes":
        self.publishAudioRoutes()
        result(true)
      case "setCallAudioRoute":
        self.applyAudioRoute(routeType: args?["routeType"] as? String,
                             routeId: args?["routeId"] as? String)
        self.publishAudioRoutes()
        result(true)
      case "callMediaTypeChanged":
        self.callAudioIsVideo = (args?["video"] as? Bool) ?? false
        self.publishAudioRoutes()
        result(true)
      case "endCallAudio":
        self.endCallAudioSession(callId: args?["callId"] as? String)
        result(true)
      case "getCookies":
        let urlStr = (call.arguments as? [String: Any])?["url"] as? String ?? "https://efactor.tech"
        let targetUrl = URL(string: urlStr)
        let domain = targetUrl?.host ?? "efactor.tech"

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          let matched = cookies.filter { cookie in
            if cookie.domain.hasPrefix(".") {
              let cleanDomain = String(cookie.domain.dropFirst())
              return domain == cleanDomain || domain.hasSuffix("." + cleanDomain)
            }
            return domain == cookie.domain || domain.hasSuffix("." + cookie.domain)
          }

          if !matched.isEmpty {
            let cookieHeader = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            result(cookieHeader)
          } else if let targetUrl = targetUrl, let sharedCookies = HTTPCookieStorage.shared.cookies(for: targetUrl), !sharedCookies.isEmpty {
            let cookieHeader = sharedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            result(cookieHeader)
          } else {
            result("")
          }
        }
      case "saveImageToGallery":
        guard let args = call.arguments as? [String: Any],
              let base64Str = args["base64"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing image data", details: nil))
          return
        }
        let album = (args["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = (album != nil && !album!.isEmpty) ? album! : "Circle Connect"

        var cleanBase64 = base64Str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commaIndex = cleanBase64.firstIndex(of: ",") {
          cleanBase64 = String(cleanBase64[cleanBase64.index(after: commaIndex)...])
        }
        guard let data = Data(base64Encoded: cleanBase64),
              let image = UIImage(data: data) else {
          result(FlutterError(code: "DECODE_ERROR", message: "Failed to decode Base64 image", details: nil))
          return
        }

        self.saveAssetToAlbum(albumName: albumName, isVideo: false, fileUrl: nil, image: image) { success, error in
          DispatchQueue.main.async {
            if success {
              result(true)
            } else {
              // Fallback to standard album
              UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
              result(true)
            }
          }
        }
      case "saveVideoToGallery":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing video file path", details: nil))
          return
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
          result(FlutterError(code: "FILE_NOT_FOUND", message: "Video file not found at path: \(filePath)", details: nil))
          return
        }
        let album = (args["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = (album != nil && !album!.isEmpty) ? album! : "Circle Connect"
        let fileUrl = URL(fileURLWithPath: filePath)

        self.saveAssetToAlbum(albumName: albumName, isVideo: true, fileUrl: fileUrl, image: nil) { success, error in
          DispatchQueue.main.async {
            if success {
              result(true)
            } else if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(filePath) {
              UISaveVideoAtPathToSavedPhotosAlbum(filePath, nil, nil, nil)
              result(true)
            } else {
              result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription ?? "Could not save video", details: nil))
            }
          }
        }
      case "openFile":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing file path", details: nil))
          return
        }
        self.openFileWithDocumentInteraction(filePath: filePath, result: result)
      case "saveFileToDownloads":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              !filePath.isEmpty else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing or empty filePath", details: nil))
          return
        }
        let fileName = (args["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileName = (fileName != nil && !fileName!.isEmpty) ? fileName! : URL(fileURLWithPath: filePath).lastPathComponent
        let mimeType = (args["mimeType"] as? String) ?? "application/octet-stream"
        self.saveFileToDocuments(filePath: filePath, fileName: resolvedFileName, mimeType: mimeType, result: result)
      case "setAppSound":
        let args = call.arguments as? [String: Any] ?? [:]
        let kind = args["kind"] as? String ?? "ringtone"
        let choice = args["choice"] as? String ?? "phone_default"
        let uri = args["uri"] as? String ?? ""
        let soundId = args["soundId"] as? String ?? ""
        UserDefaults.standard.set(choice, forKey: "efactor_sound_\(kind)_choice")
        UserDefaults.standard.set(uri, forKey: "efactor_sound_\(kind)_uri")
        UserDefaults.standard.set(soundId, forKey: "efactor_sound_\(kind)_sound_id")
        result([
          "changed": true,
          "kind": kind,
          "choice": choice
        ])
      case "playAppSound":
        let args = call.arguments as? [String: Any] ?? [:]
        let kind = args["kind"] as? String ?? "ringtone"
        self.playAppSound(kind: kind, result: result)
      case "stopAppSound":
        self.stopPreviewAudio()
        result(true)
      case "pickSystemSound":
        let args = call.arguments as? [String: Any] ?? [:]
        let kind = args["kind"] as? String ?? "ringtone"
        let reqId = args["requestId"] as? String ?? ""
        result([
          "requestId": reqId,
          "kind": kind,
          "cancelled": true,
          "unsupported": true,
          "message": "System ringtone picker is not supported on iOS"
        ])
      case "startIncomingRing":
        self.startIncomingRing()
        result(true)
      case "stopIncomingRing":
        self.stopIncomingRing()
        result(true)
      case "startOngoingCallService", "stopOngoingCallService":
        // Audio focus/session/routing are owned solely by startCallAudio/
        // endCallAudio. callStarted/callEnded no longer touch audio (iOS has no
        // foreground-service concept, so these are no-ops here).
        result(true)
      case "isOngoingCallActive":
        result(self.isOngoingCallAudioActive)
      case "openNotificationChannelSettings", "openAppNotificationSettings", "openNotificationSettings":
        if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
          result(true)
        } else {
          result(false)
        }
      case "getPendingNotificationTap":
        // Dart is now ready to receive taps live. Hand back and clear any tap
        // buffered during cold start (atomic), and mark ready for live delivery.
        self.isDartNotificationReady = true
        let pending = self.pendingNotificationTapData
        self.pendingNotificationTapData = nil
        result(pending)
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
      // No .duckOthers: other media must pause (not duck) while the call runs.
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
      try session.setActive(true)
    } catch {
      NSLog("[AppDelegate] Failed to activate AVAudioSession for ongoing call: \(error.localizedDescription)")
    }
  }

  // MARK: - Call-audio contract

  // Idempotent and keyed by callId. A repeat start for the active call only
  // re-applies routing; the session/observer are set up once.
  private func startCallAudioSession(callId: String?, video: Bool, preferredRoute: String?) {
    callAudioIsVideo = video
    if isOngoingCallAudioActive && callAudioActiveId == callId {
      applyAudioRoute(routeType: preferredRoute ?? defaultRouteType(video: video), routeId: nil)
      publishAudioRoutes()
      return
    }
    callAudioActiveId = callId
    startOngoingCallAudioSession()
    registerRouteChangeObserver()
    applyAudioRoute(routeType: preferredRoute ?? defaultRouteType(video: video), routeId: nil)
    publishAudioRoutes()
  }

  // Ignores an End whose callId is not the active call (stale/out-of-order).
  private func endCallAudioSession(callId: String?) {
    if !isOngoingCallAudioActive || (callId != nil && callId != callAudioActiveId) { return }
    callAudioActiveId = nil
    if let observer = callAudioRouteObserver {
      NotificationCenter.default.removeObserver(observer)
      callAudioRouteObserver = nil
    }
    stopOngoingCallAudioSession()
  }

  private func registerRouteChangeObserver() {
    if callAudioRouteObserver != nil { return }
    callAudioRouteObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.publishAudioRoutes()
    }
  }

  private func defaultRouteType(video: Bool) -> String {
    // Voice: BT/wired if connected, else receiver. Video: BT/wired else speaker.
    if let connected = connectedHeadsetType() { return connected }
    return video ? "speaker" : "phone"
  }

  private func connectedHeadsetType() -> String? {
    let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
    for input in inputs {
      switch routeType(for: input.portType) {
      case "bluetooth": return "bluetooth"
      case "wired": return "wired"
      default: continue
      }
    }
    return nil
  }

  private func applyAudioRoute(routeType: String?, routeId: String?) {
    let session = AVAudioSession.sharedInstance()
    let type = routeType ?? routeId ?? defaultRouteType(video: callAudioIsVideo)
    do {
      switch type {
      case "speaker":
        try session.overrideOutputAudioPort(.speaker)
      case "bluetooth", "wired":
        try session.overrideOutputAudioPort(.none)
        if let input = (session.availableInputs ?? []).first(where: {
          let rt = self.routeType(for: $0.portType)
          return rt == type && ($0.uid == routeId || routeId == nil)
        }) {
          try session.setPreferredInput(input)
        }
      default: // phone / receiver
        try session.overrideOutputAudioPort(.none)
        try session.setPreferredInput(nil)
      }
    } catch {
      NSLog("[AppDelegate] applyAudioRoute(\(type)) failed: \(error.localizedDescription)")
    }
  }

  private func publishAudioRoutes() {
    let session = AVAudioSession.sharedInstance()
    var routes: [[String: String]] = []
    var seen = Set<String>()
    // Fixed outputs always offered by the UI.
    routes.append(["id": "phone", "type": "phone", "label": "Phone"])
    routes.append(["id": "speaker", "type": "speaker", "label": "Speaker"])
    for input in session.availableInputs ?? [] {
      let type = routeType(for: input.portType)
      if type == "bluetooth" || type == "wired" {
        if seen.insert(input.uid).inserted {
          routes.append(["id": input.uid, "type": type, "label": input.portName])
        }
      }
    }
    // Selected = current output port.
    var selected = "phone"
    if let output = session.currentRoute.outputs.first {
      let type = routeType(for: output.portType)
      selected = (type == "bluetooth" || type == "wired") ? output.uid : type
    }
    let snapshot: [String: Any] = ["selectedRouteId": selected, "routes": routes]
    circleConnectChannel?.invokeMethod("onAudioRoutesChanged", arguments: snapshot)
  }

  private func routeType(for port: AVAudioSession.Port) -> String {
    switch port {
    case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
      return "bluetooth"
    case .headphones, .headsetMic, .usbAudio, .carAudio:
      return "wired"
    case .builtInSpeaker:
      return "speaker"
    case .builtInReceiver, .builtInMic:
      return "phone"
    default:
      return "output"
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

  private func openFileWithDocumentInteraction(filePath: String, result: @escaping FlutterResult) {
    let fileUrl = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: filePath) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "File not found: \(filePath)", details: nil))
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, let topVC = self.topViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No view controller available", details: nil))
        return
      }

      self.documentInteractionController = UIDocumentInteractionController(url: fileUrl)
      self.documentInteractionController?.delegate = self

      // Attempt native QuickLook in-app document preview first
      let presented = self.documentInteractionController?.presentPreview(animated: true) ?? false
      if presented {
        result(["success": true, "type": "preview"])
      } else {
        // If in-app preview is not supported for this specific file, present Open In menu
        let rect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        let menuPresented = self.documentInteractionController?.presentOpenInMenu(from: rect, in: topVC.view, animated: true) ?? false
        result(["success": menuPresented, "type": menuPresented ? "menu" : "failed"])
      }
    }
  }

  private func saveFileToDocuments(
    filePath: String,
    fileName: String,
    mimeType: String,
    result: @escaping FlutterResult
  ) {
    guard FileManager.default.fileExists(atPath: filePath) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "Source file does not exist: \(filePath)", details: nil))
      return
    }

    do {
      let docsUrl = try FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let destUrl = docsUrl.appendingPathComponent(fileName)

      let srcUrl = URL(fileURLWithPath: filePath)
      if srcUrl.standardizedFileURL.path != destUrl.standardizedFileURL.path {
        if FileManager.default.fileExists(atPath: destUrl.path) {
          try FileManager.default.removeItem(at: destUrl)
        }
        try FileManager.default.copyItem(at: srcUrl, to: destUrl)
      }

      DispatchQueue.main.async {
        result([
          "success": true,
          "type": "saved",
          "localPath": destUrl.path,
          "fileName": fileName,
          "mimeType": mimeType
        ])
      }
    } catch {
      NSLog("[AppDelegate] saveFileToDocuments error: \(error.localizedDescription)")
      result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func playAppSound(kind: String, result: @escaping FlutterResult) {
    stopPreviewAudio()
    let isRingtone = (kind == "ringtone")
    if isRingtone {
      if let url = Bundle.main.url(forResource: "call_ringtone", withExtension: "aiff") {
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playback, options: [.duckOthers])
          try session.setActive(true)
          let player = try AVAudioPlayer(contentsOf: url)
          player.numberOfLoops = 0
          player.play()
          previewAudioPlayer = player
          result(true)
          return
        } catch {
          NSLog("[AppDelegate] playAppSound ringtone error: \(error.localizedDescription)")
        }
      }
    } else {
      AudioServicesPlaySystemSound(1007)
      result(true)
      return
    }
    result(false)
  }

  private func stopPreviewAudio() {
    previewAudioPlayer?.stop()
    previewAudioPlayer = nil
  }

  private func saveAssetToAlbum(albumName: String, isVideo: Bool, fileUrl: URL?, image: UIImage?, completion: @escaping (Bool, Error?) -> Void) {
    let performSaveDirectly = {
      PHPhotoLibrary.shared().performChanges({
        if isVideo, let url = fileUrl {
          _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } else if let img = image {
          _ = PHAssetChangeRequest.creationRequestForAsset(from: img)
        }
      }) { success, error in
        if success {
          completion(true, nil)
        } else {
          // UIKit standard fallback directly to Photos
          DispatchQueue.main.async {
            if isVideo, let url = fileUrl, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
              UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
              completion(true, nil)
            } else if let img = image {
              UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
              completion(true, nil)
            } else {
              completion(false, error)
            }
          }
        }
      }
    }

    if #available(iOS 14.0, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized || status == .limited else {
          completion(false, NSError(domain: "CircleConnect", code: 403, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
          return
        }
        performSaveDirectly()
      }
    } else {
      PHPhotoLibrary.requestAuthorization { status in
        guard status == .authorized || status == .limited else {
          completion(false, NSError(domain: "CircleConnect", code: 403, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
          return
        }
        performSaveDirectly()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: { _ in })

    let dataDict = (userInfo["data"] as? [String: Any]) ?? (userInfo as? [String: Any]) ?? [:]
    let convId = (dataDict["conversation_id"] as? String)
      ?? (dataDict["conversationId"] as? String)
      ?? (dataDict["chat_id"] as? String)
      ?? (dataDict["chatId"] as? String)
      ?? ""
    let msgId = (dataDict["message_id"] as? String)
      ?? (dataDict["messageId"] as? String)
      ?? (dataDict["msg_id"] as? String)
      ?? (dataDict["msgId"] as? String)
      ?? ""
    let targetUrl = (dataDict["url"] as? String)
      ?? (dataDict["target_url"] as? String)
      ?? (dataDict["targetUrl"] as? String)

    let cleanConvId = convId.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanMsgId = msgId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !cleanConvId.isEmpty, !cleanMsgId.isEmpty else {
      completionHandler(.noData)
      return
    }

    let deviceKey = UserDefaults.standard.string(forKey: "flutter.efactor.circle_connect.device_key_unencrypted_cache")
      ?? UserDefaults.standard.string(forKey: "efactor.circle_connect.device_key_unencrypted_cache")

    guard let key = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
      NSLog("[AppDelegate] Native background push received, but no device key cached. Skipping native delivered POST.")
      completionHandler(.noData)
      return
    }

    var baseUrl = "https://efactor.tech/index.php/grid-chat/api"
    if let hint = targetUrl, let url = URL(string: hint), let host = url.host, !host.isEmpty {
      let scheme = url.scheme ?? "https"
      baseUrl = "\(scheme)://\(host)/index.php/grid-chat/api"
    }
    guard let endpoint = URL(string: "\(baseUrl)/notification/action") else {
      completionHandler(.noData)
      return
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "X-Device-Key")
    request.timeoutInterval = 10.0

    let bodyString = "action=delivered&conversation_id=\(cleanConvId)&message_id=\(cleanMsgId)"
    request.httpBody = bodyString.data(using: .utf8)

    NSLog("[AppDelegate] Native background delivery POST dispatching to \(endpoint) for convId=\(cleanConvId) msgId=\(cleanMsgId)")
    let task = URLSession.shared.dataTask(with: request) { _, response, error in
      if let httpResp = response as? HTTPURLResponse {
        NSLog("[AppDelegate] Native background delivery POST completed: status=\(httpResp.statusCode)")
        completionHandler(.newData)
      } else {
        NSLog("[AppDelegate] Native background delivery POST failed: \(error?.localizedDescription ?? "unknown error")")
        completionHandler(.failed)
      }
    }
    task.resume()
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  @available(iOS 12.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    let controller = (topViewController() as? FlutterViewController) ?? (window?.rootViewController as? FlutterViewController)
    if let controller = controller {
      let channel = FlutterMethodChannel(name: "tech.efactor/circle_connect", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("openSettingsUrl", arguments: ["url": "https://efactor.tech/index.php/grid-chat/settings"])
    }
  }

  // MARK: - Notification tap capture & bridge

  /// Tap on a delivered notification (background / foreground). FlutterAppDelegate
  /// does NOT forward this to firebase_messaging under UIScene, so we capture it.
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if !isLocalNotification(userInfo) {
      captureRemoteTap(
        userInfo,
        actionId: response.actionIdentifier,
        input: (response as? UNTextInputNotificationResponse)?.userText
      )
    }
    // Keep flutter_local_notifications and other plugins working (call/chat
    // action buttons are owned there).
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// Cold-start tap forwarded from SceneDelegate (UIScene path).
  func handleLaunchNotificationResponse(_ response: UNNotificationResponse) {
    let userInfo = response.notification.request.content.userInfo
    guard !isLocalNotification(userInfo) else { return }
    captureRemoteTap(
      userInfo,
      actionId: response.actionIdentifier,
      input: (response as? UNTextInputNotificationResponse)?.userText
    )
  }

  /// Local notifications (calls / chat action buttons) are owned by
  /// flutter_local_notifications; never double-handle them here.
  private func isLocalNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    return userInfo["NotificationId"] != nil && userInfo["payload"] != nil
  }

  private func captureRemoteTap(_ userInfo: [AnyHashable: Any], actionId: String?, input: String?) {
    var payload = flattenUserInfo(userInfo)
    if let actionId = actionId, actionId != UNNotificationDefaultActionIdentifier {
      payload["actionId"] = actionId
    }
    if let input = input { payload["input"] = input }

    // Deduplicate rapid duplicate callbacks within ~3s (keyed by message id,
    // conversation and action). A second dedup window exists on the Dart side.
    let key = [
      payload["_fcm_message_id"] as? String ?? "",
      payload["conversation_id"] as? String ?? payload["conversationId"] as? String ?? "",
      payload["actionId"] as? String ?? ""
    ].joined(separator: "|")
    let now = Date()
    if key == lastHandledTapKey, let last = lastHandledTapAt, now.timeIntervalSince(last) < 3.0 {
      return
    }
    lastHandledTapKey = key
    lastHandledTapAt = now

    if isDartNotificationReady, let messenger = currentBinaryMessenger() {
      let channel = FlutterMethodChannel(name: "tech.efactor/circle_connect", binaryMessenger: messenger)
      channel.invokeMethod("openNotificationPayload", arguments: payload)
    } else {
      // Dart not ready yet (cold start): buffer for getPendingNotificationTap.
      pendingNotificationTapData = payload
    }
  }

  /// Flattens the APNs userInfo into a JSON-safe [String: Any] for the channel:
  /// preserves gcm.message_id as _fcm_message_id, drops the aps envelope, and
  /// lifts a nested `data` object to the top level.
  private func flattenUserInfo(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (rawKey, value) in userInfo {
      guard let key = rawKey as? String else { continue }
      if key == "gcm.message_id" || key == "google.message_id" {
        out["_fcm_message_id"] = value
        continue
      }
      if key == "aps" { continue }
      if let nested = value as? [String: Any] {
        for (nk, nv) in nested { out[nk] = jsonSafeValue(nv) }
      } else {
        out[key] = jsonSafeValue(value)
      }
    }
    return out
  }

  private func jsonSafeValue(_ value: Any) -> Any {
    if value is String || value is NSNumber || value is Bool { return value }
    return String(describing: value)
  }

  private func currentBinaryMessenger() -> FlutterBinaryMessenger? {
    let controller = (topViewController() as? FlutterViewController)
      ?? (window?.rootViewController as? FlutterViewController)
      ?? (activeWindow()?.rootViewController as? FlutterViewController)
    return controller?.binaryMessenger
  }
}

extension AppDelegate: UIDocumentInteractionControllerDelegate {
  public func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    return topViewController() ?? window?.rootViewController ?? UIViewController()
  }

  public func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    documentInteractionController = nil
  }
}

extension AppDelegate: UIDocumentPickerDelegate {
  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    NSLog("[AppDelegate] User saved document(s) to: \(urls)")
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    NSLog("[AppDelegate] User cancelled document export picker (file remains in app Documents)")
  }
}
