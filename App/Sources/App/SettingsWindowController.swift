import AppKit
import CmdsCore

/// cmds › Settings… (⌘,): terminal font and size, sidebar text size, browser/preview zoom, subagent cards. Every control applies
/// immediately (`AppSettings`); there is no OK button.
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
    private var observer: NSObjectProtocol?

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func showSettings(_ sender: Any?) {
        refresh()
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

        let grid = NSGridView(views: [
            [Self.header(String(localized: "Terminal")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Font:")), fontPopup],
            [Self.label(String(localized: "Size:")), sizeRow],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Layered over your Ghostty config. View › Bigger / Smaller / Actual Size (⌘+ / ⌘− / ⌘0) change only the focused pane."))],
            [Self.header(String(localized: "Sidebar")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Text size:")), sidebarControl],
            [Self.header(String(localized: "Browser and Preview")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Browser page zoom:")), browserZoomPopup],
            [Self.label(String(localized: "Preview zoom:")), previewZoomPopup],
            [Self.header(String(localized: "Agents")), NSGridCell.emptyContentView],
            [Self.label(String(localized: "Show subagents:")), subagentsPopup],
            [NSGridCell.emptyContentView, Self.note(String(localized: "Claude Code subagents as cards under each workspace, with their current action. Needs the SubagentStart / SubagentStop hooks."))],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in [0, 4, 6, 9] {
            grid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2))
            grid.row(at: row).topPadding = row == 0 ? 0 : 10
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            fontPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        window?.contentView = content
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

    /// "Ghostty default", then the installed monospaced families (plus a saved family that is not installed).
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
        for family in families.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            fontPopup.addItem(withTitle: family)
            fontPopup.lastItem?.representedObject = family
        }
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

    @objc private func previewZoomChanged() {
        settings.previewZoom = previewZoomPopup.selectedItem?.representedObject as? Double ?? 1
    }
}
