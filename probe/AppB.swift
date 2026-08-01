/*
 * Receiver. Declares the custom URL scheme "probeb" and logs a distinctive marker
 * both when it launches and when it is handed a URL.
 *
 * The marker is the whole measurement. Nothing in this experiment taps anything, so
 * if the platform interposes a confirmation, no marker is ever logged.
 */

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemGreen
    window?.rootViewController = controller
    window?.makeKeyAndVisible()

    NSLog("PROBE_B_LAUNCHED")
    if let url = launchOptions?[.url] as? URL {
      NSLog("PROBE_B_RECEIVED_URL_AT_LAUNCH %@", url.absoluteString)
    }
    return true
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    NSLog("PROBE_B_RECEIVED_URL %@", url.absoluteString)
    return true
  }
}
