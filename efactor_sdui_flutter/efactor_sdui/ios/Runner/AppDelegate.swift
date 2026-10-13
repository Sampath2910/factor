import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let wifiNativeBridge = WifiNativeBridge()
  private var isBridgeRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
}
