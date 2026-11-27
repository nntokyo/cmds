import AppKit
import CmdsCore

/// The folder tree of a files pane (#484, docs/guide/files.md "Folder tree"): shown on the left of the list with a
/// divider, turned on with the header's sidebar button, Pane › Files › Show Folder Tree or the context menu, and saved
/// with the session (its root). The tree and the list follow each other: choosing a row in the tree moves the list,
/// and every navigation of the list selects its folder in the tree. The view: FolderTreePanel.swift.
extension FilesPane {
    static let defaultTreeWidth: CGFloat = 200
    static let minimumTreeWidth: CGFloat = 120

    var showsFolderTree: Bool { treeRoot != nil }

    func configureTree() {
        treePanel.read = { [weak self] path, done in self?.readForTree(path, done: done) }
        treePanel.icon = { [weak self] node in self?.treeIcon(node) ?? NSImage() }
        treePanel.onShowFolder = { [weak self] path in self?.navigate(to: path) }
        treePanel.onShowFile = { [weak self] path in
            guard let self else { return }
            self.navigate(to: RemotePath.parent(path), select: [RemotePath.name(path)])
        }
        treePanel.onOpenFile = { [weak self] path in self?.openFromTree(path) }
        treePanel.onPreviewFile = { [weak self] path in self?.previewFromTree(path) }
        treePanel.onFocusList = { [weak self] in self?.focus() }
        treePanel.onFocus = { [weak self] in self?.onFocus?() }
        treePanel.validateDrop = { [weak self] info, folder in self?.treeDropOperation(info, into: folder) ?? [] }
        treePanel.acceptDrop = { [weak self] info, folder in self?.acceptTreeDrop(info, into: folder) ?? false }
        treeDivider.onDrag = { [weak self] delta in self?.resizeTree(by: delta) }
        updateTreeVisibility()
    }

    @objc func toggleFolderTree() {
        setFolderTree(showsFolderTree ? nil : folder)
    }

    /// Shows the tree starting at `root` (nil hides it). The root moves when the list leaves it (`FolderTree.root`).
    func setFolderTree(_ root: String?) {
        let changed = root != treeRoot
        treeRoot = root
        updateTreeVisibility()
        updateHeader()
        treeFolderChanged()
        if changed { onStateChange?() }
    }

    private func updateTreeVisibility() {
        let on = showsFolderTree
        treePanel.isHidden = !on
        treeDivider.isHidden = !on
        treeWidthConstraint?.constant = on ? treeWidth : 0
        treeDividerWidthConstraint?.constant = on ? FolderTreeDivider.width : 0
        treeButton.state = on ? .on : .off
        treeButton.contentTintColor = on ? .controlAccentColor : nil
    }

    /// The list moved to another folder (or the server resolved it): the tree follows.
    func treeFolderChanged() {
        guard let root = treeRoot else { return }
        // A remote folder the server has not resolved yet (`~/x`) has no place in a tree of absolute paths.
        guard folder.hasPrefix("/") else { return }
        let newRoot = FolderTree.root(root.hasPrefix("/") ? root : nil, showing: folder)
        if newRoot != treeRoot {
            treeRoot = newRoot
            onStateChange?()
        }
        treePanel.showHidden = showHidden
        treePanel.setRoot(newRoot)
        treePanel.reveal(RemotePath.normalized(folder))
    }

    /// The list read the shown folder: the tree's row for it gets the same entries.
    func treeListingChanged() {
        guard showsFolderTree, folder.hasPrefix("/") else { return }
        treePanel.update(folder: RemotePath.normalized(folder), entries: allEntries)
    }

    // MARK: - Reading and icons

