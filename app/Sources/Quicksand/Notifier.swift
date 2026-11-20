import Foundation
import QuicksandCore
import UserNotifications

/// Posts a macOS notification when a sandbox (or anyone) talks to a broker.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Notification Center only works from a bundled app; `swift run`
    /// would crash in `.current()`, so notifications are off there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? .current() : nil

    /// The user turned notifications off for Quicksand in System Settings.
    private(set) var denied = false

    var isAvailable: Bool { center != nil }

    /// Ask once; macOS remembers the answer (System Settings → Notifications
    /// → Quicksand changes it).
    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.denied = !granted }
        }
    }

    func post(_ notice: BrokerNotice, id: UUID) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.thread
        // One identifier per connection: a failure replaces the "started"
        // banner for the same request instead of stacking under it.
        center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }

    // Show banners even though a status-bar app always counts as frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
