import AppKit
import CmdsCore

/// Compare and Sync (docs/guide/files.md "Comparing and syncing folders"): the differences between the folders of two
/// files panes, the sync's direction and options, and the planned action of each item, with a checkbox and, for
/// modified items, a choice of direction. Sync queues the checked actions as one transfer (Window › Transfers, the
/// footer of the pane it was opened from). Comparing runs in the background and can be stopped; nothing is changed
/// before Sync.
@MainActor
final class FolderCompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate {
    /// Open windows (each keeps itself until closed).
    private static var windows: [FolderCompareWindowController] = []

    /// Opens a window comparing the two panes' folders. The left one is the pane further left (or higher) in the window;
    /// the direction starts from `from` towards the other one, as F5 copies.
    static func show(_ from: FilesPane, _ other: FilesPane) {
        let (left, right) = isLeft(from, of: other) ? (from, other) : (other, from)
        let controller = FolderCompareWindowController(left: left, right: right, from: from)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.compare()
    }

    /// Newest window (tests).
    static var latest: FolderCompareWindowController? { windows.last }

    private static func isLeft(_ a: FilesPane, of b: FilesPane) -> Bool {
        let x = a.convert(a.bounds, to: nil)
        let y = b.convert(b.bounds, to: nil)
        if abs(x.minX - y.minX) > 1 { return x.minX < y.minX }
        return x.maxY >= y.maxY // stacked: the upper one (window coordinates grow upwards)
    }

    private var left: FileLocation
    private var right: FileLocation
    private weak var pane: FilesPane?
    private var includeHidden: Bool
    private var options: FolderSync.Options
    private var task: FolderCompareTask?
    private var output: FolderCompareTask.Output?
    private var error: String?
    private var itemsRead = 0
    /// Per-item choices for modified items, and items left out of the sync (by path).
    private var choices: [String: FolderSync.Choice] = [:]
    private var excluded = Set<String>()
    private var decisions: [FolderSync.Decision] = []
    private var rows: [Row] = []

