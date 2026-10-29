import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController.shared
    private(set) var windowController: MainWindowController!
    private var router: CommandRouter!
    private var metadataMonitor: MetadataMonitor!
    private var apiServer: APIServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MainWindowController(controller: controller)
        router = CommandRouter(controller: controller, windowController: windowController)
        NSApp.mainMenu = MainMenu.build(router: router)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        windowController.showWindow(nil)
        if let session = SessionStore.load(), !session.workspaces.isEmpty {
            controller.restore(session)
        } else {
            controller.createWorkspace()
        }
        metadataMonitor = MetadataMonitor(controller: controller)
        metadataMonitor.start()
        apiServer = APIServer(controller: controller)
        apiServer?.start()
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        metadataMonitor?.stop()
        apiServer?.stop()
        controller.saveSession()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.windowDidBecomeKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.showWindow(nil) }
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paneID = response.notification.request.content.userInfo["paneID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                self.windowController.showWindow(nil)
                if let paneID { try? self.controller.focusPane(id: paneID) }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The ring and sidebar already show it while the app is frontmost.
        completionHandler([])
    }
}
