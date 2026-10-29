import AppKit

private extension NSPasteboard.PasteboardType {
    static let cmdsWorkspace = NSPasteboard.PasteboardType("tokyo.n-n.cmds.workspace")
}

/// Vertical tabs: one row per workspace. Drag to reorder, double-click to rename, context menu.
@MainActor
final class SidebarViewController: NSViewController {
    private let controller: AppController
    private let tableView = NSTableView()
    private var rowIDs: [String] = []
    private var isSyncingSelection = false
    private var lastWidth: CGFloat = 0

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

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace")!,
                                 target: self, action: #selector(addClicked))
        addButton.isBordered = false
        addButton.toolTip = "New Workspace (⌘N)"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(scrollView)
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        self.view = view
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
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceCellView)?
                    .configure(with: controller.workspaces[row], index: row)
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
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Leave empty to use the directory name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
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
        let cell = tableView.makeView(withIdentifier: WorkspaceCellView.identifier, owner: nil) as? WorkspaceCellView
            ?? WorkspaceCellView()
        if let workspace = controller.workspaces[safe: row] { cell.configure(with: workspace, index: row) }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
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
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameMenuClicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        let close = NSMenuItem(title: "Close Workspace", action: #selector(closeClicked(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        menu.items = [rename, .separator(), close]
    }
}
