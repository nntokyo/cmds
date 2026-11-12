import AppKit
import CmdsCore

/// cmds › Settings… (⌘,): terminal font and size, sidebar text size, browser/preview zoom, subagent cards, Claude
/// accounts and schedules (their own windows), automatic updates. Every control applies immediately (`AppSettings`, `Updater`); there is no OK button.
/// The tabs of Settings.
enum SettingsTab: String {
    case general, sidebar, agents, menuBar, assistant, updates
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let settings = AppSettings.shared
    private let fontPopup = NSPopUpButton()
    private let customSizeCheckbox = NSButton(checkboxWithTitle: String(localized: "Custom size:"), target: nil, action: nil)
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let sizeUnit = NSTextField(labelWithString: String(localized: "pt", comment: "font size unit (points)"))
    private let sidebarControl = NSSegmentedControl()
    private let browserZoomPopup = NSPopUpButton()
    private let previewZoomPopup = NSPopUpButton()
    private let subagentsPopup = NSPopUpButton()
    private let menuBarCheckbox = NSButton(checkboxWithTitle: String(localized: "Show in menu bar"), target: nil, action: nil)
    private let inspectableCheckbox = NSButton(checkboxWithTitle: String(localized: "Allow Safari's Web Inspector"), target: nil, action: nil)
    private let memoryWarningCheckbox = NSButton(checkboxWithTitle: String(localized: "Warn when memory is short"), target: nil, action: nil)
    /// Settings › Sidebar: what the rows and the footer show (#107).
    private let sidebarItemCheckboxes = SettingsWindowController.checkboxes(for: SidebarItem.self)
    /// Settings › Menu Bar: one checkbox per part of the item (#105).
    private let menuBarOptionCheckboxes = SettingsWindowController.checkboxes(for: MenuBarOption.self)
    private let checkUpdatesCheckbox = NSButton(checkboxWithTitle: String(localized: "Check for updates automatically"), target: nil, action: nil)
    private let installUpdatesCheckbox = NSButton(checkboxWithTitle: String(localized: "Download and install updates automatically"), target: nil, action: nil)
    private let updatesNote = SettingsWindowController.note("")
    private let accountsButton = NSButton(title: String(localized: "Manage…"), target: nil, action: nil)
    private let schedulesButton = NSButton(title: String(localized: "Open…"), target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var assistantObserver: NSObjectProtocol?
    private var tabController: NSTabViewController?
    /// Settings › Assistant (#243), shown on macOS 26 and later.
    private let assistantPane = AssistantSettingsPane()
    /// The scrolled tabs' height limits, fitted to the screen when the window opens (#264).
    private var scrollHeightLimits: [(limit: NSLayoutConstraint, page: NSViewController, rowsHeight: CGFloat)] = []
    /// A scrolled tab is at most this tall (the content, without the title bar and toolbar), so Settings fits a 13"
    /// display with room to spare (#264).
    private static let scrollHeight: CGFloat = 540
    /// On a small screen: the title bar and toolbar taken as at least this tall, this much room left below the
    /// window, and never less than `minimumScrollHeight` of rows (#264).
    private static let minimumChrome: CGFloat = 80
    private static let screenMargin: CGFloat = 40
    private static let minimumScrollHeight: CGFloat = 200

    private static let zoomLevels: [Double] = PageZoomSteps.steps

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmds.settings")
        super.init(window: window)
        window.delegate = self
        buildContent()
        observer = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.refresh() }
        }
        // The assistant's problem row comes and goes while Settings is open (the microphone refused after turning
        // it on here).
        if #available(macOS 26.0, *) {
            assistantObserver = NotificationCenter.default.addObserver(forName: AssistantController.didChange, object: nil,
                                                                       queue: .main) { _ in
                MainActor.assumeIsolated { SettingsWindowController.shared.assistantPane.refreshProblem() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func showSettings(_ sender: Any?) {
        refresh()
        fitScrollHeight()
        if window?.isVisible != true { window?.center() }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Layout

    private func buildContent() {
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fillFontPopup()

        customSizeCheckbox.target = self
        customSizeCheckbox.action = #selector(customSizeToggled)
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: AppSettings.fontSizeRange.lowerBound)
        formatter.maximum = NSNumber(value: AppSettings.fontSizeRange.upperBound)
        formatter.maximumFractionDigits = 1
        sizeField.formatter = formatter
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sizeField.setAccessibilityLabel(String(localized: "Font size"))
        sizeStepper.minValue = AppSettings.fontSizeRange.lowerBound
        sizeStepper.maxValue = AppSettings.fontSizeRange.upperBound
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(stepperChanged)
        let sizeRow = NSStackView(views: [customSizeCheckbox, sizeField, sizeStepper, sizeUnit])
        sizeRow.spacing = 6

        sidebarControl.segmentCount = SidebarTextSize.allCases.count
        for (index, size) in SidebarTextSize.allCases.enumerated() {
            sidebarControl.setLabel(size.title, forSegment: index)
        }
        sidebarControl.trackingMode = .selectOne
        sidebarControl.target = self
        sidebarControl.action = #selector(sidebarChanged)
        sidebarControl.setAccessibilityLabel(String(localized: "Sidebar text size"))

        for popup in [browserZoomPopup, previewZoomPopup] {
            for zoom in Self.zoomLevels {
                popup.addItem(withTitle: Self.percent(zoom))
                popup.lastItem?.representedObject = zoom
            }
            popup.target = self
        }
        browserZoomPopup.action = #selector(browserZoomChanged)
        previewZoomPopup.action = #selector(previewZoomChanged)

        for display in SubagentDisplay.allCases {
            subagentsPopup.addItem(withTitle: display.title)
            subagentsPopup.lastItem?.representedObject = display.rawValue
        }
        subagentsPopup.target = self
        subagentsPopup.action = #selector(subagentsChanged)

        accountsButton.bezelStyle = .rounded
        accountsButton.target = self
        accountsButton.action = #selector(manageAccounts)
        schedulesButton.bezelStyle = .rounded
        schedulesButton.target = self
        schedulesButton.action = #selector(openSchedules)

        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(menuBarToggled)
        inspectableCheckbox.target = self
        inspectableCheckbox.action = #selector(inspectableToggled)
        memoryWarningCheckbox.target = self
        memoryWarningCheckbox.action = #selector(memoryWarningToggled)
        for checkbox in Array(menuBarOptionCheckboxes.values) + Array(sidebarItemCheckboxes.values) {
            checkbox.target = self
            checkbox.action = #selector(optionToggled(_:))
        }
        let option = { (option: MenuBarOption) -> NSView in self.menuBarOptionCheckboxes[option]! }
        let sidebarRows = { (items: [SidebarItem], label: String) -> [[NSView]] in
            items.enumerated().map { index, item in
                [index == 0 ? Self.label(label) : NSGridCell.emptyContentView, self.sidebarItemCheckboxes[item]!]
            }
        }
        checkUpdatesCheckbox.target = self
        checkUpdatesCheckbox.action = #selector(checkUpdatesToggled)
        installUpdatesCheckbox.target = self
        installUpdatesCheckbox.action = #selector(installUpdatesToggled)

        // One tab per area, as in other Mac apps' Settings: the window stays short enough for small screens and each
        // setting is where its name says (#107).
        let general: [[NSView]] = [
            [Self.header(String(localized: "Terminal")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Font:")), fontPopup],
            [Self.label(String(localized: "Size:")), sizeRow],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Layered over your Ghostty config. View › Bigger / Smaller / Actual Size (⌘+ / ⌘− / ⌘0) change only the focused pane."))],
            [Self.header(String(localized: "Browser and Preview")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Browser page zoom:")), browserZoomPopup],
            [Self.label(String(localized: "Preview zoom:")), previewZoomPopup],
            [NSGridCell.emptyContentView, inspectableCheckbox],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Inspect browser panes with Safari › Develop (turn on Show features for web developers in Safari's Advanced settings)."))],
            [Self.header(String(localized: "Memory")), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, memoryWarningCheckbox],
            [NSGridCell.emptyContentView, Self.note(String(localized: "A notification when memory pressure stays at warning or worse for a minute (at most every 30 minutes), with the swap in use and the heaviest process started from a cmds terminal."))],
        ]
        let sidebar: [[NSView]] = [[Self.label(String(localized: "Text size:")), sidebarControl]]
            + sidebarRows(SidebarItem.rowItems, String(localized: "Show in each workspace:", comment: "Settings › Sidebar"))
            + sidebarRows(SidebarItem.footerItems, String(localized: "Footer:", comment: "Settings › Sidebar"))
            + [[NSGridCell.emptyContentView, Self.note(String(localized: "The workspace name, the agent's state and its task always show."))]]
        let agents: [[NSView]] = [
            [Self.label(String(localized: "Show subagents:")), subagentsPopup],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Claude Code subagents as cards under each workspace, with their current action. Needs the SubagentStart / SubagentStop hooks."))],
            [Self.label(String(localized: "Claude accounts:")), accountsButton],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Several of your own Claude Code accounts: when one hits its limit, continue the session with the next."))],
            [Self.label(String(localized: "Schedules:")), schedulesButton],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Start a workspace or continue a Claude Code session at a set time, on weekdays, or when an account’s limit resets (also Window › Schedules…)."))],
        ]
        let menuBar: [[NSView]] = [
            [NSGridCell.emptyContentView, menuBarCheckbox],
            [NSGridCell.emptyContentView, Self.note(String(localized: "An orange badge counts the workspaces that need you (orange in the sidebar). Choose what else the icon and its menu show."))],
            [Self.label(String(localized: "Icon:", comment: "Settings › Menu Bar")), option(.workingBadge)],
            [NSGridCell.emptyContentView, option(.warningDot)],
            [NSGridCell.emptyContentView, option(.animation)],
            [Self.label(String(localized: "Menu:", comment: "Settings › Menu Bar")), option(.systemRings)],
            [NSGridCell.emptyContentView, option(.limitRings)],
            [NSGridCell.emptyContentView, option(.contextRings)],
            [NSGridCell.emptyContentView, option(.workspaces)],
            [NSGridCell.emptyContentView, option(.replyPanel)],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Choosing a workspace opens a panel under the icon to answer its agent without switching to cmds; hold ⌥ to open it in cmds instead."))],
        ]
        let updates: [[NSView]] = [
            [NSGridCell.emptyContentView, checkUpdatesCheckbox],
            [NSGridCell.emptyContentView, installUpdatesCheckbox],
            [NSGridCell.emptyContentView, updatesNote],
        ]
        fontPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        var assistantTab: [(SettingsTab, String, String, [[NSView]], [Int])] = []
        if #available(macOS 26.0, *) {
            let assistant = assistantPane.rows(label: Self.label, note: Self.note, header: Self.header)
            assistantTab = [(.assistant, String(localized: "Assistant", comment: "Settings tab"), "waveform.circle",
                             assistant.rows, assistant.headers)]
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (tab, title, symbol, rows, headers) in [
            (SettingsTab.general, String(localized: "General", comment: "Settings tab"), "gearshape", general, [0, 4, 9]),
            (.sidebar, String(localized: "Sidebar"), "sidebar.left", sidebar, []),
            (.agents, String(localized: "Agents"), "sparkles", agents, []),
            (.menuBar, String(localized: "Menu Bar"), "menubar.rectangle", menuBar, []),
        ] + assistantTab + [
            (.updates, String(localized: "Updates"), "arrow.triangle.2.circlepath", updates, []),
        ] as [(SettingsTab, String, String, [[NSView]], [Int])] {
            // The Assistant tab is longer than a small screen (#264): it scrolls.
            let item = NSTabViewItem(viewController: page(rows, headers: headers, scrolls: tab == .assistant))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        tabController = tabs
        window?.contentViewController = tabs
        window?.toolbarStyle = .preference
    }

    /// One Settings tab: a grid of label / control rows; `headers` are rows with a bold title across both columns.
    /// A tab that `scrolls` is at most `scrollHeight` tall (less on a small screen) and scrolls the rest; it is as tall
    /// as its rows when they fit, so a row that comes or goes (the assistant's problem) still resizes the window.
    private func page(_ rows: [[NSView]], headers: [Int], scrolls: Bool = false) -> NSViewController {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in headers {
            grid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2))
            grid.row(at: row).topPadding = row == 0 ? 0 : 10
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = scrolls ? FlippedView() : NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        let controller = NSViewController()
        guard scrolls else {
            controller.view = content
            controller.preferredContentSize = content.fittingSize
            return controller
        }
        let fitting = content.fittingSize
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        // Wide enough for the rows next to a legacy (always shown) scroller too.
        let width = NSScrollView.frameSize(forContentSize: fitting, horizontalScrollerClass: nil,
                                           verticalScrollerClass: NSScroller.self, borderType: .noBorder,
                                           controlSize: .regular, scrollerStyle: NSScroller.preferredScrollerStyle).width
        let limit = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.scrollHeight)
        // As tall as the rows up to the limit: above the window's wish to keep its size (500), below the labels'
        // compression resistance (750), so the rows scroll instead of being squeezed.
        let follow = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        follow.priority = NSLayoutConstraint.Priority(700)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            limit, follow,
        ])
        scrollHeightLimits.append((limit, controller, fitting.height))
        controller.view = scroll
        controller.preferredContentSize = NSSize(width: width, height: min(fitting.height, Self.scrollHeight))
        return controller
    }

    /// Keeps a scrolled tab, and so the window, on the screen Settings opens on: its title bar, toolbar and a margin
    /// fit above the limit (#264).
    private func fitScrollHeight() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = max(min(Self.scrollHeight, screen.visibleFrame.height - max(chrome, Self.minimumChrome) - Self.screenMargin),
                         Self.minimumScrollHeight)
        for (limit, page, rowsHeight) in scrollHeightLimits {
            limit.constant = height
            page.preferredContentSize.height = min(rowsHeight, height)
        }
    }

    #if DEBUG
    /// Tests only (`debug.show_settings {scroll}`): scrolls the shown tab, when it scrolls, to its top or bottom.
    func debugScroll(toBottom: Bool) {
        guard let scroll = tabController?.tabView.selectedTabViewItem?.view as? NSScrollView,
              let document = scroll.documentView else { return }
        scroll.layoutSubtreeIfNeeded()
        let y = toBottom ? max(document.bounds.height - scroll.contentView.bounds.height, 0) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Tests only (`debug.show_settings {snapshot}`): the shown tab drawn off screen, as a base64 PNG (no toolbar).
    func debugSnapshot() -> String? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }
    #endif

    /// Opens Settings on a tab (the menu bar item's "Menu Bar Settings…").
    func show(tab: SettingsTab) {
        showSettings(nil)
        guard let tabs = tabController,
              let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab.rawValue }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 300
        return label
    }

    private static func percent(_ zoom: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: zoom), number: .percent)
    }

    /// "Ghostty default", then the installed monospaced families (plus a saved family that is not installed), titled
    /// by their localized names (`displayName(ofFamily:)`); each item stores the family name.
    private func fillFontPopup() {
        fontPopup.removeAllItems()
        fontPopup.addItem(withTitle: String(localized: "Ghostty Default"))
        fontPopup.lastItem?.representedObject = nil
        fontPopup.menu?.addItem(.separator())
        var families = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 12)?.familyName, !family.hasPrefix(".") { families.insert(family) }
        }
        if let saved = settings.terminalFontFamily { families.insert(saved) }
        let titled = families.map { (family: $0, title: Self.displayName(ofFamily: $0)) }
        for (family, title) in titled.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            // Not `addItem(withTitle:)`: it drops an item with the same title, and two families may share one.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = family
            fontPopup.menu?.addItem(item)
        }
    }

    /// A family's name as Font Book shows it. Some older Japanese fonts (e.g. ＤＦ平成ゴシック体W3) store their family
    /// name in a legacy encoding that `NSFont.familyName` decodes as Mac Roman ("ÇcÇeïΩê¨ÉSÉVÉbÉNëÃW3"); their
    /// localized name is right. The setting keeps the family name, which CoreText (and so Ghostty) finds either way.
    private static func displayName(ofFamily family: String) -> String {
        let name = NSFontManager.shared.localizedName(forFamily: family, face: nil)
        return name.isEmpty ? family : name
    }

    // MARK: - State

    /// Shows the stored values (also after changes made elsewhere, e.g. `defaults write`).
    private func refresh() {
        if let family = settings.terminalFontFamily {
            if fontPopup.indexOfItem(withRepresentedObject: family) < 0 { fillFontPopup() }
            fontPopup.selectItem(at: fontPopup.indexOfItem(withRepresentedObject: family))
        } else {
            fontPopup.selectItem(at: 0)
        }
        let custom = settings.terminalFontSize
        let size = custom ?? GhosttyRuntime.shared.defaultFontSize
        customSizeCheckbox.state = custom == nil ? .off : .on
        sizeField.doubleValue = size
        sizeStepper.doubleValue = size
        for control in [sizeField, sizeStepper] as [NSControl] { control.isEnabled = custom != nil }
        sizeField.toolTip = custom == nil
            ? String(localized: "Size from your Ghostty config: \(AppSettings.format(size)) pt") : nil
        sidebarControl.selectedSegment = SidebarTextSize.allCases.firstIndex(of: settings.sidebarTextSize) ?? 1
        select(settings.browserZoom, in: browserZoomPopup)
        select(settings.previewZoom, in: previewZoomPopup)
        subagentsPopup.selectItem(at: subagentsPopup.indexOfItem(withRepresentedObject: settings.showSubagents.rawValue))
        menuBarCheckbox.state = settings.showInMenuBar ? .on : .off
        inspectableCheckbox.state = settings.browserInspectable ? .on : .off
        memoryWarningCheckbox.state = settings.memoryWarning ? .on : .off
        for (item, checkbox) in sidebarItemCheckboxes { checkbox.state = settings.sidebar(item) ? .on : .off }
        for (option, checkbox) in menuBarOptionCheckboxes {
            checkbox.state = settings.menuBar(option) ? .on : .off
            checkbox.isEnabled = settings.showInMenuBar
                && (option != .animation || settings.menuBar(.workingBadge))  // the arc circles the working badge
                && (option != .replyPanel || settings.menuBar(.workspaces))  // replies to the workspaces listed
        }
        assistantPane.refresh()
        refreshUpdates()
    }

    /// Also when the window becomes key: Sparkle's own update alert changes the same switches.
    private func refreshUpdates() {
        let updater = Updater.shared
        let available = updater.updater != nil
        let checks = updater.checksAutomatically
        let installs = updater.installsAutomatically
        checkUpdatesCheckbox.state = checks ? .on : .off
        installUpdatesCheckbox.state = installs ? .on : .off
        checkUpdatesCheckbox.isEnabled = available
        installUpdatesCheckbox.isEnabled = available && checks
        switch updater.status {
        case .running:
            updatesNote.stringValue = !checks
                ? String(localized: "cmds does not look for updates by itself. cmds › Check for Updates… looks now.")
                : installs
                ? String(localized: "Checks cmds.n-n.tokyo once a day. A downloaded update is installed when cmds quits; cmds › Check for Updates… installs it now.")
                : String(localized: "Checks cmds.n-n.tokyo once a day and asks before downloading an update.")
        case .starting:
            updatesNote.stringValue = ""
        case .notThisBuild:
            updatesNote.stringValue = String(localized: "Automatic updates work in the release downloaded from cmds.n-n.tokyo, not in this build or instance.")
        case .failed(let message):
            updatesNote.stringValue = String(localized: "Automatic updates are not available: \(message)")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshUpdates()
    }

    private func select(_ zoom: Double, in popup: NSPopUpButton) {
        let nearest = Self.zoomLevels.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1
        popup.selectItem(at: Self.zoomLevels.firstIndex(of: nearest) ?? 0)
    }

    // MARK: - Actions

    @objc private func fontChanged() {
        settings.terminalFontFamily = fontPopup.selectedItem?.representedObject as? String
    }

    @objc private func customSizeToggled() {
        settings.terminalFontSize = customSizeCheckbox.state == .on ? sizeField.doubleValue : nil
        refresh()
    }

    @objc private func sizeFieldChanged() {
        guard customSizeCheckbox.state == .on, sizeField.doubleValue > 0 else { return }
        settings.terminalFontSize = sizeField.doubleValue
        sizeStepper.doubleValue = sizeField.doubleValue
    }

    @objc private func stepperChanged() {
        sizeField.doubleValue = sizeStepper.doubleValue
        settings.terminalFontSize = sizeStepper.doubleValue
    }

    @objc private func sidebarChanged() {
        let cases = SidebarTextSize.allCases
        guard cases.indices.contains(sidebarControl.selectedSegment) else { return }
        settings.sidebarTextSize = cases[sidebarControl.selectedSegment]
    }

    @objc private func browserZoomChanged() {
        settings.browserZoom = browserZoomPopup.selectedItem?.representedObject as? Double ?? 1
    }

    @objc private func subagentsChanged() {
        let raw = subagentsPopup.selectedItem?.representedObject as? String
        settings.showSubagents = raw.flatMap(SubagentDisplay.init(rawValue:)) ?? .tiled
    }

    @objc private func inspectableToggled() {
        settings.browserInspectable = inspectableCheckbox.state == .on
    }

    @objc private func memoryWarningToggled() {
        settings.memoryWarning = memoryWarningCheckbox.state == .on
    }

    @objc private func menuBarToggled() {
        settings.showInMenuBar = menuBarCheckbox.state == .on
    }

    /// A Settings › Sidebar or Settings › Menu Bar checkbox: its identifier is the option's defaults key.
    @objc private func optionToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        if let item = SidebarItem(rawValue: key) { settings.set(item, on: on) }
        if let option = MenuBarOption(rawValue: key) { settings.set(option, on: on) }
    }

    /// One checkbox per option, titled and identified by it.
    private static func checkboxes<Option: OnByDefaultOption>(for _: Option.Type) -> [Option: NSButton] {
        Dictionary(uniqueKeysWithValues: Option.allCases.map { option in
            let checkbox = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
            checkbox.identifier = NSUserInterfaceItemIdentifier(option.rawValue)
            return (option, checkbox)
        })
    }

    @objc private func manageAccounts() {
        ClaudeAccountsWindowController.shared.showWindow(nil)
    }

    @objc private func openSchedules() {
        SchedulesWindowController.shared.showWindow(nil)
    }

    @objc private func checkUpdatesToggled() {
        Updater.shared.checksAutomatically = checkUpdatesCheckbox.state == .on
        refreshUpdates()
    }

    @objc private func installUpdatesToggled() {
        Updater.shared.installsAutomatically = installUpdatesCheckbox.state == .on
        refreshUpdates()
    }

    @objc private func previewZoomChanged() {
        settings.previewZoom = previewZoomPopup.selectedItem?.representedObject as? Double ?? 1
    }
}

/// A scrolled Settings tab's rows, top first.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
