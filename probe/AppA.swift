/*
 * Sender. On launch it makes exactly one UIApplication.open() call against a custom
 * URL scheme owned by a different application, then does nothing else.
 *
 * It declares no entitlements, no app group, and deliberately no
 * LSApplicationQueriesSchemes entry, so canOpenURL is reported only for the record.
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
    controller.view.backgroundColor = .darkGray
    window?.rootViewController = controller
    window?.makeKeyAndVisible()

    let raw = ProcessInfo.processInfo.environment["PROBE_TARGET_URL"] ?? "probeb://ping"
    NSLog("PROBE_A launched target=%@", raw)

    guard let url = URL(string: raw) else {
      NSLog("PROBE_A invalid_url")
      return true
    }
    NSLog("PROBE_A canOpenURL=%@", application.canOpenURL(url) ? "true" : "false")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      application.open(url, options: [:]) { accepted in
        NSLog("PROBE_A open_accepted=%@", accepted ? "true" : "false")
      }
    }
    return true
  }
}
