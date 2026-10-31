import AppKit
import CmdsCore
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
        SyncServer.shared.startIfEnabled()
        SyncBluetoothPeripheral.shared.activate()
        SyncRemoteAccess.shared.activate()
        KeepAwakeManager.shared.start()
        Updater.shared.start()
        // An isolated test instance (CMDS_SUPPORT_DIR) must not take keyboard focus from the app in use.
        if CmdsEnv.supportDirectoryOverride() == nil { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        metadataMonitor?.stop()
        apiServer?.stop()
        SyncRemoteAccess.shared.shutdown()
        SyncServer.shared.stop()
        controller.saveSession()
        // Last: may show macOS's administrator dialog to restore lid-close sleep.
        KeepAwakeManager.shared.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.windowDidBecomeKey()
    }

    /// Closing the window must not end the terminals (and the agents in them): cmds keeps running; the Dock icon
    /// or ⌘N brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by `app.quit` (scripted updates that move sessions with export/import) to skip the confirmation.
    static var quitWithoutConfirmation = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let agents = controller.workspaces.reduce(0) { $0 + $1.agentPanes.count }
        guard agents > 0, !Self.quitWithoutConfirmation else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit cmds?")
        alert.informativeText = String(localized: "\(agents) AI agent sessions are running in cmds. Quitting ends them; you can resume them later from the saved sessions.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

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
