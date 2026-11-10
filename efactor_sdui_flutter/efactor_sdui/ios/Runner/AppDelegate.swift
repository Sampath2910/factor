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
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
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
      case "startOngoingCallService":
        self.startOngoingCallAudioSession()
        result(true)
      case "stopOngoingCallService":
        self.stopOngoingCallAudioSession()
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
