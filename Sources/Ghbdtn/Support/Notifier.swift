import Foundation
import UserNotifications
import AppKit

/// Thin wrapper over UserNotifications with a graceful fallback: if the app is
/// unsigned / not a real bundle (e.g. run straight from `swift run`), the
/// UNUserNotificationCenter is unavailable, so we drop to a transient status
/// message posted via NSLog instead of crashing.
enum Notifier {
    /// nil = not yet resolved, true/false = user's authorization decision.
    private static var authorized: Bool?
    private static var available: Bool = {
        // UNUserNotificationCenter.current() traps if there is no bundle id.
        Bundle.main.bundleIdentifier != nil
    }()

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            authorized = granted
            if let error { Log.error("Notification auth error: \(error)") }
        }
    }

    static func show(title: String, body: String) {
        guard available else {
            Log.info("[notify] \(title): \(body)")
            return
        }
        // Don't bother the system once the user has explicitly denied us.
        if authorized == false {
            Log.debug("[notify suppressed — denied] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("Notification add failed: \(error)") }
        }
    }
}