    private func readForTree(_ path: String, done: @escaping @MainActor (Result<[FileEntry], Error>) -> Void) {
        let finish: @Sendable (Result<[FileEntry], Error>) -> Void = { result in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
        if let host {
            // A pane restored from the session connects only when the user asks (Connect, ⌘R reads the tree again).
            guard !waitingForConnect else { return done(.success([])) }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(Result { try Self.readRemote(host: host, path: path).entries })
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { finish(Self.read(path)) }
    }

    private func treeIcon(_ node: FolderTreePanel.Node) -> NSImage {
        if isRemote { return remoteIcon(FileEntry(name: node.name, isFolder: node.isFolder)) }
        let image = NSWorkspace.shared.icon(forFile: node.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Open and preview from the tree

    /// The list's entry for a file of the tree, once the list shows its folder (remote files are opened through it).
    private func listEntry(_ path: String) -> FileEntry? {
        guard RemotePath.parent(path) == RemotePath.normalized(folder) else { return nil }
        let name = RemotePath.name(path)
        return allEntries.first { $0.name == name }
    }

    private func openFromTree(_ path: String) {
        guard isRemote else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let entry = listEntry(path) else { return NSSound.beep() }
        openRemoteFiles([entry])
    }

    private func previewFromTree(_ path: String) {
        guard isRemote else { return onPreview?(path) ?? () }
        guard let entry = listEntry(path) else { return NSSound.beep() }
        previewRemote(entry)
    }

    // MARK: - Drop onto a folder of the tree

    private func treeDestination(_ folder: String) -> FileLocation {
        host.map { .remote(host: $0, path: folder) } ?? .local(folder)
    }

    /// The same rules as a drop on a folder row of the list (FilesPane+Table.swift).
    private func treeDropOperation(_ info: NSDraggingInfo, into folder: String) -> NSDragOperation {
        guard let locations = Self.locations(info.draggingPasteboard), !locations.isEmpty else { return [] }
        let destination = treeDestination(folder)
        if isRemote || locations.contains(where: \.isRemote) {
            let operation = Self.remoteDropOperation(info, sources: locations, destination: destination)
            if locations.contains(where: { $0 == destination
                || ($0.isSameTree(as: destination) && RemotePath.isSameOrInside(destination.path, $0.path))
                || ($0.isSameTree(as: destination) && $0.parent == destination && operation == .move) }) {
                return []
            }
            return operation
        }
        let sources = locations.map { URL(fileURLWithPath: $0.path) }
        let target = URL(fileURLWithPath: folder, isDirectory: true)
        if sources.contains(where: { FileNames.isSameOrInside(folder, $0.standardizedFileURL.path) }) { return [] }
        let operation = Self.dropOperation(info, sources: sources, destination: target)
        if operation == .move, sources.allSatisfy({ FileNames.isSamePath($0.deletingLastPathComponent(), target) }) {
            return []
        }
        return operation
    }

    private func acceptTreeDrop(_ info: NSDraggingInfo, into folder: String) -> Bool {
        guard let locations = Self.locations(info.draggingPasteboard), !locations.isEmpty else { return false }
        let destination = treeDestination(folder)
        if isRemote || locations.contains(where: \.isRemote) {
            let operation = Self.remoteDropOperation(info, sources: locations, destination: destination)
            startTransfer(operation == .move ? .move : .copy, sources: locations, destination: destination)
            return true
        }
        let sources = locations.map { URL(fileURLWithPath: $0.path) }
        let target = URL(fileURLWithPath: folder, isDirectory: true)
        let operation = Self.dropOperation(info, sources: sources, destination: target)
        return startOperation(operation == .move ? .move : .copy, sources: sources, destination: target)
    }

    /// A copy or move into `folder` finished: the tree reads it again (the list watches only the shown folder).
    func treeFolderContentsChanged(_ folder: String) {
        guard showsFolderTree else { return }
        treePanel.reload(RemotePath.normalized(folder))
    }

    // MARK: - Width

    private func resizeTree(by delta: CGFloat) {
        let maximum = max(Self.minimumTreeWidth, bounds.width - 160)
        treeWidth = min(maximum, max(Self.minimumTreeWidth, treeWidth + delta))
        treeWidthConstraint?.constant = treeWidth
    }
}

/// The line between the tree and the list; drag it to change the tree's width.
@MainActor
final class FolderTreeDivider: NSView {
    static let width: CGFloat = 5
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastX else { return }
        let x = event.locationInWindow.x
        self.lastX = x
        onDrag?(x - lastX)
    }

    override func mouseUp(with event: NSEvent) {
        lastX = nil
    }
}
