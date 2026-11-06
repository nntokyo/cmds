import AppKit
import Combine
import CmdsCore

/// The menu bar item (#95), drawn rather than written: the cmds glyph with an orange badge (workspaces that need the
/// user, orange in the sidebar) and an accent badge (workspaces working), each with its count. Its menu lists those
/// workspaces, under the sidebar's CPU, memory and agent limit meters; choosing one brings cmds forward on it.
/// Settings › Agents › Show in menu bar.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let showWorkspace: (String?) -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var usageSubscription: AnyCancellable?
    /// CPU, memory and the agents' account limits, as in the sidebar footer; at the top of the menu.
    private let usageView = SystemUsageView()
    private lazy var usageItem = makeUsageItem()
    private var menuIsOpen = false
    private var appliedCounts: Counts?

    private struct Counts: Equatable {
        var needingUser: Int
        var working: Int
    }

    /// `showWorkspace` brings the main window forward, on a workspace if one is given.
    init(controller: AppController, showWorkspace: @escaping (String?) -> Void) {
        self.controller = controller
        self.showWorkspace = showWorkspace
        super.init()
    }

    func start() {
        subscription = controller.changes.sink { [weak self] _ in self?.update() }
        usageSubscription = controller.usageChanges.sink { [weak self] in
            guard let self, self.menuIsOpen else { return }
            self.updateUsage()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        settingsChanged()
    }

    @objc private func settingsChanged() {
        if AppSettings.shared.showInMenuBar {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            appliedCounts = nil
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
        let counts = Counts(needingUser: summary.needingUser.count, working: summary.working.count)
        guard counts != appliedCounts else { return }
        appliedCounts = counts
        button.image = Self.image(counts)
        let description = Self.description(counts)
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    // MARK: Icon

    private static let height: CGFloat = 18
    private static let glyphWidth: CGFloat = 18
    private static let badgeSize: CGFloat = 14
    private static let spacing: CGFloat = 2

    /// The glyph, then a badge per non-zero count. Drawn when shown, so the glyph follows the menu bar's light or dark
    /// look; only the badges are coloured.
    private static func image(_ counts: Counts) -> NSImage {
        let badges = [(counts.needingUser, NSColor.systemOrange), (counts.working, NSColor.controlAccentColor)]
            .filter { $0.0 > 0 }
        let width = glyphWidth + CGFloat(badges.count) * (spacing + badgeSize)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let glyph = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.labelColor]))) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (glyphWidth - size.width) / 2, y: (height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            var x = glyphWidth + spacing
            for (count, color) in badges {
                drawBadge(count, color: color, in: NSRect(x: x, y: (height - badgeSize) / 2, width: badgeSize, height: badgeSize))
                x += badgeSize + spacing
            }
            return true
        }
    }

    private static func drawBadge(_ count: Int, color: NSColor, in rect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = count > 9 ? "9+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 8 : 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// Tooltip and VoiceOver label.
    private static func description(_ counts: Counts) -> String {
        guard counts.needingUser > 0 || counts.working > 0 else { return "cmds" }
        return "cmds — " + String(localized: "\(counts.needingUser) need you, \(counts.working) working",
                                  comment: "menu bar item: workspaces waiting for the user, and with an agent working")
    }

    // MARK: Menu

    /// Width of the usage meters in the menu.
    private static let usageWidth: CGFloat = 260
    private static let usageInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)

    private func makeUsageItem() -> NSMenuItem {
        let container = NSView()
        usageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(usageView)
        let insets = Self.usageInsets
        NSLayoutConstraint.activate([
            usageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            usageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            usageView.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            usageView.widthAnchor.constraint(equalToConstant: Self.usageWidth),
        ])
        let item = NSMenuItem()
        item.view = container
        return item
    }

    /// New values for the meters; the menu item takes the height they need (agent rows come and go).
    private func updateUsage() {
        usageView.update(sample: controller.systemSample)
        usageView.update(agentLimits: controller.activeAgentLimits())
        usageView.update(keepAwake: KeepAwakeManager.shared.status)
        usageView.update(nextSchedule: ScheduleText.nextRunHint(controller.scheduleRunner.schedules))
        guard let container = usageItem.view else { return }
        usageView.layoutSubtreeIfNeeded()
        let insets = Self.usageInsets
        let height = usageView.fittingSize.height + insets.top + insets.bottom
        container.setFrameSize(NSSize(width: Self.usageWidth + insets.left + insets.right, height: height))
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateUsage()
        menu.addItem(usageItem)
        menu.addItem(.separator())
        let summary = summary
        if !summary.needingUser.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Needs You", comment: "menu bar item: workspaces waiting for the user")))
            for entry in summary.needingUser {
                menu.addItem(workspaceItem(entry, symbol: "exclamationmark.circle.fill", color: .systemOrange))
            }
        }
        if !summary.working.isEmpty {
            if !summary.needingUser.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Working", comment: "sidebar agent state: the agent is busy")))
            for entry in summary.working {
                menu.addItem(workspaceItem(entry, symbol: "ellipsis.circle.fill", color: .controlAccentColor))
            }
        }
        if summary.isQuiet {
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

    private func workspaceItem(_ entry: MenuBarSummary.Entry, symbol: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(openWorkspace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.id
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.white, color])))
        return item
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showWorkspace(id)
    }

    @objc private func openApp() { showWorkspace(nil) }
}
