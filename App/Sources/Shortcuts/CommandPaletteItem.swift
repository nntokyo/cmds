import AppKit
import CmdsCore

/// One thing the command palette (⇧⌘P) can find and run.
@MainActor
struct CommandPaletteItem {
    enum Kind: String {
        case workspace, pane, command, session, port

        var label: String {
            switch self {
            case .workspace: String(localized: "Workspace")
            case .pane: String(localized: "Pane")
            case .command: String(localized: "Command")
            case .session: String(localized: "Agent Session")
            case .port: String(localized: "Port")
            }
        }

        var symbol: String {
            switch self {
            case .workspace: "rectangle.stack"
            case .pane: "rectangle.split.2x1"
            case .command: "command"
            case .session: "clock.arrow.circlepath"
            case .port: "network"
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String
    /// Key equivalent of a menu command (`⇧⌘D`), else "".
    var shortcut = ""
    let run: () -> Void
    /// Matched against the title and the detail, and against `alternates` (their English names in a localized UI).
    let candidate: FuzzyMatch.Candidate

    init(kind: Kind, title: String, detail: String, shortcut: String = "", alternates: [String] = [],
         run: @escaping () -> Void) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.run = run
        candidate = FuzzyMatch.Candidate(detail.isEmpty ? title : "\(title) \(detail)", alternates: alternates)
    }

    /// The English names of the app's localized strings, in the language the UI runs in (none in English), so
    /// "split" also finds 右に分割 (#186).
    static let sourceTitles: SourceTitles = {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings"),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return SourceTitles(table: [:]) }
        return SourceTitles(table: table)
    }()

    /// Between a menu command's menus (`View › Split`).
    private static let menuPathSeparator = " › "

    /// Workspaces and their panes (sidebar order), recent agent sessions, listening ports, then the enabled menu
    /// commands. Call while `window` has the keyboard: menu items are validated against its first responder.
    static func collect(controller: AppController, window: NSWindow) -> [CommandPaletteItem] {
        var items = workspaces(controller) + panes(controller) + sessions(controller) + ports(controller)
        if let menu = NSApp.mainMenu { items += commands(in: menu, path: []) }
        return items
    }

    private static func workspaces(_ controller: AppController) -> [CommandPaletteItem] {
        controller.workspaces.map { workspace in
            let id = workspace.id
            let place = [workspace.workingDirectory?.abbreviatingHome, workspace.gitBranch].compactMap { $0 }
            return CommandPaletteItem(kind: .workspace, title: workspace.displayTitle,
                                      detail: place.joined(separator: " · ")) { [weak controller] in
                try? controller?.selectWorkspace(id: id)
            }
        }
    }

    /// Where Move to Workspace… can put `paneID` (#218): every other workspace in sidebar order, then a new workspace.
    static func moveDestinations(for paneID: String, controller: AppController) -> [CommandPaletteItem] {
        guard let pane = controller.pane(id: paneID), let own = controller.workspace(id: pane.workspaceID) else { return [] }
        var items = controller.workspaces.filter { $0 !== own }.map { workspace in
            let id = workspace.id
            let place = [workspace.workingDirectory?.abbreviatingHome, workspace.gitBranch].compactMap { $0 }
            return CommandPaletteItem(kind: .workspace, title: workspace.displayTitle,
                                      detail: place.joined(separator: " · ")) { [weak controller] in
                do { try controller?.movePane(paneID: paneID, toWorkspace: id) } catch { NSSound.beep() }
            }
        }
        if own.panes.count > 1 {
            items.append(CommandPaletteItem(kind: .command, title: String(localized: "New Workspace"), detail: "",
                                            alternates: ["New Workspace"]) { [weak controller] in
                _ = try? controller?.movePaneToNewWorkspace(paneID: paneID)
            })
        }
        return items
    }

    private static func panes(_ controller: AppController) -> [CommandPaletteItem] {
        controller.workspaces.flatMap { workspace in
            workspace.orderedPanes.map { pane in
                let paneID = pane.id
                let title = pane.agentTopic ?? DefaultTitle.localized(pane.title)
                // The model keeps default titles in English (DefaultTitle). Same as the shown text in English.
                let english = "\(pane.agentTopic ?? pane.title) \(workspace.displayTitle) · "
                    + sourceTitles.englishOrSame(pane.kind.label)
                return CommandPaletteItem(kind: .pane, title: title,
                                          detail: "\(workspace.displayTitle) · \(pane.kind.label)",
                                          alternates: [english]) { [weak controller] in
                    try? controller?.focusPane(id: paneID)
                }
            }
        }
    }

    private static func sessions(_ controller: AppController) -> [CommandPaletteItem] {
        let now = Date()
        return controller.agentHistory.recent().map { session in
            CommandPaletteItem(kind: .session, title: RecentAgentSessionsMenu.title(session, now: now),
                               detail: session.cwd?.abbreviatingHome ?? "") { [weak controller] in
                guard let controller else { return }
                RecentAgentSessionsMenu.open(session, controller: controller)
            }
        }
    }

    private static func ports(_ controller: AppController) -> [CommandPaletteItem] {
        controller.workspaces.flatMap { workspace in
            let id = workspace.id
            return workspace.ports.map { port in
                CommandPaletteItem(kind: .port, title: "localhost:\(port)",
                                   detail: String(localized: "Open in a browser split — \(workspace.displayTitle)")) { [weak controller] in
                    controller?.openPort(port, workspaceID: id)
                }
            }
        }
    }

    /// Menu commands that would be enabled now. Skips submenus filled when they open (Recent Agent Sessions: the
    /// palette lists those sessions itself), Services, the Workspace 1–9 items (the workspaces are listed) and the
    /// palette itself.
    private static func commands(in menu: NSMenu, path: [String]) -> [CommandPaletteItem] {
        menu.update()
        var items: [CommandPaletteItem] = []
        let englishPath = path.map(sourceTitles.englishOrSame).joined(separator: menuPathSeparator)
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                guard submenu.delegate == nil, submenu !== NSApp.servicesMenu else { continue }
                items += commands(in: submenu, path: path + [item.title])
                continue
            }
            guard let action = item.action, item.isEnabled,
                  action != #selector(CommandRouter.showCommandPalette(_:)),
                  action != #selector(CommandRouter.selectWorkspace(_:)) else { continue }
            let target = item.target
            let alternates = sourceTitles.english(for: item.title).map { "\($0) \(englishPath)" }
            items.append(CommandPaletteItem(kind: .command, title: item.title, detail: path.joined(separator: menuPathSeparator),
                                            shortcut: shortcut(of: item), alternates: alternates) { [weak item] in
                guard let item else { return }
                NSApp.sendAction(action, to: target, from: item)
            })
        }
        return items
    }

    /// `⌥⌘N`, `⇧⌘↩` as the menu shows them.
    static func shortcut(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        if key.count == 1, let character = key.first, character.isUppercase { modifiers.insert(.shift) }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names: [Int: String] = [NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→", NSUpArrowFunctionKey: "↑",
                                    NSDownArrowFunctionKey: "↓"]
        if let scalar = key.unicodeScalars.first, let name = names[Int(scalar.value)] {
            text += name
        } else {
            switch key {
            case "\r": text += "↩"
            case "\t": text += "⇥"
            case "\u{8}", "\u{7f}": text += "⌫"
            case " ": text += String(localized: "Space")
            default: text += key.uppercased()
            }
        }
        return text
    }
}

extension PaneKind {
    /// The pane kind for the UI.
    var label: String {
        switch self {
        case .terminal: String(localized: "Terminal")
        case .browser: String(localized: "Browser")
        case .preview: String(localized: "Preview")
        case .files: String(localized: "Files")
        }
    }
}
