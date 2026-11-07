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
      guard let self = self, let rootVC = self.window?.rootViewController else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No root view controller", details: nil))
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
        let rect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
        let menuPresented = self.documentInteractionController?.presentOpenInMenu(from: rect, in: rootVC.view, animated: true) ?? false
        result(["success": menuPresented, "type": menuPresented ? "menu" : "failed"])
      }
    }
  }

  private func saveAssetToAlbum(albumName: String, isVideo: Bool, fileUrl: URL?, image: UIImage?, completion: @escaping (Bool, Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization { status in
      guard status == .authorized || status == .limited else {
        completion(false, NSError(domain: "CircleConnect", code: 403, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
        return
      }

      // Find or create named album
      var albumPlaceholder: PHObjectPlaceholder?
      let fetchOptions = PHFetchOptions()
      fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
      let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)

      var targetCollection: PHAssetCollection? = collection.firstObject

      func performSave(to album: PHAssetCollection?) {
        PHPhotoLibrary.shared().performChanges({
          var assetPlaceholder: PHObjectPlaceholder?
          if isVideo, let url = fileUrl {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            assetPlaceholder = request?.placeholderForCreatedAsset
          } else if let img = image {
            // creationRequestForAsset(from:) returns a non-optional
            // PHAssetChangeRequest on the current Photos SDK, so no optional
            // chaining here (unlike the video variant above).
            let request = PHAssetChangeRequest.creationRequestForAsset(from: img)
            assetPlaceholder = request.placeholderForCreatedAsset
          }

          if let album = album, let asset = assetPlaceholder {
            let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
            albumChangeRequest?.addAssets([asset] as NSArray)
          }
        }) { success, error in
          completion(success, error)
        }
      }

      if let target = targetCollection {
        performSave(to: target)
      } else {
        // Create album first
        PHPhotoLibrary.shared().performChanges({
          let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
          albumPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
        }) { success, error in
          if success, let placeholder = albumPlaceholder {
            let collectionFetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
            performSave(to: collectionFetch.firstObject)
          } else {
            // Fallback to saving to camera roll without album
            performSave(to: nil)
          }
        }
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
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "tech.efactor/circle_connect", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("openSettingsUrl", arguments: ["url": "https://efactor.tech/index.php/grid-chat/settings"])
    }
  }
}

extension AppDelegate: UIDocumentInteractionControllerDelegate {
  public func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    return window?.rootViewController ?? UIViewController()
  }

  public func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    documentInteractionController = nil
  }
}
