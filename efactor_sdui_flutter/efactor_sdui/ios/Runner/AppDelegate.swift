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
      isBridgeRegistered = true
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if !isBridgeRegistered {
      wifiNativeBridge.register(with: engineBridge.applicationRegistrar.messenger())
      isBridgeRegistered = true
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
