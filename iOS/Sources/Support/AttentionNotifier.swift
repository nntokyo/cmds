import Foundation
import UserNotifications

/// Posts local notifications for `notification` messages and shows them while the app is in the foreground.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()

    private var authorizationRequested = false

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, macName: String, workspaceID: String, paneID: String?) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? macName : title
        content.subtitle = title.isEmpty ? "" : macName
        content.body = body
        content.sound = .default
        content.threadIdentifier = workspaceID
        content.userInfo = ["workspaceID": workspaceID, "paneID": paneID ?? ""]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
