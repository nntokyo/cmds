import AppKit
import CmdsCore

/// The Claude account of a workspace's agent session in the sidebar: which one it runs under, and a menu to continue
/// it under another (the row's account button and its context menu). Choosing one asks as `cmds accounts switch`
/// does (`requestAccountSwitch`): Claude Code quits once it is idle and the session resumes under the other account.
@MainActor
enum ClaudeAccountMenu {
    /// The pane whose account the row shows: the workspace's primary agent when it is Claude Code in a local pane and
    /// accounts are set up (Settings › Claude Accounts); else nil (no button, no menu).
    static func pane(of workspace: Workspace, controller: AppController) -> Pane? {
        guard !controller.claudeAccounts.accounts.isEmpty, let primary = workspace.primaryAgent,
              primary.usage.agent == .claude, primary.pane.ssh == nil else { return nil }
        return primary.pane
    }

    /// The account to show for `pane` (its own, else the one using `~/.claude`), and whether a switch is under way.
    static func shown(_ pane: Pane, controller: AppController) -> (name: String?, switchingTo: String?) {
        let change = pane.accountSwitch
        return (controller.currentAccount(of: pane), change?.isInProgress == true ? change?.to : nil)
    }

    /// A colour per account, by its place in the list, so the same account looks the same in every row.
    static func color(of name: String?, controller: AppController) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo, .systemBrown]
        guard let name, let index = controller.claudeAccounts.accounts.firstIndex(where: { $0.hasName(name) }) else {
            return .secondaryLabelColor
        }
        return palette[index % palette.count]
    }

    /// The menu: every account (the current one checked, limited ones with when they reset), then Manage Accounts….
    static func menu(for pane: Pane, controller: AppController, in window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        let (current, switchingTo) = shown(pane, controller: controller)
        let header = NSMenuItem(title: String(localized: "Continue This Session With", comment: "sidebar account menu: header"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let now = Date()
        for account in controller.claudeAccounts.accounts {
            var title = account.name
            if let limit = account.limit, limit.isActive(at: now) {
                title += " — " + String(localized: "Limit — \(AppController.localizedReset(limit))")
            }
            if let switchingTo, account.hasName(switchingTo) {
                title += " — " + String(localized: "switching…", comment: "sidebar account menu: the switch is under way")
            }
            let item = Handler.item(title) {
                choose(account.name, pane: pane, controller: controller, window: window)
            }
            item.image = swatch(color(of: account.name, controller: controller))
            // The current one is checked and cannot be chosen.
            if current.map(account.hasName) == true {
                item.state = .on
                item.action = nil
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Handler.item(String(localized: "Manage Accounts…", comment: "sidebar account menu")) {
            ClaudeAccountsWindowController.shared.showWindow(nil)
        })
        return menu
    }

    /// The user chose `name`: tells why it cannot be done, else asks for the switch.
    static func choose(_ name: String, pane: Pane, controller: AppController, window: NSWindow?) {
        if let problem = controller.accountSwitchProblem(pane, to: name) {
            show(problem.localized, in: window)
            return
        }
        do {
            try controller.requestAccountSwitch(paneID: pane.id, to: name)
        } catch {
            show(error.localizedDescription, in: window)
        }
    }

    private static func show(_ text: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The account cannot be switched", comment: "sidebar account menu: alert title")
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Menu items that run a closure (the menu lives only while it is open).
    final class Handler: NSObject {
        private let run: () -> Void
        private init(_ run: @escaping () -> Void) { self.run = run }

        static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
            let handler = Handler(run)
            let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            return item
        }

        @objc private func fire() { run() }
    }
}
