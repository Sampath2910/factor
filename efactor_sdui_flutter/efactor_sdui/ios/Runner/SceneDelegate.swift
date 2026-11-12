import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
       let flutterVC = window?.rootViewController as? FlutterViewController {
      appDelegate.ensureBridgeRegistered(with: flutterVC.binaryMessenger)
    }
  }
}
