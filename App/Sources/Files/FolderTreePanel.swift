import AppKit
import CmdsCore

/// The folder tree on the left of a files pane (#484, docs/guide/files.md "Folder tree"): the root folder and what is
/// below it, folders opened in place with their disclosure triangle. It only shows and reports; the pane
/// (FilesPane+Tree.swift) reads folders for it, moves the list and copies or moves dropped items. Rules (root, which
/// folders to open, order) in `CmdsCore.FolderTree`.
@MainActor
final class FolderTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// One row. A class: the outline view keeps rows (and their open state) by identity.
    final class Node: NSObject {
        let path: String
        var isFolder: Bool
        var isHidden: Bool
        /// The folder's entries as last read (all of them, hidden included); nil until read.
        var entries: [FileEntry]?
        var loading = false
        var children: [Node] = []

        init(path: String, isFolder: Bool, isHidden: Bool) {
            self.path = path
            self.isFolder = isFolder
            self.isHidden = isHidden
        }

        var name: String { FolderTree.name(path) }
    }

    /// Reads a folder's entries (off the main thread) and calls back on the main thread.
    var read: ((_ path: String, _ done: @escaping @MainActor (Result<[FileEntry], Error>) -> Void) -> Void)?
    var icon: ((Node) -> NSImage)?
    /// A folder row was chosen: show it in the list.
    var onShowFolder: ((String) -> Void)?
    /// A file row was chosen: show its folder with it selected.
    var onShowFile: ((String) -> Void)?
    /// Double-click or Return on a file.
    var onOpenFile: ((String) -> Void)?
    /// Space on a file.
    var onPreviewFile: ((String) -> Void)?
    /// Tab: back to the list.
    var onFocusList: (() -> Void)?
    var onFocus: (() -> Void)?
    var validateDrop: ((_ info: NSDraggingInfo, _ folder: String) -> NSDragOperation)?
    var acceptDrop: ((_ info: NSDraggingInfo, _ folder: String) -> Bool)?

    private(set) var root: Node?
    var showHidden = false {
        didSet {
            guard showHidden != oldValue, let root else { return }
            rebuild(root)
            outline.reloadData()
            if let revealed { reveal(revealed) }
        }
    }

    let outline = FolderTreeOutlineView()
    private let scrollView = NSScrollView()
    /// Every node made so far, by path: rebuilt children reuse them, so open folders stay open.
    private var nodes: [String: Node] = [:]
    /// The folder the list shows (selected here, its ancestors opened).
    private var revealed: String?
    /// A file chosen in the tree: it stays selected here while the list shows its folder.
    private var chosenFile: String?
    /// Set while the panel selects a row itself (no report back to the pane).
    private var selectingItself = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files.tree.name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.panel = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL, FilesPane.remoteFileType])
        outline.draggingDestinationFeedbackStyle = .regular
        outline.setAccessibilityIdentifier("files.tree")
        outline.setAccessibilityLabel(String(localized: "Folder Tree"))
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - What the pane tells it

    /// Starts the tree at `path` (forgets what was read under another root).
    func setRoot(_ path: String) {
        guard root?.path != path else { return }
        nodes = [:]
        revealed = nil
        let node = Node(path: path, isFolder: true, isHidden: false)
        nodes[path] = node
        root = node
        outline.reloadData()
        load(node)
    }

    /// The list shows `folder`: its ancestors are opened (read first where needed) and its row selected.
    func reveal(_ folder: String) {
        revealed = folder
        guard let root else { return }
        let chain = FolderTree.chain(from: root.path, to: folder)
        for path in chain {
            guard let node = nodes[path], node.isFolder else { return }
            if path == folder { break }
            guard node.entries != nil else {
                // Continued once read (`load` calls `reveal` again).
                return load(node)
            }
            outline.expandItem(node)
        }
        if let file = chosenFile, RemotePath.parent(file) != folder { chosenFile = nil }
        guard let node = chosenFile.flatMap({ nodes[$0] }) ?? nodes[folder] else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        selectingItself = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectingItself = false
        outline.scrollRowToVisible(row)
    }

    /// The pane listed `folder` (its own listing, so changes on disk show here too).
    func update(folder: String, entries: [FileEntry]) {
        guard let node = nodes[folder], node.isFolder else { return }
        apply(entries, to: node)
    }

    /// Reload (⌘R): every folder read so far is read again.
    func reloadAll() {
        for node in nodes.values where node.isFolder && node.entries != nil { load(node, force: true) }
    }

    /// One folder read again (something was copied or moved into it), if the tree has read it before.
    func reload(_ path: String) {
        guard let node = nodes[path], node.entries != nil else { return }
        load(node, force: true)
    }

    // MARK: - Reading

    private func load(_ node: Node, force: Bool = false) {
        guard node.isFolder, !node.loading, force || node.entries == nil, let read else { return }
        node.loading = true
        read(node.path) { [weak self, weak node] result in
            guard let self, let node, self.nodes[node.path] === node else { return }
            node.loading = false
            switch result {
            case .success(let entries): self.apply(entries, to: node)
            case .failure: self.apply([], to: node)
            }
        }
    }

    private func apply(_ entries: [FileEntry], to node: Node) {
        let before = node.entries
        node.entries = entries
        guard before != entries || before == nil else { return }
        rebuild(node)
        let selected = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
        outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        if node === root { outline.expandItem(root) }
        if let selected, outline.row(forItem: selected) >= 0 {
            selectingItself = true
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: selected)), byExtendingSelection: false)
            selectingItself = false
        }
        if let revealed { reveal(revealed) }
    }

    /// The node's children from its entries, reusing the nodes already made (open folders stay open).
    private func rebuild(_ node: Node) {
        guard let entries = node.entries else { return }
        node.children = FolderTree.children(entries, showHidden: showHidden).map { entry in
            let path = RemotePath.join(node.path, entry.name)
            if let existing = nodes[path] {
                if existing.isFolder != entry.isFolder { existing.entries = nil }
                existing.isFolder = entry.isFolder
                existing.isHidden = entry.isHidden
                return existing
            }
            let child = Node(path: path, isFolder: entry.isFolder, isHidden: entry.isHidden)
            nodes[path] = child
            return child
        }
        for child in node.children where child.entries != nil { rebuild(child) }
    }

    // MARK: - Data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return root == nil ? 0 : 1 }
        if node.entries == nil { load(node) }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root! }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("files.tree.cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isHidden ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = icon?(node)
        cell.imageView?.alphaValue = node.isHidden ? 0.5 : 1
        cell.toolTip = node.path
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(icon)
        cell.addSubview(field)
        cell.imageView = icon
        cell.textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selectingItself, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        if node.isFolder {
            chosenFile = nil
            guard node.path != revealed else { return }
            onShowFolder?(node.path)
        } else {
            chosenFile = node.path
            onShowFile?(node.path)
        }
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node.path)
        }
    }

    /// The selected row, for the outline's keys.
    var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }

    // MARK: - Drop onto a folder

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Between rows, or onto a file: into the folder those rows are in.
        guard let target = dropFolder(item) else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return validateDrop?(info, target.path) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = dropFolder(item) else { return false }
        return acceptDrop?(info, folder.path) ?? false
    }

    /// The folder a drop on `item` goes into: the folder itself, a file's folder, the root for empty space.
    private func dropFolder(_ item: Any?) -> Node? {
        guard let node = (item as? Node) ?? root else { return nil }
        if node.isFolder { return node }
        return nodes[RemotePath.parent(node.path)]
    }
}

