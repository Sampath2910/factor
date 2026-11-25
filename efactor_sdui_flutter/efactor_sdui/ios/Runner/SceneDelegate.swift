import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Cold-start notification taps under UIScene arrive via
    // connectionOptions.notificationResponse, NOT the launch options remote key
    // that FLTFirebaseMessagingPlugin checks. Capture before super so the tap
    // is never lost on a terminated-app launch.
    if let response = connectionOptions.notificationResponse,
       let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.handleLaunchNotificationResponse(response)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
       let flutterVC = window?.rootViewController as? FlutterViewController {
      appDelegate.ensureBridgeRegistered(with: flutterVC.binaryMessenger)
    }
  }
}
