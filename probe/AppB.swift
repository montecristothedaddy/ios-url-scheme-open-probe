/*
 * Receiver. Declares the custom URL scheme "probeb" and records a marker every time it is
 * launched or handed a URL.
 *
 * The marker is written to a file in the app's own Documents directory rather than to the
 * system log. A file survives process exit and is read back out of the app container by the
 * harness, so the measurement does not depend on a log stream being attached at the right
 * moment or on a predicate matching.
 */

import UIKit

func record(_ line: String) {
  let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  let file = dir.appendingPathComponent("probe-marker.txt")
  let entry = line + "\n"
  if let handle = try? FileHandle(forWritingTo: file) {
    handle.seekToEndOfFile()
    handle.write(Data(entry.utf8))
    try? handle.close()
  } else {
    try? entry.write(to: file, atomically: true, encoding: .utf8)
  }
  NSLog("%@", line)
}

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

    record("PROBE_B_LAUNCHED")
    if let url = launchOptions?[.url] as? URL {
      record("PROBE_B_RECEIVED_URL_AT_LAUNCH \(url.absoluteString)")
    }
    return true
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    record("PROBE_B_RECEIVED_URL \(url.absoluteString)")
    return true
  }
}
