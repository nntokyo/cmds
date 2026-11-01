import AppKit
import CmdsCore

/// Settings › Claude Accounts › Manage…: the user's Claude Code accounts (docs/guide/ai-agents.md "Several Claude
/// accounts"). Lists name, config directory, limit and whether sessions are shared; adds, removes and reorders
/// accounts; shares session transcripts (after asking); switches automatically or not. Everything goes through
/// `AppController` (AppController+Accounts), which saves `claude-accounts.json` in the support directory, so an
/// isolated instance (`CMDS_SUPPORT_DIR`) never changes the accounts of the app in use.
@MainActor
final class ClaudeAccountsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ClaudeAccountsWindowController()

    private var controller: AppController { AppController.shared }
    private let table = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let clearLimitButton = NSButton(title: String(localized: "Clear Limit"), target: nil, action: nil)
    private let openButton = NSButton(title: String(localized: "New Workspace"), target: nil, action: nil)
    private let shareButton = NSButton(title: String(localized: "Share Sessions…"), target: nil, action: nil)
    private let autoSwitchCheckbox = NSButton(checkboxWithTitle: String(localized: "Switch automatically when an account hits its limit"),
                                              target: nil, action: nil)
    private let sharingNote = NSTextField(wrappingLabelWithString: "")
    private var list = ClaudeAccountList(accounts: [], autoSwitch: false)
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?
    /// While the window is open: reset times count down and limits expire.
    private static let refreshInterval: TimeInterval = 30

    private enum Column: String, CaseIterable {
        case name, directory, status, sessions

        var title: String {
            switch self {
            case .name: return String(localized: "Name")
            case .directory: return String(localized: "Config Directory")
            case .status: return String(localized: "Status")
            case .sessions: return String(localized: "Sessions")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 110
            case .directory: return 200
            case .status: return 170
            case .sessions: return 110
            }
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = String(localized: "Claude Accounts")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmds.claudeAccounts")
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        buildContent()
        observer = NotificationCenter.default.addObserver(forName: AppController.accountsDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeAccountsWindowController.shared.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        refresh()
        if window?.isVisible != true { window?.center() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeAccountsWindowController.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Layout

    private func buildContent() {
        let intro = NSTextField(wrappingLabelWithString: String(localized: """
            Each account is a Claude Code config directory (CLAUDE_CONFIG_DIR) that you sign in to yourself once: open \
            a workspace with the account, run claude and type /login. cmds keeps only the names and paths, never \
            credentials. When an account hits its limit, cmds offers to continue the session with the next account.
            """))
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let terms = NSTextField(wrappingLabelWithString: String(localized: """
            Use only your own accounts. You are responsible for following Anthropic’s terms for each account.
            """))
        terms.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        terms.textColor = .secondaryLabelColor

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier("cmds.claudeAccounts.table")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add Account")), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove Account")), forSegment: 1)
        addRemove.trackingMode = .momentary
        addRemove.segmentStyle = .smallSquare
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked)
        let arrows: [(NSButton, String, String, Selector)] = [
            (upButton, "chevron.up", String(localized: "Move Up"), #selector(moveAccountUp)),
            (downButton, "chevron.down", String(localized: "Move Down"), #selector(moveAccountDown)),
        ]
        for (button, symbol, label, action) in arrows {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .smallSquare
            button.toolTip = label
            button.target = self
            button.action = action
        }
        clearLimitButton.target = self
        clearLimitButton.action = #selector(clearLimit)
        clearLimitButton.toolTip = String(localized: "Forget this account’s limit (e.g. when it has reset early)")
        openButton.target = self
        openButton.action = #selector(openWorkspace)
        openButton.toolTip = String(localized: "A new workspace whose shell uses this account (CLAUDE_CONFIG_DIR); run claude there, and /login the first time")
        shareButton.target = self
        shareButton.action = #selector(shareSessions)
        for button in [clearLimitButton, openButton, shareButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [addRemove, upButton, downButton, NSView(), openButton, clearLimitButton])
        buttons.spacing = 6
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        autoSwitchCheckbox.target = self
        autoSwitchCheckbox.action = #selector(autoSwitchToggled)
        let autoNote = NSTextField(wrappingLabelWithString: String(localized: """
            Otherwise cmds asks in the pane and in a notification. Either way it waits until Claude Code is idle at its \
            prompt, quits it and resumes the same session with the next account that has not hit its limit.
            """))
        autoNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoNote.textColor = .secondaryLabelColor
        sharingNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sharingNote.textColor = .secondaryLabelColor
        let shareRow = NSStackView(views: [sharingNote, shareButton])
        shareRow.alignment = .firstBaseline
        shareRow.spacing = 8
        sharingNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [intro, scroll, buttons, shareRow, autoSwitchCheckbox, autoNote, terms])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shareRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        for label in [intro, terms, autoNote] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.contentView = content
    }

    // MARK: - State

    private func refresh() {
        let selected = selectedAccount?.name
        list = controller.accountList()
        table.reloadData()
        if let selected, let row = list.accounts.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        autoSwitchCheckbox.state = list.autoSwitch ? .on : .off
        let unshared = list.accounts.filter { $0.sessions == .missing || $0.sessions == .separate }
        shareButton.isEnabled = !unshared.isEmpty
        if list.accounts.count < 2 {
            sharingNote.stringValue = String(localized: "Add at least two accounts to continue sessions across them.")
        } else if unshared.isEmpty {
            sharingNote.stringValue = String(localized: "Sessions are shared: each account’s projects folder is the first account’s.")
        } else {
            sharingNote.stringValue = String(localized: "To continue a session under another account, its transcripts must be shared (a projects symlink).")
        }
        updateButtons()
    }

    private var selectedAccount: ClaudeAccountStatus? {
        list.accounts.indices.contains(table.selectedRow) ? list.accounts[table.selectedRow] : nil
    }

    private func updateButtons() {
        let row = table.selectedRow
        let hasSelection = list.accounts.indices.contains(row)
        addRemove.setEnabled(hasSelection, forSegment: 1)
        upButton.isEnabled = hasSelection && row > 0
        downButton.isEnabled = hasSelection && row < list.accounts.count - 1
        clearLimitButton.isEnabled = selectedAccount?.limit != nil
        openButton.isEnabled = selectedAccount?.exists ?? false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { list.accounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue),
              list.accounts.indices.contains(row) else { return nil }
        let account = list.accounts[row]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        guard let field = cell.textField else { return cell }
        field.textColor = .labelColor
        field.toolTip = nil
        switch column {
        case .name:
            field.stringValue = account.name
        case .directory:
            field.stringValue = account.configDir
            field.toolTip = ClaudeAccounts.expandedPath(account.configDir)
            if !account.exists {
                field.textColor = .systemRed
                field.toolTip = String(localized: "This folder does not exist yet: open a workspace with the account and sign in with claude.")
            }
        case .status:
            if let limit = account.limit {
                field.stringValue = String(localized: "Limit — \(AppController.localizedReset(limit))")
                field.textColor = .systemOrange
                field.toolTip = limit.message
            } else {
                field.stringValue = String(localized: "Available")
            }
            if !account.panes.isEmpty {
                field.stringValue += " · " + account.panes.joined(separator: " ")
            }
        case .sessions:
            switch account.sessions {
            case .shared: field.stringValue = String(localized: "Shared")
            case .missing, .separate:
                field.stringValue = String(localized: "Not shared")
                field.textColor = .secondaryLabelColor
            case .elsewhere:
                field.stringValue = String(localized: "Linked elsewhere")
                field.textColor = .systemOrange
                field.toolTip = String(localized: "projects is a link or file pointing elsewhere; cmds leaves it alone.")
            case .noConfigDir:
                field.stringValue = "–"
            }
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
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

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - Actions

    @objc private func addRemoveClicked() {
        addRemove.selectedSegment == 0 ? addAccount() : removeAccount()
    }

    private func addAccount() {
        guard let window else { return }
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "work"
        let pathField = NSTextField(string: "")
        pathField.placeholderString = "~/.claude-work"
        let choose = NSButton(title: String(localized: "Choose…"), target: nil, action: nil)
        choose.bezelStyle = .rounded
        let chooser = FolderChooser(field: pathField)
        choose.target = chooser
        choose.action = #selector(FolderChooser.choose)
        let pathRow = NSStackView(views: [pathField, choose])
        pathRow.spacing = 6
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name:")), nameField],
            [NSTextField(labelWithString: String(localized: "Config directory:")), pathRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 56)
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        pathField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let alert = NSAlert()
        alert.messageText = String(localized: "Add Claude Account")
        alert.informativeText = String(localized: """
            A folder of its own for each account, e.g. ~/.claude-work. Use ~/.claude for the account plain claude uses. \
            cmds does not sign in: open a workspace with the account, run claude and type /login.
            """)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.controller.addAccount(name: nameField.stringValue, configDir: pathField.stringValue)
            } catch {
                self.showError(error)
            }
        }
    }

    private func removeAccount() {
        guard let account = selectedAccount, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(account.name)” from cmds?")
        alert.informativeText = String(localized: "Its folder \(account.configDir) and everything in it stay as they are. Panes using it keep running.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.controller.removeAccount(name: account.name) } catch { self.showError(error) }
        }
    }

    @objc private func moveAccountUp() { move(by: -1) }
    @objc private func moveAccountDown() { move(by: 1) }

    private func move(by offset: Int) {
        guard let account = selectedAccount else { return }
        let target = table.selectedRow + offset
        guard list.accounts.indices.contains(target) else { return }
        do { try controller.moveAccount(name: account.name, to: target) } catch { showError(error) }
        table.selectRowIndexes([target], byExtendingSelection: false)
    }

    @objc private func clearLimit() {
        guard let account = selectedAccount else { return }
        do { try controller.clearAccountLimit(name: account.name) } catch { showError(error) }
    }

    @objc private func openWorkspace() {
        guard let status = selectedAccount, let account = controller.claudeAccounts.account(named: status.name) else { return }
        controller.createWorkspace(title: "Claude: \(account.name)", account: account)
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func autoSwitchToggled() {
        controller.setAccountAutoSwitch(autoSwitchCheckbox.state == .on)
    }

    /// Asks before linking: lists what each account's projects folder becomes.
    @objc private func shareSessions() {
        guard let window else { return }
        let steps = controller.accountSharingPlan()
        var lines: [String] = []
        for step in steps {
            switch step.action {
            case .none: lines.append(String(localized: "\(step.account): keeps \(step.projectsPath) (the shared folder)"))
            case .createLink: lines.append(String(localized: "\(step.account): projects becomes a link to the shared folder"))
            case .moveAsideAndLink(let backup):
                lines.append(String(localized: "\(step.account): its projects folder is renamed to \(backup) (kept, not deleted), then linked"))
            case .skip(let reason): lines.append(String(localized: "\(step.account): left alone (\(reason))"))
            }
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Share sessions between accounts?")
        alert.informativeText = String(localized: """
            Claude Code keeps each session in its config folder’s projects folder. To continue a session under another \
            account, every account’s projects folder becomes a symbolic link to the first account’s. Sessions kept \
            only in a renamed folder are not resumable from there until you move them back yourself.
            """) + "\n\n" + lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Share"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { _ = try self.controller.shareAccountSessions() } catch { self.showError(error) }
            self.refresh()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Claude Accounts")
        alert.informativeText = (error as? RPCError)?.message ?? "\(error)"
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// The Add sheet's Choose… button: picks a folder (hidden ones shown, since config folders start with a dot).
@MainActor
private final class FolderChooser: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field }

    @objc func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        field.stringValue = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
