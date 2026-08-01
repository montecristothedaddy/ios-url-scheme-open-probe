/*
 * Sender. On launch it makes exactly one UIApplication.open() call against a custom
 * URL scheme owned by a different application, then does nothing else.
 *
 * It declares no entitlements, no app group, and deliberately no
 * LSApplicationQueriesSchemes entry, so canOpenURL is reported only for the record.
 *
 * Like the receiver, it records to a file in its own container so the harness can tell
 * "the sender never ran" apart from "the sender ran and the open was blocked".
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
    controller.view.backgroundColor = .darkGray
    window?.rootViewController = controller
    window?.makeKeyAndVisible()

    let raw = ProcessInfo.processInfo.environment["PROBE_TARGET_URL"] ?? "probeb://ping"
    record("PROBE_A_LAUNCHED target=\(raw)")

    guard let url = URL(string: raw) else {
      record("PROBE_A_INVALID_URL")
      return true
    }
    record("PROBE_A_CANOPENURL=\(application.canOpenURL(url))")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      application.open(url, options: [:]) { accepted in
        record("PROBE_A_OPEN_ACCEPTED=\(accepted)")
      }
    }
    return true
  }
}
