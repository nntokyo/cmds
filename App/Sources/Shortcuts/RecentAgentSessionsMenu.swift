import AppKit
import CmdsCore

/// File › Recent Agent Sessions and the sidebar's clock button: the newest sessions of `AppController.agentHistory`,
/// rebuilt each time the menu opens. A session some pane holds is checked and shows that pane; any other is resumed
/// in a new workspace (`openRecentAgentSession`).
@MainActor
final class RecentAgentSessionsMenu: NSObject, NSMenuDelegate {
    let controller: AppController
    /// Brings the main window forward before a workspace is shown or created.
    var showWindow: (() -> Void)?

    init(controller: AppController) {
        self.controller = controller
    }

    /// A new menu filled by this object when it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Recent Agent Sessions"))
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = controller.agentHistory.recent()
        if sessions.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No Recent Agent Sessions"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let now = Date()
        for session in sessions {
            let item = NSMenuItem(title: Self.title(session, now: now), action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session
            var tip = [session.host.map { String(localized: "On \($0)") }, session.cwd].compactMap { $0 }
            if controller.paneHolding(session) != nil {
                // Never resumed twice: choosing it shows the pane that has it.
                item.state = .on
                tip.append(String(localized: "Open in a pane: choose to show it."))
            } else {
                tip.append(String(localized: "Choose to resume it in a new workspace."))
            }
            item.toolTip = tip.joined(separator: "\n")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: String(localized: "Clear Menu"), action: #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !controller.agentHistory.sessions.isEmpty
        menu.addItem(clear)
    }

    /// `Claude Code session “Fix login” (Opus, 3 hours ago) — app` (`— host:app` for an SSH session).
    static func title(_ session: AgentSession, now: Date) -> String {
        let summary = AppController.localizedSummary(session, now: now)
        let folder = session.cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        let place = [session.host, folder].compactMap { $0 }.joined(separator: ":")
        return place.isEmpty ? summary : "\(summary) — \(place)"
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? AgentSession else { return }
        showWindow?()
        guard let problem = controller.openRecentAgentSession(session) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not resume the agent session")
        alert.informativeText = problem
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = controller.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func clear(_ sender: NSMenuItem) {
        controller.clearAgentHistory()
    }
}
