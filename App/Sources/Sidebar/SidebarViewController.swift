import AppKit

private extension NSPasteboard.PasteboardType {
    static let cmdsWorkspace = NSPasteboard.PasteboardType("tokyo.n-n.cmds.workspace")
}

/// Vertical tabs: one row per workspace. Drag to reorder, double-click to rename, context menu.
@MainActor
final class SidebarViewController: NSViewController {
    private let controller: AppController
    private let tableView = NSTableView()
    private let usageFooter = SystemUsageView()
    private let compactFooter = CompactUsageView()
    private let compactButton = NSButton()
    private var rowIDs: [String] = []
    private var isSyncingSelection = false
    private var lastWidth: CGFloat = 0
    /// Constraints swapped between the full sidebar and the compact rail.
    private var fullConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []

    /// Width of the compact rail.
    static let compactWidth: CGFloat = 52
    /// The toggle button at the top of the sidebar was clicked (the window controller resizes the split).
    var onToggleCompact: (() -> Void)?

    /// Compact rail: workspace numbers, attention dots and status colours; tiny meters in the footer.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue, isViewLoaded else { return }
            applyMode()
        }
    }

    init(controller: AppController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("workspace"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(renameClicked)
        tableView.registerForDraggedTypes([.cmdsWorkspace])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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
        for subview in [compactButton, scrollView, separator, usageFooter, compactFooter, addButton] as [NSView] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            compactButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            compactButton.widthAnchor.constraint(equalToConstant: 20),
            compactButton.heightAnchor.constraint(equalToConstant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: compactButton.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        fullConstraints = [
            compactButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            separator.bottomAnchor.constraint(equalTo: usageFooter.topAnchor, constant: -8),
            usageFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            usageFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            usageFooter.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        ]
        compactConstraints = [
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
        usageFooter.isHidden = isCompact
        compactFooter.isHidden = !isCompact
        let symbol = isCompact ? "sidebar.right" : "sidebar.leading"
        compactButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        compactButton.toolTip = isCompact ? String(localized: "Expand Sidebar (⌃⌘S)") : String(localized: "Compact Sidebar (⌃⌘S)")
        compactButton.setAccessibilityLabel(isCompact ? String(localized: "Expand Sidebar") : String(localized: "Compact Sidebar"))
        tableView.intercellSpacing = NSSize(width: 0, height: isCompact ? 2 : 4)
        rowIDs = controller.workspaces.map(\.id)
        tableView.reloadData()
        isSyncingSelection = true
        if let selected = controller.selectedWorkspaceID, let row = rowIDs.firstIndex(of: selected) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        isSyncingSelection = false
        updateUsage()
    }

    @objc private func compactClicked() {
        onToggleCompact?()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Notification text wraps, so row heights depend on the sidebar width.
        guard view.bounds.width != lastWidth else { return }
        lastWidth = view.bounds.width
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rowIDs.count))
    }

    func reload() {
        let ids = controller.workspaces.map(\.id)
        if ids != rowIDs {
            rowIDs = ids
            tableView.reloadData()
        } else {
            for row in 0..<ids.count {
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                (cell as? WorkspaceCellView)?.configure(with: controller.workspaces[row], index: row)
                (cell as? CompactWorkspaceCellView)?.configure(with: controller.workspaces[row], index: row)
            }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<ids.count))
        }
        isSyncingSelection = true
        if let selected = controller.selectedWorkspaceID, let row = ids.firstIndex(of: selected) {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    /// New resource-usage sample: refresh the usage line of visible rows and the footer. No reload, no
    /// height changes (the usage line's visibility does not depend on the values), selection untouched.
    func updateUsage() {
        for (row, workspace) in controller.workspaces.enumerated() where rowIDs[safe: row] == workspace.id {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (cell as? WorkspaceCellView)?.updateUsage(with: workspace)
            (cell as? CompactWorkspaceCellView)?.updateUsage(with: workspace)
        }
        let limits = controller.activeAgentLimits()
        if isCompact {
            compactFooter.update(sample: controller.systemSample)
            compactFooter.update(agentLimits: limits)
        } else {
            usageFooter.update(sample: controller.systemSample)
            usageFooter.update(agentLimits: limits)
        }
    }

    // MARK: - Actions

    @objc private func addClicked() {
        controller.createWorkspace()
    }

    @objc private func renameClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let id = rowIDs[safe: row] else { return }
        promptRename(workspaceID: id)
    }

    @objc private func closeClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? controller.closeWorkspace(id: id)
    }

    @objc private func renameMenuClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        promptRename(workspaceID: id)
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
    func numberOfRows(in tableView: NSTableView) -> Int { rowIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isCompact {
            let cell = tableView.makeView(withIdentifier: CompactWorkspaceCellView.identifier, owner: nil)
                as? CompactWorkspaceCellView ?? CompactWorkspaceCellView()
            if let workspace = controller.workspaces[safe: row] { cell.configure(with: workspace, index: row) }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: WorkspaceCellView.identifier, owner: nil) as? WorkspaceCellView
            ?? WorkspaceCellView()
        if let workspace = controller.workspaces[safe: row] { cell.configure(with: workspace, index: row) }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if isCompact { return CompactWorkspaceCellView.height }
        guard let workspace = controller.workspaces[safe: row] else { return 40 }
        return WorkspaceCellView.height(for: workspace, width: tableView.bounds.width)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let id = rowIDs[safe: tableView.selectedRow] else { return }
        try? controller.selectWorkspace(id: id)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(rowIDs[row], forType: .cmdsWorkspace)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: .cmdsWorkspace),
              let from = rowIDs.firstIndex(of: id) else { return false }
        try? controller.moveWorkspace(id: id, to: from < row ? row - 1 : row)
        return true
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let id = rowIDs[safe: tableView.clickedRow] else { return }
        let rename = NSMenuItem(title: String(localized: "Rename…"), action: #selector(renameMenuClicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        let close = NSMenuItem(title: String(localized: "Close Workspace"), action: #selector(closeClicked(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        menu.items = [rename, .separator(), close]
    }
}
