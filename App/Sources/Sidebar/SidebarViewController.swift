import AppKit
import CmdsCore

private extension NSPasteboard.PasteboardType {
    static let cmdsWorkspace = NSPasteboard.PasteboardType("tokyo.n-n.cmds.workspace")
}

/// The table of the sidebar: ⌘F while it has the keyboard opens the filter.
private final class SidebarTableView: NSTableView {
    var onFind: (() -> Void)?
    /// Esc with the sidebar focused (leaves the tiled view).
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Group header row ("Group by Project").
private final class GroupHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarGroupHeader")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: SidebarTextSize.size(11), weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Vertical tabs: one row per workspace. Drag to reorder, double-click to rename, context menu, filter (⌥⌘F),
/// optional grouping by project.
@MainActor
final class SidebarViewController: NSViewController {
    private enum Row: Equatable {
        /// A project header (grouping on): its title and tooltip (the project directory).
        case group(title: String, path: String)
        case workspace(String)

        var workspaceID: String? {
            if case .workspace(let id) = self { return id }
            return nil
        }
    }

    private let controller: AppController
    private let tableView = SidebarTableView()
    private let filterField = NSSearchField()
    private let usageFooter = SystemUsageView()
    private let compactFooter = CompactUsageView()
    private let compactButton = NSButton()
    private var rows: [Row] = []
    /// Last height given to the table per workspace; reloads re-measure and tell the table only about rows that changed.
    private var rowHeights: [String: CGFloat] = [:]
    private var isSyncingSelection = false
    private var lastWidth: CGFloat = 0
    /// Constraints swapped between the full sidebar and the compact rail.
    private var fullConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    /// Top of the rail's toggle button: below the title bar (the traffic lights are wider than the rail).
    private var compactTopConstraint: NSLayoutConstraint?
    private var filterShownConstraints: [NSLayoutConstraint] = []
    private var filterHiddenConstraints: [NSLayoutConstraint] = []
    /// Directory → project root (git top level), for grouping without touching the disk on every reload.
    private var projectRoots: [String: String] = [:]

    /// Width of the compact rail.
    static let compactWidth: CGFloat = 52
    static let groupDefaultsKey = "SidebarGroupByProject"
    /// The toggle button at the top of the sidebar was clicked (the window controller resizes the split).
    var onToggleCompact: (() -> Void)?
    /// The rows changed without a state change (filter, grouping): "tile all" follows the visible rows.
    var onRowsChanged: (() -> Void)?

    /// Workspace ids in row order (filter and grouping applied): the order of the tiled view.
    var visibleWorkspaceIDs: [String] {
        // Computed now, not from `rows`: a workspace created this moment is not in the table yet.
        computeRows().compactMap(\.workspaceID)
    }

