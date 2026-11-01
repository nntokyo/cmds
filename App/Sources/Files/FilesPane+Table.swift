import AppKit
import CmdsCore

/// The list of a files pane: keys (FilesTableView), cells, sorting, type-to-select, rename in place, drag and drop.
extension FilesPane: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Column: String, CaseIterable {
        case name, git, size, modified, kind

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("files." + rawValue) }

        var sortKey: FileSortKey? {
            switch self {
            case .name: return .name
            case .size: return .size
            case .modified: return .modified
            case .kind: return .kind
            case .git: return nil
            }
        }
    }

    func configureTable() {
        tableView.pane = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setAccessibilityIdentifier("files.table")
        let specs: [(Column, String, CGFloat, CGFloat)] = [
            (.name, String(localized: "Name"), 220, 80),
            (.git, String(localized: "Git"), 28, 24),
            (.size, String(localized: "Size"), 70, 40),
            (.modified, String(localized: "Date Modified"), 150, 60),
            (.kind, String(localized: "Kind"), 110, 40),
        ]
        for (column, title, width, minWidth) in specs {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = minWidth
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            if column == .git {
                tableColumn.headerToolTip = String(localized: "Git status: M modified, A added, R renamed, D deleted, ? untracked, U conflict")
                tableColumn.isHidden = true
                tableColumn.resizingMask = []
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
    }

    func updateGitColumn() {
        tableView.tableColumn(withIdentifier: Column.git.identifier)?.isHidden = gitStates == nil
        guard let column = tableView.column(withIdentifier: Column.git.identifier) as Int?, column >= 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: column))
    }

    // MARK: - Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: String(tableColumn.identifier.rawValue.dropFirst("files.".count))),
              let entry = rows[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
            ?? makeCell(column)
        let field = cell.textField
        field?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
        switch column {
        case .name:
            field?.stringValue = entry.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url(of: entry).path)
            cell.imageView?.alphaValue = entry.isHidden ? 0.5 : 1
        case .git:
            let state = gitStates?[entry.name]
            field?.stringValue = state?.rawValue ?? ""
            field?.textColor = state.map(Self.color) ?? .secondaryLabelColor
            field?.toolTip = state.map(Self.gitDescription)
        case .size:
            field?.stringValue = entry.size.map { byteFormatter.string(fromByteCount: $0) } ?? "--"
            field?.textColor = .secondaryLabelColor
        case .modified:
            field?.stringValue = entry.modified.map { dateFormatter.string(from: $0) } ?? ""
            field?.textColor = .secondaryLabelColor
        case .kind:
            field?.stringValue = entry.kind
            field?.textColor = .secondaryLabelColor
        }
        return cell
    }

    private func makeCell(_ column: Column) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = column.identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        var constraints = [
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ]
        switch column {
        case .name:
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            field.isEditable = true
            field.isSelectable = false
            field.delegate = self
            constraints += [
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            ]
        case .git:
            field.alignment = .center
            field.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        case .size:
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        case .modified, .kind:
            field.font = .systemFont(ofSize: 11)
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private static func color(_ state: GitFileState) -> NSColor {
        switch state {
        case .modified, .renamed: return .systemOrange
        case .added: return .systemGreen
        case .deleted, .conflicted: return .systemRed
        case .untracked: return .secondaryLabelColor
        }
    }

    private static func gitDescription(_ state: GitFileState) -> String {
        switch state {
        case .modified: return String(localized: "Modified")
        case .added: return String(localized: "Added")
        case .renamed: return String(localized: "Renamed")
        case .deleted: return String(localized: "Deleted")
        case .untracked: return String(localized: "Untracked")
        case .conflicted: return String(localized: "Conflict")
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(FileSortKey.init(rawValue:))
        else { return }
        sortKey = key
        ascending = descriptor.ascending
        applyRows(keepSelection: true)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn == nil || tableColumn?.identifier == Column.name.identifier else { return nil }
        return rows[safe: row]?.name
    }

    // MARK: - Rename in place

    func beginRename(row: Int) {
        guard let column = tableView.column(withIdentifier: Column.name.identifier) as Int?, column >= 0,
              rows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.renaming = true
        tableView.editColumn(column, row: row, with: nil, select: true)
        tableView.renaming = false
        // Like the Finder: the name without its extension is selected.
        let entry = rows[row]
        if !entry.isFolder, let editor = (tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?
            .textField?.currentEditor() {
            let name = entry.name as NSString
            let ext = name.pathExtension
            if !ext.isEmpty, name.length > ext.count + 1 {
                editor.selectedRange = NSRange(location: 0, length: name.length - ext.count - 1)
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard let entry = rows[safe: row] else { return }
        let newName = field.stringValue
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        guard movement != .cancel, newName != entry.name else {
            field.stringValue = entry.name
            return
        }
        if !rename(entry, to: newName) { field.stringValue = entry.name }
        focus()
    }

    /// Escape gives up the new name (an NSTextField would offer completions instead).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
        if let entry = rows[safe: tableView.row(for: field)] { field.stringValue = entry.name }
        field.abortEditing()
        focus()
        return true
    }

    /// Renames an entry of the shown folder; false (after telling the user) when it cannot.
    @discardableResult
    func rename(_ entry: FileEntry, to newName: String) -> Bool {
        guard FileNames.isValid(newName) else {
            NSSound.beep()
            return false
        }
        let source = url(of: entry)
        let target = folderURL.appendingPathComponent(newName)
        // A case-only change is allowed on case-insensitive volumes (the "existing" item is the same file).
        if FileOperation.exists(target), newName.lowercased() != entry.name.lowercased() {
            showError(String(localized: "“\(newName)” already exists in this folder."), detail: nil)
            return false
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            pendingSelection = [newName]
            load()
            return true
        } catch {
            showError(String(localized: "Could not rename “\(entry.name)”."), detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let entry = rows[safe: row] else { return nil }
        return url(of: entry) as NSURL
    }

    // MARK: - Drop target

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let sources = Self.fileURLs(info.draggingPasteboard), !sources.isEmpty else { return [] }
        var destination = folderURL
        if dropOperation == .on, let entry = rows[safe: row], entry.isFolder {
            destination = url(of: entry)
        } else {
            tableView.setDropRow(-1, dropOperation: .on) // the whole list: into this folder
        }
        // Onto one of the dragged items, or into the folder they are already in: nothing to do.
        let destinationPath = destination.standardizedFileURL.path
        if sources.contains(where: { FileNames.isSameOrInside(destinationPath, $0.standardizedFileURL.path) }) { return [] }
        let operation = Self.dropOperation(info, sources: sources, destination: destination)
        if operation == .move, sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == destinationPath }) {
            return []
        }
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let sources = Self.fileURLs(info.draggingPasteboard), !sources.isEmpty else { return false }
        var destination = folderURL
        if row >= 0, dropOperation == .on, let entry = rows[safe: row], entry.isFolder { destination = url(of: entry) }
        let operation = Self.dropOperation(info, sources: sources, destination: destination)
        return startOperation(operation == .move ? .move : .copy, sources: sources, destination: destination)
    }

    /// Like the Finder: ⌥ copies, ⌘ moves; otherwise items move within a volume and are copied to another one.
    static func dropOperation(_ info: NSDraggingInfo, sources: [URL], destination: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        guard mask.contains(.move) || mask.contains(.generic) else { return mask.contains(.copy) ? .copy : [] }
        let volume = FileOperation.volume(of: destination)
        let sameVolume = volume != nil && sources.allSatisfy { FileOperation.volume(of: $0) == volume }
        return sameVolume ? .move : .copy
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

/// The list of a files pane. Keys (docs/reference/shortcuts.md "Files pane"): Return / ⌘↓ open, ⌘↑ enclosing folder,
/// Space preview, ⌘⌫ Move to Trash, F2 rename, F5 / F6 copy / move to the other pane, F7 new folder, Tab other pane,
/// ⇧⌘. hidden files, ⇧⌘G go to folder; ⌘C / ⌘V / ⌥⌘V copy, paste, move here.
@MainActor
final class FilesTableView: NSTableView, NSMenuItemValidation {
    weak var pane: FilesPane?
    /// Set while Rename starts editing a name (clicks never do).
    var renaming = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { pane?.onFocus?() }
        return accepted
    }

    /// Names are edited only through Rename (F2, menu), never by clicking a selected row (double-click opens).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextField, !renaming { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let pane else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (36, []), (76, []), (125, [.command]): pane.openSelection()
        case (126, [.command]): pane.goUp()
        case (49, []): pane.previewSelection()
        case (51, [.command]): pane.moveToTrash()
        case (120, []): pane.renameSelection()
        case (96, []): pane.copyToOtherPane()
        case (97, []): pane.moveToOtherPane()
        case (98, []): pane.newFolder()
        case (48, []): pane.focusOtherPane()
        case (47, [.command, .shift]): pane.toggleHiddenFiles()
        case (5, [.command, .shift]): pane.goToFolder()
        case (9, [.command, .option]): pane.paste(move: true)
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pane else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return pane.contextMenu()
    }

    @objc func copy(_ sender: Any?) { pane?.copyToPasteboard() }
    @objc func paste(_ sender: Any?) { pane?.paste(move: false) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selectedRow >= 0
        case #selector(paste(_:)): return FilesPane.fileURLs(.general)?.isEmpty == false
        default: return true
        }
    }
}
