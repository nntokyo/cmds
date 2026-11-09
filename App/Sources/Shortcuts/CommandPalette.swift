import AppKit
import CmdsCore

/// ⇧⌘P (#173): a panel over the main window that finds workspaces, panes, enabled menu commands, recent agent
/// sessions and listening ports by fuzzy search (`FuzzyMatch`) and runs the chosen one. Keyboard only: type, ↑/↓
/// (⌃P/⌃N), Return runs, Esc (or clicking elsewhere) closes. The items are collected when it opens, while the main
/// window still has the keyboard, so menu commands are enabled as they would be in the menu bar.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The open palette, if any.
    private(set) static var current: CommandPalette?

    private let controller: AppController
    private weak var parent: NSWindow?
    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let items: [CommandPaletteItem]
    private(set) var results: [(item: CommandPaletteItem, result: FuzzyMatch.Result)] = []
    private var closing = false
    /// Rows Page Up / Page Down move.
    private static let pageRows = 8

    /// Opens the palette over `window` (closing one that is open).
    @discardableResult
    static func present(controller: AppController, over window: NSWindow?) -> CommandPalette? {
        current?.close()
        guard let window else { return nil }
        let palette = CommandPalette(controller: controller, parent: window,
                                     items: CommandPaletteItem.collect(controller: controller, window: window))
        current = palette
        palette.show()
        return palette
    }

    private init(controller: AppController, parent: NSWindow, items: [CommandPaletteItem]) {
        self.controller = controller
        self.parent = parent
        self.items = items
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        build()
        filter()
    }

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.appearance = parent?.appearance

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        field.placeholderString = String(localized: "Search workspaces, panes, commands, sessions and ports")
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier("command-palette-field")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.refusesFirstResponder = true
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.setAccessibilityIdentifier("command-palette-list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let separator = NSBox()
        separator.boxType = .separator
        for view in [field, separator, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
    }

    private func show() {
        guard let parent else { return }
        let frame = parent.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 70))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// `refocus`: give the main window the keyboard back (not when another window or app took it).
    func close(refocus: Bool = true) {
        guard !closing else { return }
        closing = true
        if Self.current === self { Self.current = nil }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocus { parent?.makeKeyAndOrderFront(nil) }
    }

    // MARK: Filtering and running

    var query: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            filter()
        }
    }

    private func filter() {
        results = FuzzyMatch.rank(items, query: field.stringValue) { $0.candidate }
        table.reloadData()
        if !results.isEmpty { select(row: 0) }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select(row: min(max(table.selectedRow + delta, 0), results.count - 1))
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Closes the palette, gives the main window the keyboard back, then runs result `index` (the selected one).
    func run(_ index: Int? = nil) {
        guard let entry = results[safe: index ?? table.selectedRow] else { return NSSound.beep() }
        close()
        // After the main window is key again: menu commands without a target go to its first responder.
        DispatchQueue.main.async { MainActor.assumeIsolated { entry.item.run() } }
    }

    @objc private func tableDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        run(table.clickedRow)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(-Self.pageRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(Self.pageRows)
        case #selector(NSResponder.insertNewline(_:)): run()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close(refocus: false)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = PaletteRowView.identifier
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteRowView ?? PaletteRowView()
        if let entry = results[safe: row] { view.show(entry.item, positions: entry.result.positions) }
        return view
    }

    // MARK: Debug

    #if DEBUG
    func debugMove(_ rows: Int) { move(rows) }

    /// For `debug.palette`: the results as the list shows them.
    var debugResults: JSONValue {
        .array(results.prefix(100).map { entry in
            .object(["kind": .string(entry.item.kind.rawValue), "title": .string(entry.item.title),
                     "detail": .string(entry.item.detail), "shortcut": .string(entry.item.shortcut),
                     "score": .number(Double(entry.result.score))])
        })
    }

    var debugSelectedRow: Int { table.selectedRow }
    var debugPanel: NSWindow { panel }
    #endif
}

/// Borderless, but takes the keyboard.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One result: title (matched characters bold) over its detail, kind and shortcut on the right.
private final class PaletteRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommandPaletteRow")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let matchedFont = NSFont.boldSystemFont(ofSize: 13)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = Self.titleFont
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        kind.font = .systemFont(ofSize: 11)
        kind.textColor = .tertiaryLabelColor
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let right = NSStackView(views: [shortcut, kind])
        right.orientation = .horizontal
        right.spacing = 8
        for view in [icon, text, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [title, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: CommandPaletteItem, positions: [Int]) {
        icon.image = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)
        title.attributedStringValue = Self.highlighted(item.title, positions: positions)
        detail.stringValue = item.detail
        detail.isHidden = item.detail.isEmpty
        kind.stringValue = item.kind.label
        shortcut.stringValue = item.shortcut
    }

    /// `title` with the characters at `positions` (`FuzzyMatch.Result.positions`: `Character` offsets) in bold.
    private static func highlighted(_ title: String, positions: [Int]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: titleFont])
        let characters = Array(title)
        var offset = 0
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(characters.count)
        for character in characters {
            utf16Offsets.append(offset)
            offset += character.utf16.count
        }
        for position in positions where position < characters.count {
            let range = NSRange(location: utf16Offsets[position], length: characters[position].utf16.count)
            attributed.addAttributes([.font: matchedFont], range: range)
        }
        return attributed
    }
}