    /// Compact rail: workspace numbers, state dots and status colours; tiny meters in the footer.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue, isViewLoaded else { return }
            applyMode()
        }
    }

    private var filterText = ""
    private var isFilterShown = false

    /// Rows grouped under their project directory (git top level, else the directory). Saved like the compact state:
    /// isolated test instances neither read nor write it and start grouped only with `CMDS_SIDEBAR_GROUPED=1`.
    private(set) var groupsByProject: Bool = {
        if CmdsEnv.supportDirectoryOverride() != nil {
            return ProcessInfo.processInfo.environment["CMDS_SIDEBAR_GROUPED"] == "1"
        }
        return UserDefaults.standard.bool(forKey: groupDefaultsKey)
    }()

    /// Drag-reordering maps rows 1:1 to workspaces: only without filter and grouping.
    private var canReorder: Bool { filterText.isEmpty && (!groupsByProject || isCompact) }

    init(controller: AppController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: AppSettings.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keepAwakeChanged),
                                               name: KeepAwakeManager.didChange, object: nil)
        let column = NSTableColumn(identifier: .init("workspace"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(renameClicked)
        tableView.registerForDraggedTypes([.cmdsWorkspace])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onFind = { [weak self] in self?.beginFilter() }
        tableView.onCancel = { [weak self] in
            guard let self, self.controller.isTiling else { return NSSound.beep() }
            try? self.controller.setTiling(.off)
        }
        // ⌘-click / ⇧-click select several workspaces: they are shown side by side (tiled view).
        tableView.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = String(localized: "Filter Workspaces")
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.delegate = self
        filterField.isHidden = true
        filterField.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New Workspace"))!,
                                 target: self, action: #selector(addClicked))
        addButton.isBordered = false
        addButton.toolTip = String(localized: "New Workspace (⌘N)")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        usageFooter.translatesAutoresizingMaskIntoConstraints = false
        compactFooter.translatesAutoresizingMaskIntoConstraints = false

        compactButton.isBordered = false
        compactButton.imagePosition = .imageOnly
        compactButton.contentTintColor = .tertiaryLabelColor
        compactButton.target = self
        compactButton.action = #selector(compactClicked)
        compactButton.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        for subview in [compactButton, filterField, scrollView, separator, usageFooter, compactFooter, addButton] as [NSView] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            compactButton.widthAnchor.constraint(equalToConstant: 20),
            compactButton.heightAnchor.constraint(equalToConstant: 16),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        filterShownConstraints = [
            filterField.topAnchor.constraint(equalTo: compactButton.bottomAnchor, constant: 4),
            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
        ]
        filterHiddenConstraints = [scrollView.topAnchor.constraint(equalTo: compactButton.bottomAnchor, constant: 2)]
        NSLayoutConstraint.activate(filterHiddenConstraints)
        let compactTop = compactButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 30)
        compactTopConstraint = compactTop
        fullConstraints = [
            compactButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            compactButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            separator.bottomAnchor.constraint(equalTo: usageFooter.topAnchor, constant: -8),
            usageFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            usageFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            usageFooter.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        ]
        compactConstraints = [
            compactTop,
            compactButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            separator.bottomAnchor.constraint(equalTo: compactFooter.topAnchor, constant: -8),
            compactFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            compactFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            compactFooter.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            addButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ]
        self.view = view
        applyMode()
    }

    /// Swaps cells, footer and button placement for the current mode (width is set by the window controller).
    private func applyMode() {
        NSLayoutConstraint.deactivate(isCompact ? fullConstraints : compactConstraints)
        NSLayoutConstraint.activate(isCompact ? compactConstraints : fullConstraints)
        if isCompact, isFilterShown { endFilter() }
        usageFooter.isHidden = isCompact
        compactFooter.isHidden = !isCompact
        let symbol = isCompact ? "sidebar.right" : "sidebar.leading"
        compactButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        compactButton.toolTip = isCompact ? String(localized: "Expand Sidebar (⌃⌘S)") : String(localized: "Compact Sidebar (⌃⌘S)")
        compactButton.setAccessibilityLabel(isCompact ? String(localized: "Expand Sidebar") : String(localized: "Compact Sidebar"))
        tableView.intercellSpacing = NSSize(width: 0, height: isCompact ? 2 : 4)
        rows = computeRows()
        rowHeights = [:]
        tableView.reloadData()
        syncSelection(scroll: false)
        updateUsage()
    }

    /// Sidebar text size changed (cmds › Settings…): cells re-set their fonts on reload, heights are re-measured.
    @objc private func settingsChanged() {
        // Show Subagents (Settings › Agents): the "Sub n" badges come and go.
        let subagents = AppSettings.shared.showSubagents
        if isViewLoaded, subagents != appliedSubagentDisplay {
            appliedSubagentDisplay = subagents
            if SidebarTextSize.scale == appliedTextScale || appliedTextScale == nil { reload() }
        }
        let scale = SidebarTextSize.scale
        guard isViewLoaded, scale != appliedTextScale else { return }
        appliedTextScale = scale
        usageFooter.applyTextSize()
        compactFooter.applyTextSize()
        rowHeights = [:]
        tableView.reloadData()
        syncSelection(scroll: false)
        updateUsage()
    }

    /// nil until the first settings change (the views were built for the size at launch).
    private var appliedTextScale: CGFloat?
    private var appliedSubagentDisplay = AppSettings.shared.showSubagents

    @objc private func keepAwakeChanged() {
        guard isViewLoaded else { return }
        updateUsage()
    }

    @objc private func compactClicked() {
        onToggleCompact?()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The rail starts below the title bar: the traffic lights are wider than the rail and would cover it.
        if let window = view.window {
            let titlebar = max(window.frame.height - window.contentLayoutRect.height, 0)
            let top = (titlebar > 0 ? titlebar : 28) + 2
            if compactTopConstraint?.constant != top { compactTopConstraint?.constant = top }
        }
        // Notification text wraps, so row heights depend on the sidebar width.
        guard view.bounds.width != lastWidth else { return }
        lastWidth = view.bounds.width
        rowHeights = [:]
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    // MARK: - Rows

    private func computeRows() -> [Row] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let shown = controller.workspaces.filter { query.isEmpty || Self.matches($0, query) }
        guard groupsByProject, !isCompact else { return shown.map { .workspace($0.id) } }
        var order: [String] = []
        var members: [String: [String]] = [:]
        var titles: [String: String] = [:]
        for workspace in shown {
            let (key, title) = project(of: workspace)
            if members[key] == nil {
                order.append(key)
                titles[key] = title
            }
            members[key, default: []].append(workspace.id)
        }
        return order.flatMap { key in
            [Row.group(title: titles[key] ?? key, path: key)] + (members[key] ?? []).map { .workspace($0) }
        }
    }

    /// Group key (project directory, `host:dir` for SSH) and its header title.
    private func project(of workspace: Workspace) -> (key: String, title: String) {
        guard let cwd = workspace.workingDirectory else {
            return ("", String(localized: "Other", comment: "sidebar group of workspaces without a directory"))
        }
        if let host = workspace.remoteHost {
            return ("\(host):\(cwd)", "\(host): \((cwd as NSString).lastPathComponent)")
        }
        let root: String
        if let known = projectRoots[cwd] {
            root = known
        } else {
            root = GitInfo.projectRoot(at: cwd) ?? cwd
            projectRoots[cwd] = root
        }
        let title = root == NSHomeDirectory() ? "~" : (root as NSString).lastPathComponent
        return (root, title)
    }

    private static func matches(_ workspace: Workspace, _ query: String) -> Bool {
        let fields = [workspace.displayTitle, workspace.agentTopic, workspace.workingDirectory?.abbreviatingHome,
                      workspace.gitBranch, workspace.notificationText, workspace.remoteHost,
                      AgentActivityStyle.badge(for: workspace)?.text]
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }

    private func workspace(atRow row: Int) -> Workspace? {
        rows[safe: row]?.workspaceID.flatMap(controller.workspace(id:))
    }

    private func globalIndex(of workspace: Workspace) -> Int {
        controller.workspaces.firstIndex { $0 === workspace } ?? 0
    }

    func reload() {
        let newRows = computeRows()
        if newRows != rows {
            let visibleChanged = newRows.compactMap(\.workspaceID) != rows.compactMap(\.workspaceID)
            rows = newRows
            rowHeights = [:]
            tableView.reloadData()
            if visibleChanged, controller.tileMode != .off {
                // After this reload: the controller's change re-enters reload().
                DispatchQueue.main.async { [weak self] in self?.onRowsChanged?() }
            }
        } else {
            var changed = IndexSet()
            for (row, item) in rows.enumerated() {
                guard let id = item.workspaceID, let workspace = controller.workspace(id: id) else { continue }
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                (cell as? WorkspaceCellView)?.configure(with: workspace, index: globalIndex(of: workspace))
                (cell as? CompactWorkspaceCellView)?.configure(with: workspace, index: globalIndex(of: workspace))
                if !isCompact, rowHeights[id] != WorkspaceCellView.height(for: workspace, width: tableView.bounds.width) {
                    changed.insert(row)
                }
            }
            // Only rows whose height changed are re-measured (no relayout of the whole table per state change).
            if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }
        }
        syncSelection(scroll: true)
    }

    private func syncSelection(scroll: Bool) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        // Tiled view: every tile's row is selected.
        let ids = controller.isTiling ? controller.tiledWorkspaceIDs : controller.selectedWorkspaceID.map { [$0] } ?? []
        let indexes = IndexSet(ids.compactMap { rows.firstIndex(of: .workspace($0)) })
        guard !indexes.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        if scroll, let selected = controller.selectedWorkspaceID, let row = rows.firstIndex(of: .workspace(selected)),
           selectedRowShown != selected {
            selectedRowShown = selected
            tableView.scrollRowToVisible(row)
        }
    }

    /// The workspace last scrolled into view (scroll only when the selection moves).
    private var selectedRowShown: String?

    /// New resource-usage sample: refresh the usage line of visible rows and the footer. No reload, no
    /// height changes (the usage line's visibility does not depend on the values), selection untouched.
    func updateUsage() {
        for (row, item) in rows.enumerated() {
            guard let id = item.workspaceID, let workspace = controller.workspace(id: id) else { continue }
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (cell as? WorkspaceCellView)?.updateUsage(with: workspace)
            (cell as? CompactWorkspaceCellView)?.updateUsage(with: workspace)
        }
        let limits = controller.activeAgentLimits()
        let keepAwake = KeepAwakeManager.shared.status
        compactFooter.update(keepAwake: keepAwake)
        usageFooter.update(keepAwake: keepAwake)
        if isCompact {
            compactFooter.update(sample: controller.systemSample)
            compactFooter.update(agentLimits: limits)
        } else {
            usageFooter.update(sample: controller.systemSample)
            usageFooter.update(agentLimits: limits)
        }
    }

    // MARK: - Filter

    /// ⌥⌘F / ⌘F in the sidebar: shows the filter field and focuses it (expands the compact rail first).
    func beginFilter() {
        if isCompact { onToggleCompact?() }
        if !isFilterShown {
            isFilterShown = true
            filterField.isHidden = false
            NSLayoutConstraint.deactivate(filterHiddenConstraints)
            NSLayoutConstraint.activate(filterShownConstraints)
        }
        view.window?.makeFirstResponder(filterField)
        filterField.currentEditor()?.selectAll(nil)
    }

    /// Hides the filter (Esc); `clear` also shows all workspaces again.
    func endFilter(clear: Bool = true) {
        guard isFilterShown else { return }
        isFilterShown = false
        filterField.isHidden = true
        NSLayoutConstraint.deactivate(filterShownConstraints)
        NSLayoutConstraint.activate(filterHiddenConstraints)
        if clear, !filterText.isEmpty {
            filterField.stringValue = ""
            filterText = ""
            reload()
        }
        controller.focusedPane?.focus()
    }

    @objc private func filterChanged() {
        guard filterField.stringValue != filterText else { return }
        filterText = filterField.stringValue
        reload()
    }

    /// Return in the filter: go to the first match.
    private func openFirstMatch() {
        guard let id = rows.lazy.compactMap(\.workspaceID).first else { NSSound.beep(); return }
        try? controller.selectWorkspace(id: id)
        controller.focusedPane?.focus()
    }

    func setGroupsByProject(_ on: Bool) {
        guard on != groupsByProject else { return }
        groupsByProject = on
        if CmdsEnv.supportDirectoryOverride() == nil { UserDefaults.standard.set(on, forKey: Self.groupDefaultsKey) }
        projectRoots = [:]
        reload()
    }

    // MARK: - Actions

    @objc private func addClicked() {
        controller.createWorkspace()
    }

    @objc private func renameClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let id = rows[safe: row]?.workspaceID else { return }
        promptRename(workspaceID: id)
    }

    @objc private func closeClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        confirmClose(workspaceID: id)
    }

    @objc private func clearNotificationClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? controller.clearNotification(workspaceID: id)
    }

    @objc private func groupClicked(_ sender: NSMenuItem) {
        setGroupsByProject(!groupsByProject)
    }

    @objc private func filterClicked(_ sender: NSMenuItem) {
        beginFilter()
    }

    @objc private func renameMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        promptRename(workspaceID: id)
    }

    /// The row's × and the context menu: asks first while an agent is still around in the workspace.
    func confirmClose(workspaceID id: String) {
        guard let workspace = controller.workspace(id: id) else { return }
        guard workspace.agentActivity != .none, let window = view.window else {
            try? controller.closeWorkspace(id: id)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Close “\(workspace.displayTitle)”?")
        alert.informativeText = String(localized: "A coding agent is running in this workspace. Closing it ends the agent and its terminals.")
        alert.addButton(withTitle: String(localized: "Close Workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { try? self?.controller.closeWorkspace(id: id) }
            }
        }
    }

    /// Shows a rename sheet for the workspace (default: the selected one).
    func promptRename(workspaceID: String? = nil) {
        guard let window = view.window,
              let workspace = (workspaceID ?? controller.selectedWorkspaceID).flatMap(controller.workspace(id:)) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Workspace")
        alert.informativeText = String(localized: "Leave empty to use the directory name.")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = workspace.customTitle ?? workspace.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let id = workspace.id
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { try? self?.controller.renameWorkspace(id: id, title: field.stringValue) }
                self?.controller.focusedPane?.focus()
            }
        }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .group(let title, let path)? = rows[safe: row] {
            let header = tableView.makeView(withIdentifier: GroupHeaderView.identifier, owner: nil) as? GroupHeaderView
                ?? GroupHeaderView()
            header.label.stringValue = title
            header.toolTip = path.isEmpty ? nil : path
            return header
        }
        guard let workspace = workspace(atRow: row) else { return nil }
        if isCompact {
            let cell = tableView.makeView(withIdentifier: CompactWorkspaceCellView.identifier, owner: nil)
                as? CompactWorkspaceCellView ?? CompactWorkspaceCellView()
            cell.configure(with: workspace, index: globalIndex(of: workspace))
            return cell
        }
        let cell = tableView.makeView(withIdentifier: WorkspaceCellView.identifier, owner: nil) as? WorkspaceCellView
            ?? WorkspaceCellView()
        cell.onClose = { [weak self] id in self?.confirmClose(workspaceID: id) }
        cell.configure(with: workspace, index: globalIndex(of: workspace))
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group? = rows[safe: row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[safe: row]?.workspaceID != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group? = rows[safe: row] { return (20 * SidebarTextSize.scale).rounded() }
        if isCompact { return CompactWorkspaceCellView.height }
        guard let workspace = workspace(atRow: row) else { return 40 }
        let height = WorkspaceCellView.height(for: workspace, width: tableView.bounds.width)
        rowHeights[workspace.id] = height
        return height
    }

    /// A plain click on a tile's row while tiled keeps the tiles and gives that tile the keyboard (Esc in the
    /// sidebar or ⌃⌘T shows one workspace again).
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard !isSyncingSelection, controller.isTiling, proposed.count == 1, let row = proposed.first,
              let id = rows[safe: row]?.workspaceID, controller.tiledWorkspaceIDs.contains(id),
              let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
              event.modifierFlags.intersection([.command, .shift]).isEmpty else { return proposed }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = self.controller.workspace(id: id)?.focusedPane else { return }
            try? self.controller.focusPane(id: pane.id)
        }
        return tableView.selectedRowIndexes
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let ids = tableView.selectedRowIndexes.compactMap { rows[safe: $0]?.workspaceID }
        guard !ids.isEmpty else { return }
        if ids.count >= 2 {
            // The clicked row gets the keyboard when it was just added; else the active tile keeps it.
            let clicked = rows[safe: tableView.clickedRow]?.workspaceID
            let active = clicked.flatMap { ids.contains($0) ? $0 : nil }
            try? controller.setTiling(.selected(ids), active: active)
        } else if controller.isTiling {
            try? controller.setTiling(.off, active: ids[0])
        } else {
            try? controller.selectWorkspace(id: ids[0])
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorder, let id = rows[safe: row]?.workspaceID else { return nil }
        let item = NSPasteboardItem()
        item.setString(id, forType: .cmdsWorkspace)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorder, info.draggingSource as? NSTableView === tableView,
              info.draggingPasteboard.string(forType: .cmdsWorkspace) != nil else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard canReorder, let id = info.draggingPasteboard.string(forType: .cmdsWorkspace),
              let from = controller.workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let target = from < row ? row - 1 : row
        guard target != from else { return false }
        try? controller.moveWorkspace(id: id, to: target)
        return true
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector, _ id: String?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }
        let group = item(String(localized: "Group by Project"), #selector(groupClicked(_:)), nil)
        group.state = groupsByProject ? .on : .off
        let filter = item(String(localized: "Filter Workspaces…"), #selector(filterClicked(_:)), nil)
        guard let workspace = workspace(atRow: tableView.clickedRow) else {
            menu.items = [filter, group]
            return
        }
        let id = workspace.id
        var items = [item(String(localized: "Rename…"), #selector(renameMenuClicked(_:)), id)]
        if workspace.notificationText != nil || workspace.attention {
            items.append(item(String(localized: "Clear Notification"), #selector(clearNotificationClicked(_:)), id))
        }
        items += [.separator(), filter, group, .separator(),
                  item(String(localized: "Close Workspace"), #selector(closeClicked(_:)), id)]
        menu.items = items
    }
}

extension SidebarViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === filterField else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            endFilter()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openFirstMatch()
            return true
        case #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }
}
