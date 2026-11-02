import AppKit
import Combine
import CmdsCore

/// Window › Schedules… (also Settings › Agents): the schedules with when they run next and how the last run ended;
/// add, remove, edit (ScheduleEditorController), turn on and off, Run Now, Cancel Run; the selected schedule's history
/// below. Everything goes through `ScheduleRunner`, which saves `schedules.json` in the support directory.
@MainActor
final class SchedulesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SchedulesWindowController()

    private var runner: ScheduleRunner { AppController.shared.scheduleRunner }
    private let table = NSTableView()
    private let historyTable = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let editButton = NSButton(title: String(localized: "Edit…"), target: nil, action: nil)
    private let runButton = NSButton(title: String(localized: "Run Now"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel Run"), target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var entries: [ScheduleListEntry] = []
    private var runs: [ScheduleRun] = []
    private var subscription: AnyCancellable?
    private var refreshTimer: Timer?
    private var editor: ScheduleEditorController?
    /// While the window is open: relative times and limits change.
    private static let refreshInterval: TimeInterval = 30

    private enum Column: String, CaseIterable {
        case enabled, name, when, action, next, last

        var title: String {
            switch self {
            case .enabled: return String(localized: "On")
            case .name: return String(localized: "Name")
            case .when: return String(localized: "When")
            case .action: return String(localized: "Action")
            case .next: return String(localized: "Next Run")
            case .last: return String(localized: "Last Result")
            }
        }

        var width: CGFloat {
            switch self {
            case .enabled: return 30
            case .name: return 140
            case .when: return 170
            case .action: return 170
            case .next: return 100
            case .last: return 150
            }
        }
    }

    private enum HistoryColumn: String, CaseIterable {
        case time, cause, result, place

        var title: String {
            switch self {
            case .time: return String(localized: "Started")
            case .cause: return String(localized: "Cause")
            case .result: return String(localized: "Result")
            case .place: return String(localized: "Pane")
            }
        }

        var width: CGFloat {
            switch self {
            case .time: return 110
            case .cause: return 80
            case .result: return 440
            case .place: return 90
            }
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = String(localized: "Schedules")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmds.schedules")
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func showSchedules(_ sender: Any?) { showWindow(sender) }

    override func showWindow(_ sender: Any?) {
        subscription = runner.changes.receive(on: RunLoop.main).sink { _ in
            MainActor.assumeIsolated { SchedulesWindowController.shared.refresh() }
        }
        refresh()
        if window?.isVisible != true { window?.center() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { SchedulesWindowController.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        subscription = nil
    }

    // MARK: - Layout

    private func buildContent() {
        let intro = NSTextField(wrappingLabelWithString: String(localized: """
            Start a workspace or continue a Claude Code session at a set time, on weekdays, or when an account’s limit \
            resets. Schedules run while cmds runs. Nothing is typed into a busy agent or a pane running another program.
            """))
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .enabled ? 24 : 60
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(editSchedule)
        table.setAccessibilityIdentifier("cmds.schedules.table")

        for column in HistoryColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history." + column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            historyTable.addTableColumn(tableColumn)
        }
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.usesAlternatingRowBackgroundColors = true
        historyTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        historyTable.setAccessibilityIdentifier("cmds.schedules.history")

        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add Schedule")), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove Schedule")), forSegment: 1)
        addRemove.trackingMode = .momentary
        addRemove.segmentStyle = .smallSquare
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked)
        for (button, action) in [(editButton, #selector(editSchedule)), (runButton, #selector(runNow)), (cancelButton, #selector(cancelRun))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        runButton.toolTip = String(localized: "Run the selected schedule now, also when it is off")
        cancelButton.toolTip = String(localized: "Stop the active run; nothing more is typed")
        let buttons = NSStackView(views: [addRemove, NSView(), editButton, runButton, cancelButton])
        buttons.spacing = 6
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .systemOrange
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        let historyLabel = NSTextField(labelWithString: String(localized: "History"))
        historyLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        let scroll = Self.scroll(table)
        let historyScroll = Self.scroll(historyTable)
        let stack = NSStackView(views: [intro, note, scroll, buttons, detail, historyLabel, historyScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            historyScroll.heightAnchor.constraint(equalTo: scroll.heightAnchor, multiplier: 0.7),
        ])
        for label in [intro, note, detail] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.contentView = content
    }

    private static func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - State

    func refresh() {
        let selected = selectedEntry?.schedule.id
        entries = runner.list().schedules
        table.reloadData()
        if let selected, let row = entries.firstIndex(where: { $0.schedule.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        if runner.readOnly {
            note.stringValue = runner.readOnlyReason?.hasPrefix("version") == true
                ? String(localized: "The schedules were saved by a newer version of cmds. They are shown, but not run or changed here.")
                : String(localized: "The schedules file could not be read. Nothing is changed until it can be.")
        } else if !runner.movedAside.isEmpty {
            let names = runner.movedAside.map(\.lastPathComponent).joined(separator: ", ")
            note.stringValue = String(localized: "A damaged schedules file was kept as \(names) in the cmds support folder.")
        } else {
            note.stringValue = ""
        }
        note.isHidden = note.stringValue.isEmpty
        selectionChanged()
    }

    private var selectedEntry: ScheduleListEntry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func selectionChanged() {
        let entry = selectedEntry
        runs = entry.map { runner.runs(scheduleID: $0.schedule.id, limit: ScheduleLimits.maxRunsPerSchedule) } ?? runner.runs(scheduleID: nil, limit: 100)
        historyTable.reloadData()
        let writable = !runner.readOnly
        addRemove.setEnabled(writable, forSegment: 0)
        addRemove.setEnabled(writable && entry != nil, forSegment: 1)
        editButton.isEnabled = writable && entry != nil
        runButton.isEnabled = !runner.readOnly && entry != nil && entry?.activeRun == nil
        cancelButton.isEnabled = entry?.activeRun != nil
        if let entry {
            var parts = [ScheduleText.origin(entry.schedule.origin)]
            if let problem = runner.problem(of: entry.schedule) { parts.append(ScheduleText.problem(problem)) }
            if let run = entry.activeRun { parts.append(String(localized: "Running: \(ScheduleText.state(run.state))")) }
            detail.stringValue = parts.joined(separator: " · ")
        } else {
            detail.stringValue = String(localized: "Recent runs of all schedules:")
        }
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? entries.count : runs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        if tableView === historyTable {
            guard let column = HistoryColumn(rawValue: String(id.rawValue.dropFirst("history.".count))), runs.indices.contains(row) else { return nil }
            return historyCell(column, runs[row])
        }
        guard let column = Column(rawValue: id.rawValue), entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        if column == .enabled {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled(_:)))
            checkbox.state = entry.schedule.enabled ? .on : .off
            checkbox.tag = row
            checkbox.isEnabled = !runner.readOnly
            checkbox.setAccessibilityLabel(String(localized: "On"))
            return checkbox
        }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        guard let field = cell.textField else { return cell }
        field.textColor = .labelColor
        field.toolTip = nil
        let accounts = AppController.shared.claudeAccounts.accounts
        switch column {
        case .enabled:
            break
        case .name:
            field.stringValue = entry.schedule.name
            field.toolTip = ScheduleText.origin(entry.schedule.origin)
            // Made by a script or an agent: visible at a glance.
            if case .api = entry.schedule.origin { field.stringValue += " · " + String(localized: "CLI", comment: "a schedule made with the command line or socket API") }
        case .when:
            field.stringValue = ScheduleText.trigger(entry.schedule.trigger, accounts: accounts)
            field.toolTip = field.stringValue
        case .action:
            field.stringValue = ScheduleText.action(entry.schedule.action)
            field.toolTip = field.stringValue
        case .next:
            if let run = entry.activeRun {
                field.stringValue = ScheduleText.state(run.state)
                field.textColor = .controlAccentColor
            } else if let next = entry.nextFireAt, entry.schedule.enabled {
                field.stringValue = ScheduleText.time(next)
            } else {
                field.stringValue = "–"
                field.textColor = .secondaryLabelColor
            }
        case .last:
            if let last = entry.lastRun {
                field.stringValue = ScheduleText.state(last.state)
                field.toolTip = ScheduleText.outcome(last)
                if last.state.isProblem { field.textColor = .systemOrange }
            } else {
                field.stringValue = "–"
                field.textColor = .secondaryLabelColor
            }
            if runner.problem(of: entry.schedule) != nil {
                field.stringValue = String(localized: "Invalid")
                field.textColor = .systemRed
                field.toolTip = runner.problem(of: entry.schedule).map(ScheduleText.problem)
            }
        }
        return cell
    }

    private func historyCell(_ column: HistoryColumn, _ run: ScheduleRun) -> NSView {
        let id = NSUserInterfaceItemIdentifier("history." + column.rawValue)
        let cell = (historyTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        guard let field = cell.textField else { return cell }
        field.textColor = .labelColor
        switch column {
        case .time:
            field.stringValue = ScheduleText.time(run.startedAt)
        case .cause:
            field.stringValue = ScheduleText.cause(run.cause)
        case .result:
            let prefix = selectedEntry == nil ? "\(run.scheduleName): " : ""
            field.stringValue = prefix + (run.state.isActive ? ScheduleText.state(run.state) : ScheduleText.outcome(run))
            field.textColor = run.state.isProblem ? .systemOrange : .labelColor
        case .place:
            field.stringValue = [run.pane, run.account].compactMap { $0 }.joined(separator: " · ")
        }
        field.toolTip = field.stringValue
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === table else { return }
        selectionChanged()
    }

    // MARK: - Actions

    @objc private func addRemoveClicked() {
        addRemove.selectedSegment == 0 ? addSchedule() : removeSchedule()
    }

    private func addSchedule() { openEditor(nil) }

    @objc private func editSchedule() {
        guard let entry = selectedEntry, !runner.readOnly else { return }
        openEditor(entry.schedule)
    }

    private func openEditor(_ schedule: Schedule?) {
        guard let window, editor == nil else { return }
        let editor = ScheduleEditorController(schedule: schedule)
        self.editor = editor
        editor.onClose = { [weak self] in self?.editor = nil }
        editor.begin(on: window)
    }

    private func removeSchedule() {
        guard let entry = selectedEntry, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(entry.schedule.name)”?")
        alert.informativeText = entry.activeRun != nil
            ? String(localized: "Its active run is cancelled. Its history is kept.")
            : String(localized: "Its history is kept.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.runner.remove(id: entry.schedule.id) } catch { self.showError(error) }
        }
    }

    @objc private func enabledToggled(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let schedule = entries[sender.tag].schedule
        let id = schedule.id
        var draft = schedule.draft
        draft.enabled = sender.state == .on
        let problems = runner.problems(draft, excluding: id, full: draft.enabled)
        if !problems.isEmpty {
            showMessage(problems.map(ScheduleText.problem).joined(separator: "\n"))
            return refresh()
        }
        do {
            try runner.update(id: id) { $0.enabled = sender.state == .on }
        } catch {
            showError(error)
            refresh()
        }
    }

    @objc private func runNow() {
        guard let entry = selectedEntry else { return }
        do { try runner.runNow(id: entry.schedule.id) } catch { showError(error) }
    }

    @objc private func cancelRun() {
        guard let run = selectedEntry?.activeRun else { return }
        do { try runner.cancel(runID: run.id) } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        showMessage((error as? RPCError)?.message ?? "\(error)")
    }

    private func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Schedules")
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