#if DEBUG
extension FolderTreePanel {
    /// Tests only (`debug.files`): the row of `path`.
    func debugRow(_ path: String) -> Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? Node)?.path == path }
    }

    func debugRows() -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? Node else { return nil }
            let mark = node.isFolder ? (outline.isItemExpanded(node) ? "▾ " : "▸ ") : "  "
            let selected = outline.selectedRow == row ? " *" : ""
            return String(repeating: "  ", count: outline.level(forRow: row)) + mark + node.path + selected
        }
    }

    /// As a double-click on the row of `path`.
    func debugOpen(_ path: String) {
        guard let node = nodes(path) else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node.path)
        }
    }

    private func nodes(_ path: String) -> Node? { debugRow(path).flatMap { outline.item(atRow: $0) as? Node } }
}
#endif

/// The outline of the folder tree: Return opens a file, Space previews it, Tab goes back to the list.
@MainActor
final class FolderTreeOutlineView: NSOutlineView {
    weak var panel: FolderTreePanel?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { panel?.onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard let panel else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (36, []), (76, []), (36, [.option]): // Return, keypad Enter; ⌥Return opens a file in its default app
            guard let node = panel.selectedNode else { return }
            if node.isFolder {
                if isItemExpanded(node) { collapseItem(node) } else { expandItem(node) }
            } else {
                panel.onOpenFile?(node.path)
            }
        case (49, []): // Space
            guard let node = panel.selectedNode, !node.isFolder else { return NSSound.beep() }
            panel.onPreviewFile?(node.path)
        case (48, []): // Tab
            panel.onFocusList?()
        default:
            super.keyDown(with: event)
        }
    }
}
