import AppKit
import CmdsCore

/// The Claude account of a workspace's agent session in the sidebar: which one it runs under, and a menu to continue
/// it under another (the row's account button and its context menu). Choosing one asks as `cmds accounts switch`
/// does (`requestAccountSwitch`): Claude Code quits once it is idle and the session resumes under the other account.
@MainActor
enum ClaudeAccountMenu {
    /// The pane whose account the row shows: the workspace's primary agent when it is Claude Code in a local pane and
    /// accounts are set up (Settings › Claude Accounts); else nil (no button).
    static func pane(of workspace: Workspace, controller: AppController) -> Pane? {
        guard !controller.claudeAccounts.accounts.isEmpty, let primary = workspace.primaryAgent,
              isSwitchable(primary.pane) else { return nil }
        return primary.pane
    }

    /// Claude Code in a local pane: what an account switch can move.
    private static func isSwitchable(_ pane: Pane) -> Bool {
        pane.agentUsage?.agent == .claude && pane.ssh == nil
    }

    /// Every pane the menu can switch (#296): the workspace's local Claude Code panes, the row's one first; empty
    /// without accounts (no menu).
    static func panes(of workspace: Workspace, controller: AppController) -> [Pane] {
        guard !controller.claudeAccounts.accounts.isEmpty else { return [] }
        let local = workspace.agentPanes.filter(isSwitchable)
        guard let shown = pane(of: workspace, controller: controller) else { return local }
        return [shown] + local.filter { $0 !== shown }
    }

    /// The account to show for `pane` (its own, else the one using `~/.claude`), and whether a switch is under way.
    static func shown(_ pane: Pane, controller: AppController) -> (name: String?, switchingTo: String?) {
        let change = pane.accountSwitch
        return (controller.currentAccount(of: pane), change?.isInProgress == true ? change?.to : nil)
    }

    /// What the account button shows for `pane`: in the full row its title and icon, in the compact one the icon
    /// with the rest in its tooltip (#296).
    struct Badge: Equatable {
        /// The account, `→ name` while a switch waits, else "Unknown account".
        var title: String
        var color: NSColor
        var toolTip: String
        var accessibilityLabel: String
        /// A switch waits (the title is `→ name`).
        var switching: Bool
    }

    static func badge(for pane: Pane, controller: AppController) -> Badge {
        let (name, switchingTo) = shown(pane, controller: controller)
        let title = switchingTo.map { String(localized: "→ \($0)", comment: "sidebar: the account a switch goes to") }
            ?? name ?? String(localized: "Unknown account", comment: "sidebar: the session's Claude account is not known")
        return Badge(title: title, color: color(of: switchingTo ?? name, controller: controller),
                     toolTip: String(localized: "Claude account: \(name ?? "?"). Click to continue this session with another account.",
                                     comment: "sidebar: account button tooltip"),
                     accessibilityLabel: String(localized: "Claude account \(name ?? "?")", comment: "sidebar: account button"),
                     switching: switchingTo != nil)
    }