    private struct Row {
        var entry: FolderSync.Entry
        var decision: FolderSync.Decision?
    }

    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let directionControl = NSSegmentedControl()
    private let deleteCheckbox = NSButton(checkboxWithTitle: String(localized: "Move extra items to the Trash"),
                                          target: nil, action: nil)
    private let conflictsLabel = NSTextField(labelWithString: String(localized: "Conflicts:"))
    private let conflictsPopup = NSPopUpButton()
    private let hiddenCheckbox = NSButton(checkboxWithTitle: String(localized: "Hidden items"), target: nil, action: nil)
    private let sameCheckbox = NSButton(checkboxWithTitle: String(localized: "Show identical items"), target: nil, action: nil)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let compareButton = NSButton(title: String(localized: "Compare Again"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Close"), target: nil, action: nil)
    private let syncButton = NSButton(title: String(localized: "Sync"), target: nil, action: nil)

    private lazy var bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private lazy var dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let conflictRules: [FolderSync.ConflictRule] = [.newer, .left, .right, .skip]

    private init(left: FilesPane, right: FilesPane, from: FilesPane) {
        self.left = left.location
        self.right = right.location
        pane = from
        includeHidden = from.showHidden
        options = FolderSync.Options(direction: from === left ? .leftToRight : .rightToLeft)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
                              defer: true)
        window.title = String(localized: "Compare \(left.title) and \(right.title)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 300)
        super.init(window: window)
        window.delegate = self
        build()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        for label in [leftLabel, rightLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        leftLabel.stringValue = String(localized: "Left: \(left.displayPath)")
        rightLabel.stringValue = String(localized: "Right: \(right.displayPath)")
        leftLabel.setAccessibilityIdentifier("compare.left")
        rightLabel.setAccessibilityIdentifier("compare.right")

        directionControl.segmentCount = 3
        directionControl.setLabel(String(localized: "Left → Right"), forSegment: 0)
        directionControl.setLabel(String(localized: "Left ← Right"), forSegment: 1)
        directionControl.setLabel(String(localized: "Both Ways"), forSegment: 2)
        directionControl.setToolTip(String(localized: "Copy new and modified items from the left folder to the right one"), forSegment: 0)
        directionControl.setToolTip(String(localized: "Copy new and modified items from the right folder to the left one"), forSegment: 1)
        directionControl.setToolTip(String(localized: "Copy items missing on either side; items that differ are conflicts"), forSegment: 2)
        directionControl.trackingMode = .selectOne
        directionControl.target = self
        directionControl.action = #selector(directionChanged)
        directionControl.setAccessibilityIdentifier("compare.direction")
        deleteCheckbox.target = self
        deleteCheckbox.action = #selector(optionsChanged)
        deleteCheckbox.toolTip = String(localized: "Items only in the folder being synced to go to its Trash (on a server: its Trash there). Nothing is deleted.")
        for rule in Self.conflictRules {
            conflictsPopup.addItem(withTitle: Self.title(rule))
        }
        conflictsPopup.target = self
        conflictsPopup.action = #selector(optionsChanged)
        conflictsPopup.controlSize = .small
        hiddenCheckbox.state = includeHidden ? .on : .off
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(hiddenChanged)
        hiddenCheckbox.toolTip = String(localized: "Include items whose names start with a dot (compares again)")
        sameCheckbox.target = self
        sameCheckbox.action = #selector(optionsChanged)
        let optionsRow = NSStackView(views: [directionControl, deleteCheckbox, conflictsLabel, conflictsPopup, NSView(),
                                             hiddenCheckbox, sameCheckbox])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 12
        optionsRow.setCustomSpacing(4, after: conflictsLabel)

        let columns: [(String, String, CGFloat)] = [
            ("include", "", 24), ("name", String(localized: "Name"), 220), ("left", String(localized: "Left"), 140),
            ("status", String(localized: "Difference"), 130), ("right", String(localized: "Right"), 140),
            ("action", String(localized: "Sync"), 120),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "include" ? 24 : 60
            if id == "include" { column.maxWidth = 24 }
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.style = .fullWidth
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("compare.table")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("compare.status")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        compareButton.target = self
        compareButton.action = #selector(compareOrStop)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.keyEquivalent = "\u{1b}"
        syncButton.target = self
        syncButton.action = #selector(sync)
        syncButton.keyEquivalent = "\r"
        syncButton.setAccessibilityIdentifier("compare.sync")
        let footer = NSStackView(views: [spinner, statusLabel, NSView(), compareButton, closeButton, syncButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [leftLabel, rightLabel, optionsRow, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            optionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            leftLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            rightLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private static func title(_ rule: FolderSync.ConflictRule) -> String {
        switch rule {
        case .newer: return String(localized: "Newer wins")
        case .left: return String(localized: "Left wins")
        case .right: return String(localized: "Right wins")
        case .skip: return String(localized: "Skip")
        }
    }

    // MARK: - Comparing

    /// Lists both folders again (in the background) and plans the sync.
    func compare() {
        task?.cancel()
        let task = FolderCompareTask(left: left, right: right, includeHidden: includeHidden)
        self.task = task
        error = nil
        itemsRead = 0
        update()
        task.start(progress: { [weak self, weak task] count in
            guard let self, let task, self.task === task else { return }
            self.itemsRead = count
            self.updateStatus()
        }, completion: { [weak self, weak task] result in
            guard let self, let task, self.task === task else { return }
            self.task = nil
            switch result {
            case .success(let output):
                self.output = output
                // Remote folders as typed (`~/x`) are now absolute.
                self.left = output.left
                self.right = output.right
                self.leftLabel.stringValue = String(localized: "Left: \(output.left.displayPath)")
                self.rightLabel.stringValue = String(localized: "Right: \(output.right.displayPath)")
            case .failure(let error as FolderCompareError):
                self.output = nil
                self.error = error.localizedText
            case .failure(is FolderSync.Cancelled):
                self.error = self.output == nil ? String(localized: "Stopped.") : nil
            case .failure(let error):
                self.output = nil
                self.error = TransferFailure(error).localizedText
            }
            self.update()
        })
    }

    @objc private func compareOrStop() {
        if let task {
            task.cancel()
            self.task = nil
            if output == nil { error = String(localized: "Stopped.") }
            update()
        } else {
            compare()
        }
    }

    @objc private func hiddenChanged() {
        includeHidden = hiddenCheckbox.state == .on
        compare()
    }

    @objc private func directionChanged() {
        options.direction = [.leftToRight, .rightToLeft, .both][max(0, directionControl.selectedSegment)]
        update()
    }

    @objc private func optionsChanged() {
        options.deleteExtra = deleteCheckbox.state == .on
        options.conflictRule = Self.conflictRules[max(0, conflictsPopup.indexOfSelectedItem)]
        update()
    }

    /// Plans again from the comparison and the options, and shows it.
    private func update() {
        let entries = output?.comparison.entries ?? []
        decisions = FolderSync.plan(entries, options: options, choices: choices)
        if sameCheckbox.state == .on {
            let byPath = Dictionary(decisions.map { ($0.entry.path, $0) }, uniquingKeysWith: { a, _ in a })
            rows = entries.map { Row(entry: $0, decision: byPath[$0.path]) }
        } else {
            rows = decisions.map { Row(entry: $0.entry, decision: $0) }
        }
        directionControl.selectedSegment = [.leftToRight, .rightToLeft, .both].firstIndex(of: options.direction) ?? 0
        deleteCheckbox.state = options.deleteExtra ? .on : .off
        deleteCheckbox.isEnabled = options.direction != .both
        conflictsPopup.selectItem(at: Self.conflictRules.firstIndex(of: options.conflictRule) ?? 0)
        conflictsLabel.isHidden = options.direction != .both
        conflictsPopup.isHidden = options.direction != .both
        tableView.reloadData()
        updateStatus()
    }

    /// The row of `decision` is ticked (rows without an action have nothing to tick).
    private func isChecked(_ decision: FolderSync.Decision) -> Bool { !excluded.contains(decision.entry.path) }

    /// The actions that Sync would queue: planned and checked.
    private var checkedActions: [FolderSync.Action] { decisions.filter(isChecked).compactMap(\.action) }

    private func updateStatus() {
        let running = task != nil
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        compareButton.title = running ? String(localized: "Stop") : String(localized: "Compare Again")
        let actions = checkedActions
        syncButton.isEnabled = !running && output?.comparison.truncated == false && !actions.isEmpty
        if running {
            statusLabel.stringValue = String(localized: "Comparing… \(itemsRead) items read")
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        if let error {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
            return
        }
        guard let output else {
            statusLabel.stringValue = ""
            return
        }
        statusLabel.textColor = .labelColor
        if output.comparison.truncated {
            statusLabel.stringValue = FolderCompareError.truncated(output.comparison.itemsRead).localizedText
            statusLabel.textColor = .systemOrange
            return
        }
        let summary = FolderSync.Summary(decisions: decisions, including: isChecked)
        if decisions.isEmpty {
            statusLabel.stringValue = String(localized: "The folders are the same (\(output.comparison.itemsRead) items).")
            return
        }
        var parts: [String] = []
        if summary.toRight > 0 { parts.append(String(localized: "\(summary.toRight) to copy to the right")) }
        if summary.toLeft > 0 { parts.append(String(localized: "\(summary.toLeft) to copy to the left")) }
        let trash = summary.trashLeft + summary.trashRight
        if trash > 0 { parts.append(String(localized: "\(trash) to move to the Trash")) }
        if summary.unsettled > 0 { parts.append(String(localized: "\(summary.unsettled) conflicts not synced")) }
        if parts.isEmpty { parts.append(String(localized: "Nothing to sync")) }
        statusLabel.stringValue = String(localized: "\(decisions.count) differences: ") + parts.joined(separator: ", ")
    }

    // MARK: - Sync

    @objc private func sync() {
        guard let output, !output.comparison.truncated else { return }
        let actions = checkedActions
        guard !actions.isEmpty, let window else { return NSSound.beep() }
        let summary = FolderSync.Summary(actions)
        let trashed = summary.trashLeft + summary.trashRight
        guard trashed > 0 else { return start(actions, output) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move \(trashed) items to the Trash?")
        alert.informativeText = String(localized: "They are not in the folder being synced from. Items on this Mac go to its Trash, items on a server to your Trash there (~/.local/share/Trash). Nothing is deleted.")
        alert.addButton(withTitle: String(localized: "Sync"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.start(actions, output) }
        }
    }

    private func start(_ actions: [FolderSync.Action], _ output: FolderCompareTask.Output) {
        let request = TransferJob.SyncRequest(left: output.left, right: output.right, direction: options.direction,
                                              actions: actions)
        let job = TransferCenter.shared.startSync(request, from: pane)
        if let pane {
            pane.startedTransfers.insert(job.id)
            pane.updateStatus()
        }
        close()
    }

    @objc private func closeWindow() { close() }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        Self.windows.removeAll { $0 === self }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let row = rows[safe: index] else { return nil }
        let entry = row.entry
        switch id {
        case "include":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(includeClicked(_:)))
            box.tag = index
            box.isEnabled = row.decision?.action != nil
            box.state = box.isEnabled && !excluded.contains(entry.path) ? .on : .off
            return box
        case "name":
            return label(entry.path + (entry.isFolder ? "/" : ""), truncate: .byTruncatingHead)
        case "left": return label(describe(entry.left))
        case "right": return label(describe(entry.right))
        case "status":
            let text = label(statusText(row))
            if row.decision?.isConflict == true || row.decision?.replacesNewer == true || entry.status == .unreadable {
                text.textColor = .systemOrange
            } else if entry.status == .same || entry.status == .skipped {
                text.textColor = .secondaryLabelColor
            }
            text.toolTip = entry.error
            return text
        case "action":
            guard entry.status == .modified else { return label(actionText(row.decision)) }
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.isBordered = false
            popup.addItems(withTitles: [String(localized: "Copy to right"), String(localized: "Copy to left"),
                                        String(localized: "Skip")])
            switch row.decision?.action?.kind {
            case .copy(to: .right)?: popup.selectItem(at: 0)
            case .copy(to: .left)?: popup.selectItem(at: 1)
            default: popup.selectItem(at: 2)
            }
            popup.tag = index
            popup.target = self
            popup.action = #selector(choiceChanged(_:))
            return popup
        default:
            return nil
        }
    }

    private func label(_ text: String, truncate: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = truncate
        field.font = .systemFont(ofSize: 12)
        field.toolTip = text
        return field
    }

    private func describe(_ item: FileItem?) -> String {
        guard let item else { return "—" }
        let date = item.modified.map { dates.string(from: $0) }
        switch item.kind {
        case .file: return [bytes.string(fromByteCount: item.size), date].compactMap { $0 }.joined(separator: "  ")
        case .folder: return String(localized: "Folder")
        case .symlink: return String(localized: "Symbolic link")
        case .other: return String(localized: "Special file")
        }
    }

    private func statusText(_ row: Row) -> String {
        let entry = row.entry
        var text: String
        switch entry.status {
        case .leftOnly: text = String(localized: "Only on the left")
        case .rightOnly: text = String(localized: "Only on the right")
        case .same: text = String(localized: "Same")
        case .skipped: text = String(localized: "Link (not synced)")
        case .unreadable: text = String(localized: "Could not be read")
        case .modified:
            if entry.kindsDiffer {
                text = String(localized: "File and folder")
            } else {
                switch entry.newer {
                case .left?: text = String(localized: "Left is newer")
                case .right?: text = String(localized: "Right is newer")
                case nil: text = String(localized: "Different size")
                }
            }
            if row.decision?.isConflict == true { text = String(localized: "Conflict: \(text)") }
        }
        if row.decision?.replacesNewer == true { text += String(localized: " (replaces the newer one)") }
        return text
    }

    private func actionText(_ decision: FolderSync.Decision?) -> String {
        switch decision?.action?.kind {
        case .copy(to: .right)?: return String(localized: "Copy to right")
        case .copy(to: .left)?: return String(localized: "Copy to left")
        case .trash(.left)?: return String(localized: "Move to Trash (left)")
        case .trash(.right)?: return String(localized: "Move to Trash (right)")
        case nil: return decision == nil ? "" : String(localized: "Keep")
        }
    }

    @objc private func includeClicked(_ sender: NSButton) {
        guard let row = rows[safe: sender.tag] else { return }
        if sender.state == .on { excluded.remove(row.entry.path) } else { excluded.insert(row.entry.path) }
        updateStatus()
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let row = rows[safe: sender.tag] else { return }
        choices[row.entry.path] = [FolderSync.Choice.useLeft, .useRight, .skip][max(0, sender.indexOfSelectedItem)]
        update()
    }

    // MARK: - Tests

    #if DEBUG
    /// `debug.compare` (docs/internals/testing.md): the newest Compare window's state; `direction`, `delete`,
    /// `conflicts`, `hidden`, `same` set its options, `choose {path, choice}` and `exclude {path, on}` set items,
    /// `compare` compares again, `sync` starts the sync (no confirmation: the test asked for it), `snapshot` (with
    /// `appearance` light or dark) draws the window as PNG, `close` closes it.
    func debugPerform(_ params: Params) throws -> JSONValue {
        if let raw = try params.string("direction") {
            guard let direction = FolderSync.Direction(rawValue: raw) else { throw RPCError.invalidParams("direction") }
            options.direction = direction
        }
        if let delete = try params.bool("delete") { options.deleteExtra = delete }
        if let raw = try params.string("conflicts") {
            guard let rule = FolderSync.ConflictRule(rawValue: raw) else { throw RPCError.invalidParams("conflicts") }
            options.conflictRule = rule
        }
        if let same = try params.bool("same") { sameCheckbox.state = same ? .on : .off }
        if let path = try params.string("path") {
            if let raw = try params.string("choice") {
                guard let choice = FolderSync.Choice(rawValue: raw) else { throw RPCError.invalidParams("choice") }
                choices[path] = choice
            }
            if let on = try params.bool("exclude") {
                if on { excluded.insert(path) } else { excluded.remove(path) }
            }
        }
        update()
        switch try params.string("action") ?? "state" {
        case "state": break
        case "compare": compare()
        case "hidden":
            includeHidden = try params.bool("on") ?? true
            hiddenCheckbox.state = includeHidden ? .on : .off
            compare()
        case "sync":
            guard let output, !output.comparison.truncated, !checkedActions.isEmpty else {
                throw RPCError.invalidParams("nothing to sync")
            }
            start(checkedActions, output)
        case "close": close()
        case "snapshot":
            // `appearance` (light/dark) draws the window in it. The content view draws no background of its own (the
            // window does), so it is drawn on the window's background colour, as on screen.
            guard let window, let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw RPCError(code: 500, message: "no window")
            }
            if let name = try params.string("appearance") {
                window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
            }
            rep.draw(in: view.bounds)
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw RPCError(code: 500, message: "PNG")
            }
            return ["png_base64": .string(png.base64EncodedString())]
        default: throw RPCError.invalidParams("unknown action")
        }
        return .object([
            "left": .string(left.description),
            "right": .string(right.description),
            "comparing": .bool(task != nil),
            "window": .number(Double(window?.windowNumber ?? 0)),
            "error": error.map(JSONValue.string) ?? .null,
            "status": .string(statusLabel.stringValue),
            "syncEnabled": .bool(syncButton.isEnabled),
            "direction": .string(options.direction.rawValue),
            "rows": .array(rows.map { row in
                .object([
                    "path": .string(row.entry.path),
                    "status": .string(statusText(row)),
                    "action": .string(actionText(row.decision)),
                    "checked": .bool(row.decision?.action != nil && !excluded.contains(row.entry.path)),
                ])
            }),
        ])
    }
    #endif
}
