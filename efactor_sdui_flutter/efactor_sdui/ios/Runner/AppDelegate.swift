import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let wifiNativeBridge = WifiNativeBridge()
  private var isBridgeRegistered = false

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
    channel.setMethodCallHandler { (call, result) in
      if call.method == "getCookies" {
        let urlStr = (call.arguments as? [String: Any])?["url"] as? String ?? "https://efactor.tech"
        if let url = URL(string: urlStr), let cookies = HTTPCookieStorage.shared.cookies(for: url) {
          let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
          result(cookieHeader)
        } else {
          result("")
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