    /// The account icon: a person in the account's colour.
    static func image(_ color: NSColor, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular).applying(.init(paletteColors: [.white, color])))
    }

    /// A colour per account, by its place in the list, so the same account looks the same in every row.
    static func color(of name: String?, controller: AppController) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo, .systemBrown]
        guard let name, let index = controller.claudeAccounts.accounts.firstIndex(where: { $0.hasName(name) }) else {
            return .secondaryLabelColor
        }
        return palette[index % palette.count]
    }

    /// The workspace's menu, nil without a pane to switch: every account (the current one checked, limited ones with
    /// when they reset), Cancel Switch while a switch waits, then Manage Accounts…. With several Claude panes, a
    /// section per pane headed by the pane and its account (#296).
    static func menu(for workspace: Workspace, controller: AppController, in window: NSWindow?) -> NSMenu? {
        let panes = panes(of: workspace, controller: controller)
        guard !panes.isEmpty else { return nil }
        let menu = NSMenu()
        // Read once per menu: the list looks at each account's folder (sign-in, settings).
        let list = controller.accountList()
        for pane in panes {
            if pane !== panes[0] { menu.addItem(.separator()) }
            let title = panes.count == 1
                ? String(localized: "Continue This Session With", comment: "sidebar account menu: header")
                : sectionTitle(pane, controller: controller)
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in items(for: pane, list: list, controller: controller, in: window) {
                if panes.count > 1 { item.indentationLevel = 1 }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        for item in accountItems(list, controller: controller) { menu.addItem(item) }
        menu.addItem(Handler.item(String(localized: "Manage Accounts…", comment: "sidebar account menu")) {
            ClaudeAccountsWindowController.shared.showWindow(nil)
        })
        return menu
    }

    /// What `cmds accounts auto|login|clear|share` do, without the command line: switching by itself at the limit
    /// (checked when on), Sign In per account, Clear Limit per limited account, and Share Sessions… while some
    /// account's sessions are not shared.
    private static func accountItems(_ list: ClaudeAccountList, controller: AppController) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let auto = Handler.item(String(localized: "Switch Automatically at the Limit", comment: "sidebar account menu")) {
            controller.setAccountAutoSwitch(!list.autoSwitch)
        }
        auto.state = list.autoSwitch ? .on : .off
        items.append(auto)

        let signIn = NSMenuItem(title: String(localized: "Sign In", comment: "sidebar account menu: submenu of accounts"),
                                action: nil, keyEquivalent: "")
        signIn.submenu = NSMenu()
        for account in list.accounts {
            let item = Handler.item(account.name + (note(account).map { " — " + $0 } ?? "")) {
                do {
                    try controller.signInToAccount(name: account.name)
                } catch {
                    show(text(of: error), title: String(localized: "Claude Accounts"), in: controller.window)
                }
            }
            item.image = swatch(color(of: account.name, controller: controller))
            signIn.submenu?.addItem(item)
        }
        items.append(signIn)

        let unset = list.accounts.filter { $0.needsSetup == true }
        if !unset.isEmpty {
            let setUp = NSMenuItem(title: String(localized: "Set Up for cmds", comment: "account menu: add cmds's status line and hooks to an account"),
                                   action: nil, keyEquivalent: "")
            setUp.submenu = NSMenu()
            for account in unset {
                let item = Handler.item(account.name) { confirmSetUp(account.name, controller: controller, in: controller.window) }
                item.image = swatch(color(of: account.name, controller: controller))
                setUp.submenu?.addItem(item)
            }
            items.append(setUp)
        }

        let limited = list.accounts.filter { $0.limit != nil }
        if !limited.isEmpty {
            let clear = NSMenuItem(title: String(localized: "Clear Limit"), action: nil, keyEquivalent: "")
            clear.submenu = NSMenu()
            for account in limited {
                let item = Handler.item(account.name) {
                    try? controller.clearAccountLimit(name: account.name)
                    refreshRows(controller)
                }
                item.image = swatch(color(of: account.name, controller: controller))
                clear.submenu?.addItem(item)
            }
            items.append(clear)
        }
        if list.accounts.count > 1, list.accounts.contains(where: { $0.sessions == .missing || $0.sessions == .separate }) {
            items.append(Handler.item(String(localized: "Share Sessions…")) {
                ClaudeAccountsWindowController.shared.showAndShareSessions()
            })
        }
        return items
    }

    /// Why an account cannot take a session as it is: not signed in, not set up for cmds, the same sign-in as another
    /// account.
    static func note(_ account: ClaudeAccountStatus) -> String? {
        if !account.exists { return String(localized: "not signed in", comment: "account menu: the config folder does not exist") }
        var notes: [String] = []
        if account.needsSetup == true {
            notes.append(String(localized: "not set up", comment: "account menu: settings.json lacks cmds's status line or hooks"))
        }
        if let other = account.sameSignInAs {
            notes.append(String(localized: "same sign-in as \(other)", comment: "account menu: two accounts are one Claude account"))
        }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    /// Set Up: says what is added to the account's settings.json, then adds it and says what happened.
    static func confirmSetUp(_ name: String, controller: AppController, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Set up “\(name)” for cmds?")
        alert.informativeText = String(localized: """
            cmds adds its status line and hooks to this account’s settings.json when they are missing. They tell cmds \
            the session, its usage and its state: without them the account’s workspaces have no account button and \
            cannot be switched. Other settings stay, and the previous file is kept next to it. Sessions started \
            afterwards use it.
            """)
        alert.addButton(withTitle: String(localized: "Set Up for cmds", comment: "account menu: add cmds's status line and hooks to an account"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let run: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let result = try controller.setUpAccount(name: name)
                if result.statusLine == .own {
                    show(String(localized: "The hooks were added. This account has a status line of its own: add cmds hook claude-status to it (see the guide, “Usage and limits”)."),
                         title: String(localized: "Claude Accounts"), in: window)
                }
            } catch {
                show(text(of: error), title: String(localized: "Claude Accounts"), in: window)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// A pane's section header: its task (else "Pane id") and the account it runs under.
    private static func sectionTitle(_ pane: Pane, controller: AppController) -> String {
        let label: String
        if let topic = pane.agentTopic, !topic.isEmpty {
            label = (topic.count > 40 ? String(topic.prefix(39)) + "…" : topic) + " (\(pane.id))"
        } else {
            label = String(localized: "Pane \(pane.id)")
        }
        let account = controller.currentAccount(of: pane)
            ?? String(localized: "Unknown account", comment: "sidebar: the session's Claude account is not known")
        return String(localized: "\(label) — \(account)", comment: "sidebar account menu: a Claude pane and its account")
    }

    /// One pane's items: the accounts, and Cancel Switch while a switch waits for Claude Code (#296).
    private static func items(for pane: Pane, list: ClaudeAccountList, controller: AppController,
                              in window: NSWindow?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let (current, switchingTo) = shown(pane, controller: controller)
        let now = Date()
        let notes = Dictionary(uniqueKeysWithValues: list.accounts.map { ($0.name, note($0)) })
        for account in controller.claudeAccounts.accounts {
            var title = account.name
            if let note = notes[account.name] ?? nil, current.map(account.hasName) != true { title += " — " + note }
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
            items.append(item)
        }
        if switchingTo != nil {
            // As the pane banner's Cancel (`dismissAccountSwitch`): nothing more is sent to the pane.
            items.append(Handler.item(String(localized: "Cancel Switch", comment: "sidebar account menu: stop a switch that waits")) {
                cancel(pane, controller: controller)
            })
        }
        return items
    }

    /// The user chose `name`: tells why it cannot be done, else asks for the switch.
    static func choose(_ name: String, pane: Pane, controller: AppController, window: NSWindow?) {
        if let problem = request(name, pane: pane, controller: controller) { show(problem, in: window) }
    }

    /// Asks for the switch to `name` (the rows show it at once); the alert's text when it cannot be done, else nil.
    static func request(_ name: String, pane: Pane, controller: AppController) -> String? {
        if let problem = controller.accountSwitchProblem(pane, to: name) { return problem.localized }
        do {
            try controller.requestAccountSwitch(paneID: pane.id, to: name)
        } catch {
            return error.localizedDescription
        }
        refreshRows(controller)
        return nil
    }

    /// Cancel Switch: drops the switch that waits, as the pane banner's Cancel does, and shows it in the rows.
    static func cancel(_ pane: Pane, controller: AppController) {
        controller.dismissAccountSwitch(pane)
        refreshRows(controller)
    }

    /// The rows show a switch asked for or cancelled at once, not at the next usage sample.
    private static func refreshRows(_ controller: AppController) {
        (controller.window?.windowController as? MainWindowController)?.sidebar.updateUsage()
    }

    /// What an alert says about a failed account action: the app's own message, else the system's.
    private static func text(of error: Error) -> String {
        (error as? RPCError)?.message ?? error.localizedDescription
    }

    private static func show(_ text: String, title: String? = nil, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title ?? String(localized: "The account cannot be switched", comment: "sidebar account menu: alert title")
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
