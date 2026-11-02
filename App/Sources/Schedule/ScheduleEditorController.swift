import AppKit
import CmdsCore

/// The Schedules window's add / edit sheet: name, trigger (once, weekly, when an account's limit resets), action
/// (start a workspace, continue a Claude Code session), if late, notify. Problems are listed as you type and Save stays
/// disabled until there are none (`ScheduleRunner.problems`, the same rules as the API).
@MainActor
final class ScheduleEditorController: NSWindowController, NSTextFieldDelegate, NSComboBoxDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?

    private let original: Schedule?
    private var runner: ScheduleRunner { AppController.shared.scheduleRunner }
    private var accounts: [ClaudeAccount] { AppController.shared.claudeAccounts.accounts }

    private let nameField = NSTextField()
    private let triggerPopup = NSPopUpButton()
    private let datePicker = NSDatePicker()
    private var dayBoxes: [(Weekday, NSButton)] = []
    private let timesField = NSTextField()
    private let zoneBox = NSComboBox()
    private let limitAccountPopup = NSPopUpButton()
    private let delayField = NSTextField()
    private let actionPopup = NSPopUpButton()
    private let folderField = NSTextField()
    private let startAccountPopup = NSPopUpButton()
    private let titleField = NSTextField()
    private let commandField = NSTextField()
    private let promptView = NSTextView()
    private let sessionPopup = NSPopUpButton()
    private let continuePromptField = NSTextField()
    private let latePopup = NSPopUpButton()
    private let lateField = NSTextField()
    private let notifyPopup = NSPopUpButton()
    private let problemsLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)
    private var onceRows: [NSGridRow] = []
    private var weeklyRows: [NSGridRow] = []
    private var limitRows: [NSGridRow] = []
    private var startRows: [NSGridRow] = []
    private var continueRows: [NSGridRow] = []
    /// Claude Code sessions offered in the session popup (`representedObject` is the index).
    private var sessions: [ContinueSession] = []

    private enum TriggerKind: Int { case once, weekly, limit }
    private enum ActionKind: Int { case start, resume }

    init(schedule: Schedule?) {
        original = schedule
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("cmds.scheduleEditor")
        super.init(window: window)
        buildContent()
        load(schedule)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(nameField)
    }

    // MARK: - Layout

    private func buildContent() {
        triggerPopup.addItems(withTitles: [String(localized: "Once"), String(localized: "Weekly"),
                                           String(localized: "When an account’s limit resets")])
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.dateValue = Date().addingTimeInterval(3600)
        let symbols = DateFormatter().shortWeekdaySymbols ?? []
        let days = NSStackView()
        days.spacing = 4
        for day in Weekday.allCases {
            let box = NSButton(checkboxWithTitle: symbols[safe: day.calendarWeekday - 1] ?? day.rawValue, target: self,
                               action: #selector(changed))
            dayBoxes.append((day, box))
            days.addArrangedSubview(box)
        }
        timesField.placeholderString = "09:00, 13:30"
        zoneBox.addItems(withObjectValues: TimeZone.knownTimeZoneIdentifiers.sorted())
        zoneBox.placeholderString = String(localized: "This Mac’s time zone")
        zoneBox.completes = true
        delayField.placeholderString = "1"
        let delayRow = NSStackView(views: [delayField, NSTextField(labelWithString: String(localized: "minutes after the reset"))])
        delayRow.spacing = 6

        actionPopup.addItems(withTitles: [String(localized: "Start a workspace"), String(localized: "Continue a Claude Code session")])
        folderField.placeholderString = "~/src/app"
        let choose = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderField, choose])
        folderRow.spacing = 6
        titleField.placeholderString = String(localized: "The schedule’s name")
        commandField.placeholderString = "claude"
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.delegate = self
        let promptScroll = NSScrollView()
        promptScroll.documentView = promptView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptView.autoresizingMask = [.width]
        promptView.minSize = NSSize(width: 0, height: 60)
        promptView.isVerticallyResizable = true
        promptScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        continuePromptField.placeholderString = ContinueSession.defaultPrompt

        latePopup.addItems(withTitles: [String(localized: "Skip the run"), String(localized: "Run if at most this late:")])
        let lateRow = NSStackView(views: [latePopup, lateField, NSTextField(labelWithString: String(localized: "minutes"))])
        lateRow.spacing = 6
        notifyPopup.addItems(withTitles: [String(localized: "When a run fails, is skipped or missed"), String(localized: "Always"),
                                          String(localized: "Never")])

        for popup in [triggerPopup, limitAccountPopup, actionPopup, startAccountPopup, sessionPopup, latePopup, notifyPopup] {
            popup.target = self
            popup.action = #selector(changed)
        }
        datePicker.target = self
        datePicker.action = #selector(changed)
        for field in [nameField, timesField, delayField, folderField, titleField, commandField, continuePromptField, lateField] {
            field.delegate = self
        }
        zoneBox.target = self
        zoneBox.action = #selector(changed)
        zoneBox.delegate = self
        for field in [delayField, lateField] { field.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        for field in [nameField, timesField, folderField, titleField, commandField, continuePromptField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        zoneBox.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let grid = NSGridView(views: [
            [Self.label(String(localized: "Name:")), nameField],
            [Self.label(String(localized: "When:")), triggerPopup],
            [Self.label(String(localized: "Date and time:")), datePicker],
            [Self.label(String(localized: "Days:")), days],
            [Self.label(String(localized: "Times:")), timesField],
            [Self.label(String(localized: "Time zone:")), zoneBox],
            [Self.label(String(localized: "Account:")), limitAccountPopup],
            [Self.label(String(localized: "Delay:")), delayRow],
            [Self.label(String(localized: "Action:")), actionPopup],
            [Self.label(String(localized: "Folder:")), folderRow],
            [Self.label(String(localized: "Account:")), startAccountPopup],
            [Self.label(String(localized: "Title:")), titleField],
            [Self.label(String(localized: "Command:")), commandField],
            [Self.label(String(localized: "First prompt:")), promptScroll],
            [Self.label(String(localized: "Session:")), sessionPopup],
            [Self.label(String(localized: "Prompt:")), continuePromptField],
            [Self.label(String(localized: "If late:")), lateRow],
            [Self.label(String(localized: "Notify:")), notifyPopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        onceRows = [grid.row(at: 2)]
        weeklyRows = [3, 4, 5].map(grid.row(at:))
        limitRows = [6, 7].map(grid.row(at:))
        startRows = [9, 10, 11, 12, 13].map(grid.row(at:))
        continueRows = [14, 15].map(grid.row(at:))
        grid.row(at: 1).topPadding = 6
        grid.row(at: 8).topPadding = 10
        grid.row(at: 16).topPadding = 10

        let commandNote = Self.note(String(localized: """
            The command is typed at the new workspace’s shell prompt. The first prompt needs a command that starts \
            Claude Code; it is pasted once Claude Code is idle.
            """))
        problemsLabel.textColor = .systemRed
        problemsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, commandNote, problemsLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            problemsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.commandNote = commandNote
        window?.contentView = content
    }

    private var commandNote: NSTextField?

    private static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Loading

    private func load(_ schedule: Schedule?) {
        window?.title = schedule == nil ? String(localized: "New Schedule") : String(localized: "Edit Schedule")
        let draft = schedule?.draft
        nameField.stringValue = draft?.name ?? ""
        limitAccountPopup.removeAllItems()
        for account in accounts { limitAccountPopup.addItem(withTitle: account.name) }
        startAccountPopup.removeAllItems()
        startAccountPopup.addItems(withTitles: [String(localized: "None (the shell’s own)"),
                                                String(localized: "Auto (the first without a limit)")])
        for account in accounts { startAccountPopup.addItem(withTitle: account.name) }
        fillSessions(including: draft.flatMap { if case .continueSession(let session) = $0.action { return session }; return nil })
        delayField.stringValue = "1"
        lateField.stringValue = ""
        switch draft?.trigger {
        case .once(let at)?:
            triggerPopup.selectItem(at: TriggerKind.once.rawValue)
            datePicker.dateValue = at
        case .weekly(let rule)?:
            triggerPopup.selectItem(at: TriggerKind.weekly.rawValue)
            for (day, box) in dayBoxes { box.state = rule.weekdays.contains(day) ? .on : .off }
            timesField.stringValue = rule.times.map(\.text).joined(separator: ", ")
            zoneBox.stringValue = rule.timeZone ?? ""
        case .limitReset(let account, let delay)?:
            triggerPopup.selectItem(at: TriggerKind.limit.rawValue)
            if limitAccountPopup.item(withTitle: account) == nil { limitAccountPopup.addItem(withTitle: account) }
            limitAccountPopup.selectItem(withTitle: account)
            delayField.stringValue = String(Int((delay / 60).rounded()))
        case nil:
            triggerPopup.selectItem(at: TriggerKind.once.rawValue)
            for (day, box) in dayBoxes { box.state = Weekday.workdays.contains(day) ? .on : .off }
            timesField.stringValue = "09:00"
        }
        switch draft?.action {
        case .startWorkspace(let start)?:
            actionPopup.selectItem(at: ActionKind.start.rawValue)
            folderField.stringValue = start.cwd
            titleField.stringValue = start.title ?? ""
            commandField.stringValue = start.command ?? ""
            promptView.string = start.prompt ?? ""
            switch start.account {
            case nil: startAccountPopup.selectItem(at: 0)
            case let name? where name.lowercased() == ClaudeAccounts.automatic: startAccountPopup.selectItem(at: 1)
            case let name?:
                if startAccountPopup.item(withTitle: name) == nil { startAccountPopup.addItem(withTitle: name) }
                startAccountPopup.selectItem(withTitle: name)
            }
        case .continueSession(let session)?:
            actionPopup.selectItem(at: ActionKind.resume.rawValue)
            continuePromptField.stringValue = session.prompt
        case nil:
            actionPopup.selectItem(at: ActionKind.start.rawValue)
            continuePromptField.stringValue = ContinueSession.defaultPrompt
        }
        switch draft?.late {
        case .skip?:
            latePopup.selectItem(at: 0)
        case .runIfWithin(let seconds)?:
            latePopup.selectItem(at: 1)
            lateField.stringValue = String(Int((seconds / 60).rounded()))
        case nil:
            latePopup.selectItem(at: 1)
        }
        notifyPopup.selectItem(at: ScheduleNotify.allCases.firstIndex(of: draft?.notify ?? .failures) ?? 0)
        if continuePromptField.stringValue.isEmpty { continuePromptField.stringValue = ContinueSession.defaultPrompt }
    }

    /// The Claude Code sessions cmds remembers (local panes), plus the one being edited.
    private func fillSessions(including current: ContinueSession?) {
        sessionPopup.removeAllItems()
        sessions = []
        let list = (try? AppController.shared.agentSessionList(paneID: nil))?.sessions ?? []
        for entry in list where entry.session.agent == .claude && entry.session.host == nil {
            guard !sessions.contains(where: { $0.sessionID == entry.session.sessionID }) else { continue }
            sessions.append(ContinueSession(sessionID: entry.session.sessionID, cwd: entry.session.cwd))
            sessionPopup.addItem(withTitle: "\(AppController.localizedSummary(entry.session)) — \(entry.pane)")
        }
        if let current, !sessions.contains(where: { $0.sessionID == current.sessionID }) {
            sessions.insert(current, at: 0)
            sessionPopup.insertItem(withTitle: String(localized: "Session \(String(current.sessionID.prefix(8)))"), at: 0)
        }
        if sessions.isEmpty {
            sessionPopup.addItem(withTitle: String(localized: "No Claude Code session is known"))
            sessionPopup.isEnabled = false
        } else {
            sessionPopup.isEnabled = true
            let index = current.flatMap { session in sessions.firstIndex { $0.sessionID == session.sessionID } } ?? 0
            sessionPopup.selectItem(at: index)
        }
    }

    // MARK: - Draft and validation

    private var triggerKind: TriggerKind { TriggerKind(rawValue: triggerPopup.indexOfSelectedItem) ?? .once }
    private var actionKind: ActionKind { ActionKind(rawValue: actionPopup.indexOfSelectedItem) ?? .start }

    /// The schedule as entered, and problems found while reading the fields (unparsable times or numbers).
    private func draft() -> (ScheduleDraft?, [ScheduleProblem]) {
        var problems: [ScheduleProblem] = []
        let trigger: ScheduleTrigger
        switch triggerKind {
        case .once:
            trigger = .once(at: datePicker.dateValue)
        case .weekly:
            let parts = timesField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let times = parts.compactMap(TimeOfDay.init)
            if times.count != parts.count { problems.append(.timesCount) }
            let zone = zoneBox.stringValue.trimmingCharacters(in: .whitespaces)
            trigger = .weekly(WeeklyRule(weekdays: Set(dayBoxes.filter { $0.1.state == .on }.map(\.0)), times: times,
                                         timeZone: zone.isEmpty ? nil : zone))
        case .limit:
            let minutes = Double(delayField.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
            if minutes < 0 { problems.append(.delayOutOfRange) }
            guard let account = limitAccountPopup.titleOfSelectedItem else { return (nil, problems + [.noAccounts]) }
            trigger = .limitReset(account: account, delay: max(0, minutes) * 60)
        }
        let action: ScheduleAction
        switch actionKind {
        case .start:
            let account: String?
            switch startAccountPopup.indexOfSelectedItem {
            case 0, -1: account = nil
            case 1: account = ClaudeAccounts.automatic
            default: account = startAccountPopup.titleOfSelectedItem
            }
            action = .startWorkspace(StartWorkspace(cwd: folderField.stringValue.trimmingCharacters(in: .whitespaces),
                                                    title: Self.nonEmpty(titleField.stringValue), account: account,
                                                    command: Self.nonEmpty(commandField.stringValue),
                                                    prompt: Self.nonEmpty(promptView.string)))
        case .resume:
            guard sessionPopup.isEnabled, var session = sessions[safe: sessionPopup.indexOfSelectedItem] else {
                return (nil, problems + [.sessionIDInvalid])
            }
            session.prompt = continuePromptField.stringValue
            action = .continueSession(session)
        }
        let late: ScheduleLatePolicy
        if latePopup.indexOfSelectedItem == 0 {
            late = .skip
        } else if lateField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            late = .defaultPolicy(for: trigger)
        } else if let minutes = Double(lateField.stringValue.trimmingCharacters(in: .whitespaces)) {
            late = .runIfWithin(minutes * 60)
        } else {
            late = .runIfWithin(0)
        }
        let notify = ScheduleNotify.allCases[safe: notifyPopup.indexOfSelectedItem] ?? .failures
        let draft = ScheduleDraft(name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                  enabled: original?.enabled ?? true, trigger: trigger, action: action, late: late, notify: notify)
        return (draft, problems)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Shows the rows of the chosen trigger and action, and lists the problems.
    private func update() {
        onceRows.forEach { $0.isHidden = triggerKind != .once }
        weeklyRows.forEach { $0.isHidden = triggerKind != .weekly }
        limitRows.forEach { $0.isHidden = triggerKind != .limit }
        startRows.forEach { $0.isHidden = actionKind != .start }
        continueRows.forEach { $0.isHidden = actionKind != .resume }
        commandNote?.isHidden = actionKind != .start
        promptView.isEditable = !commandField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        promptView.textColor = promptView.isEditable ? .labelColor : .disabledControlTextColor
        lateField.isEnabled = latePopup.indexOfSelectedItem == 1
        if lateField.isEnabled, lateField.stringValue.isEmpty, case (let draft?, _) = draft(),
           case .runIfWithin(let seconds) = ScheduleLatePolicy.defaultPolicy(for: draft.trigger) {
            lateField.placeholderString = String(Int(seconds / 60))
        }
        let (draft, parseProblems) = draft()
        var problems = parseProblems
        if let draft {
            let full = original.map { draft.trigger != $0.trigger || (draft.enabled && !$0.enabled) || $0.nextFireAt == nil } ?? true
            problems += runner.problems(draft, excluding: original?.id, full: full && draft.enabled)
        }
        var seen: [String] = []
        for text in problems.map(ScheduleText.problem) where !seen.contains(text) { seen.append(text) }
        problemsLabel.stringValue = seen.joined(separator: "\n")
        problemsLabel.isHidden = seen.isEmpty
        saveButton.isEnabled = seen.isEmpty && !runner.readOnly
    }

    // MARK: - Actions

    @objc private func changed() { update() }
    func controlTextDidChange(_ obj: Notification) { update() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.update() }
    }
    func textDidChange(_ notification: Notification) { update() }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (folderField.stringValue.isEmpty ? NSHomeDirectory()
                                                   : (folderField.stringValue as NSString).expandingTildeInPath))
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let home = NSHomeDirectory()
            self.folderField.stringValue = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
            self.update()
        }
    }

    @objc private func save() {
        update()
        guard saveButton.isEnabled, case (let draft?, _) = draft() else { return }
        do {
            if let original {
                try runner.update(id: original.id) { $0 = draft }
            } else {
                try runner.add(draft, origin: .app)
            }
            close()
        } catch {
            problemsLabel.stringValue = (error as? RPCError)?.message ?? "\(error)"
            problemsLabel.isHidden = false
        }
    }

    @objc private func cancel() { close() }

    override func close() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        onClose?()
        onClose = nil
    }
}
