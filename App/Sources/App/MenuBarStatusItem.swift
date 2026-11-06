import AppKit
import Combine
import CmdsCore

/// The menu bar item (#95): the workspace that needs the user (orange in the sidebar), else how many work. Its menu
/// lists those workspaces; choosing one brings cmds forward on it. Settings › Agents › Show in menu bar.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let showWorkspace: (String?) -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var appliedTitle: String?

    /// `showWorkspace` brings the main window forward, on a workspace if one is given.
    init(controller: AppController, showWorkspace: @escaping (String?) -> Void) {
        self.controller = controller
        self.showWorkspace = showWorkspace
        super.init()
    }

    func start() {
        subscription = controller.changes.sink { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        settingsChanged()
    }

    @objc private func settingsChanged() {
        if AppSettings.shared.showInMenuBar {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "cmds")
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            appliedTitle = nil
            update()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private var summary: MenuBarSummary {
        MenuBarSummary(controller.workspaces.map { workspace in
            MenuBarSummary.Entry(id: workspace.id, title: workspace.displayTitle,
                                 needsUser: AgentActivityStyle.needsUser(workspace),
                                 working: AgentActivityStyle.isWorking(workspace))
        })
    }

    private func update() {
        guard let button = item?.button else { return }
        let summary = summary
        let title = summary.title
        guard title != appliedTitle else { return }
        appliedTitle = title
        button.attributedTitle = Self.attributedTitle(title, needsUser: !summary.needingUser.isEmpty)
        button.toolTip = title.isEmpty ? "cmds" : "cmds — \(title)"
    }

    /// The leading dot in the sidebar's colours: orange when a workspace needs the user, the accent while working.
    private static func attributedTitle(_ title: String, needsUser: Bool) -> NSAttributedString {
        guard !title.isEmpty else { return NSAttributedString() }
        let font = NSFont.menuBarFont(ofSize: 0)
        let text = NSMutableAttributedString(string: " " + title, attributes: [.font: font])
        let dot = NSRange(location: 1, length: 1)
        text.addAttribute(.foregroundColor, value: needsUser ? NSColor.systemOrange : NSColor.controlAccentColor, range: dot)
        return text
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = summary
        if !summary.needingUser.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Needs You", comment: "menu bar item: workspaces waiting for the user")))
            for entry in summary.needingUser { menu.addItem(workspaceItem(entry, color: .systemOrange)) }
        }
        if !summary.working.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Working", comment: "sidebar agent state: the agent is busy")))
            for entry in summary.working { menu.addItem(workspaceItem(entry, color: .controlAccentColor)) }
        }
        if menu.numberOfItems == 0 {
            let none = NSMenuItem(title: String(localized: "No agents working", comment: "menu bar item: nothing waits or works"),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open cmds", comment: "menu bar item"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    private func workspaceItem(_ entry: MenuBarSummary.Entry, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(openWorkspace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.id
        item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
        return item
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showWorkspace(id)
    }

    @objc private func openApp() { showWorkspace(nil) }
}
