import AppKit
import UserNotifications

/// Posted when the user clicks one of DeskPulse's notifications.
let notificationClickedNotification = Notification.Name("DeskPulse.notificationClicked")

/// macOS notifications for incoming alerts and stock price alerts. They show in any
/// app and on any Space, unlike the dashboard and the HDMI banner.
@MainActor
enum Notifier {
    private static let delegate = Delegate()
    private static var isSetUp = false

    /// Notification Center requires a real app bundle; unit tests and `swift run` skip it.
    private static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Asks for permission once (macOS remembers the answer) and routes clicks.
    static func setUp() {
        guard isAvailable, !isSetUp else { return }
        isSetUp = true
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        requestAuthorization(center)
    }

    /// The completion runs on a background queue, so it is created outside the main
    /// actor (see `RedAlertMonitor.ping`).
    nonisolated private static func requestAuthorization(_ center: UNUserNotificationCenter) {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String, sound: Bool = true) {
        guard isAvailable else { return }
        setUp()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// Show banners even while DeskPulse is the active app.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound, .list]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: notificationClickedNotification, object: nil)
            }
        }
    }
}
