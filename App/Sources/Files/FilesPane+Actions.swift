import AppKit
import CmdsCore

/// Commands of a files pane: open, preview, rename, new folder, Move to Trash, copy and move (between panes, by
/// pasteboard, by drag and drop) with their progress and name conflicts, and the context menu. Remote panes run the
/// server's side of each command in FilesPane+Remote.swift.
extension FilesPane {
    // MARK: - Open

    /// Return / ⌘↓ / double-click: a folder opens in the pane, files open in their default app.
    @objc func openSelection() {
        let entries = targetEntries
        guard !entries.isEmpty else { return }
        if entries.count == 1, let entry = entries.first, entry.isFolder {
            navigate(to: isRemote ? remotePath(entry) : url(of: entry).path)
            return
        }
        if isRemote {
            guard entries.contains(where: { !$0.isFolder }) else { return NSSound.beep() }
            return openRemoteFiles(entries)
        }
        let files = entries.filter { !$0.isFolder }.map(url(of:))
        if files.isEmpty { return NSSound.beep() }
        files.forEach { NSWorkspace.shared.open($0) }
    }

    /// Double-click on a row (not on the header or below the rows).
    @objc func rowDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        openSelection()
    }

    @objc func openWithDefaultApp() {
        if isRemote { return openRemoteFiles(targetEntries) }
        let urls = targetEntries.map(url(of:))
        guard !urls.isEmpty else { return NSSound.beep() }
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    /// F4: edit the selected files. A server's file is downloaded into an editable copy, opened in its default app and
    /// uploaded when saved (RemoteEdits); a file on this Mac simply opens in its default app.
    @objc func editSelection() {
        let files = targetEntries.filter { !$0.isFolder }
        guard !files.isEmpty else { return NSSound.beep() }
        if isRemote { return editRemoteFiles(files) }
        files.map(url(of:)).forEach { NSWorkspace.shared.open($0) }
    }

    /// Ends the edits of the selected files: what is pending is uploaded, then the copy is no longer watched.
    @objc func stopEditing() {
        let sessions = editSessions(for: targetEntries)
        guard !sessions.isEmpty else { return NSSound.beep() }
        sessions.forEach(RemoteEdits.shared.end)
    }

    /// Space: the selected file in the workspace's preview pane (images, PDF, Markdown, diffs, Quick Look).
    @objc func previewSelection() {
        guard let entry = targetEntries.first(where: { !$0.isFolder }) else { return NSSound.beep() }
        if isRemote { return previewRemote(entry) }
        onPreview?(url(of: entry).path)
    }

    @objc func revealInFinder() {
        guard !isRemote else { return NSSound.beep() }
        let urls = targetEntries.map(url(of:))
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [folderURL] : urls)
    }

    @objc func copyPaths() {
        // Remote items as `host:/path`, as `cmds files` takes them.
        let paths = targetEntries.map { location(of: $0).description }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString((paths.isEmpty ? [location.description] : paths).joined(separator: "\n"), forType: .string)
    }

    /// The selected folder (one), else the shown folder, in a new terminal pane.
    @objc func openTerminalHere() {
        let entries = targetEntries
        if let host {
            let target = entries.count == 1 && entries[0].isFolder ? remotePath(entries[0]) : folder
            return onOpenSSHTerminal?(host, target) ?? ()
        }
        let target = entries.count == 1 && entries[0].isFolder ? url(of: entries[0]).path : folder
        onOpenTerminal?(target)
    }

    /// ⇧⌘G: type a path (absolute, `~/…`, or relative to the shown folder).
    @objc func goToFolder() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Folder")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = isRemote ? folder : folder.abbreviatingHome
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if self.isRemote {
                // Checked by the listing: a file is selected in its folder, a missing path shows an error.
                self.navigate(to: RemotePath.resolve(typed: field.stringValue, in: self.folder))
                return self.focus()
            }
            let path = FileNames.resolve(typed: field.stringValue, in: self.folder)
            if Self.isFolder(path) {
                self.navigate(to: path)
            } else if FileManager.default.fileExists(atPath: path) {
                self.navigate(to: (path as NSString).deletingLastPathComponent, select: [(path as NSString).lastPathComponent])
            } else {
                NSSound.beep()
            }
            self.focus()
        }
    }

    // MARK: - Rename, new folder, trash

    @objc func renameSelection() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 else { return NSSound.beep() }
        beginRename(row: row)
    }

    @objc func newFolder() {
        if isRemote { return newRemoteFolder() }
        let base = String(localized: "untitled folder")
        let taken = { (name: String) in FileOperation.exists(self.folderURL.appendingPathComponent(name)) }
        let name = taken(base) ? FileNames.keepBoth(base, isFolder: true, taken: taken) : base
        do {
            try FileManager.default.createDirectory(at: folderURL.appendingPathComponent(name), withIntermediateDirectories: false)
            pendingSelection = [name]
            pendingRename = name
            load()
        } catch {
            showError(String(localized: "Could not create a folder here."), detail: error.localizedDescription)
        }
    }

    /// ⌘⌫: to the Trash (never deleted for good; Put Back works from the Finder).
    @objc func moveToTrash() {
        let entries = targetEntries
        guard !entries.isEmpty else { return NSSound.beep() }
        if isRemote { return trashRemote(entries) }
        // Keep the keyboard near where the items were.
        let next = FileSelection.afterRemoving(Set(entries.map(\.name)), from: rows.map(\.name))
        NSWorkspace.shared.recycle(entries.map(url(of:))) { [weak self] _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.showError(String(localized: "Could not move to the Trash."), detail: error.localizedDescription)
                    }
                    self.pendingSelection = next.map { [$0] } ?? []
                    self.load()
                }
            }
        }
    }

    // MARK: - Copy and move

    @objc func copyToOtherPane() { transferToOtherPane(.copy) }
    @objc func moveToOtherPane() { transferToOtherPane(.move) }

    private func transferToOtherPane(_ mode: FileOperation.Mode) {
        let entries = targetEntries
        guard !entries.isEmpty else { return NSSound.beep() }
        guard let other = otherPane?() else {
            return showError(String(localized: "There is no other files pane in this workspace."),
                             detail: String(localized: "Open one with File › New Files Pane (⇧⌘E), then copy or move between the two."))
        }
        guard other.location != location else { return NSSound.beep() }
        if isRemote || other.isRemote {
            return startTransfer(mode == .move ? .move : .copy, sources: entries.map(location(of:)),
                                 destination: other.location)
        }
        startOperation(mode, sources: entries.map(url(of:)), destination: other.folderURL)
    }

    func focusOtherPane() {
        guard let other = otherPane?() else { return NSSound.beep() }
        other.focus()
    }

    /// ⌘C: the selected items as files on the pasteboard (paste them in the Finder or another files pane).
    func copyToPasteboard() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if isRemote {
            pasteboard.writeObjects(entries.map(pasteboardItem(for:)))
        } else {
            pasteboard.writeObjects(entries.map(url(of:)) as [NSURL])
        }
    }

    /// ⌘V copies the files on the pasteboard into the shown folder; ⌥⌘V moves them.
    func paste(move: Bool) {
        guard let sources = Self.locations(.general), !sources.isEmpty else { return NSSound.beep() }
        copyOrMoveHere(sources, move: move)
    }

    /// Copies or moves `sources` into the shown folder: through the transfer queue when a server is involved, else as
    /// a `FileOperation` with progress in the footer.
    func copyOrMoveHere(_ sources: [FileLocation], move: Bool) {
        if isRemote || sources.contains(where: \.isRemote) {
            return startTransfer(move ? .move : .copy, sources: sources, destination: location)
        }
        startOperation(move ? .move : .copy, sources: sources.map { URL(fileURLWithPath: $0.path) }, destination: folderURL)
    }

    /// Runs a copy or move with progress in this pane's footer. False when one is already running here.
    @discardableResult
    func startOperation(_ mode: FileOperation.Mode, sources: [URL], destination: URL) -> Bool {
        guard operation == nil else {
            NSSound.beep()
            return false
        }
        let operation = FileOperation(mode: mode, sources: sources, destination: destination)
        operation.onStatus = { [weak self] status in self?.show(status) }
        operation.onConflict = { [weak self] name, isFolder, reply in
            guard let self else { return reply(.skip, false) }
            self.askConflict(name: name, isFolder: isFolder, several: sources.count > 1, reply: reply)
        }
        operation.onFinish = { [weak self] created, failures, cancelled in
            self?.finish(created: created, failures: failures, cancelled: cancelled, destination: destination)
        }
        self.operation = operation
        progressIndicator.isHidden = false
        progressIndicator.doubleValue = 0
        cancelButton.isHidden = false
        operation.start()
        return true
    }

    @objc func cancelFileOperation(_ sender: Any?) {
        if let operation { return operation.cancel() }
        if let job = activeTransfer { try? TransferCenter.shared.cancel(id: job.id) }
    }

    private func show(_ status: FileOperation.Status) {
        guard operation != nil else { return }
        var text: String
        switch (status.mode, status.count > 1) {
        case (.copy, true): text = String(localized: "Copying \(status.index) of \(status.count): \(status.name)")
        case (.copy, false): text = String(localized: "Copying \(status.name)")
        case (.move, true): text = String(localized: "Moving \(status.index) of \(status.count): \(status.name)")
        case (.move, false): text = String(localized: "Moving \(status.name)")
        }
        progressIndicator.isIndeterminate = false
        if status.bytesTotal > 0 {
            text += " — " + String(localized: "\(byteFormatter.string(fromByteCount: status.bytesDone)) of \(byteFormatter.string(fromByteCount: status.bytesTotal))")
            progressIndicator.doubleValue = min(1, Double(status.bytesDone) / Double(status.bytesTotal))
        } else {
            progressIndicator.doubleValue = status.count > 0 ? Double(status.index - 1) / Double(status.count) : 0
        }
        statusLabel.stringValue = text
    }

    private func finish(created: [URL], failures: [FileOperation.Failure], cancelled: Bool, destination: URL) {
        operation = nil
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        updateStatus()
        let names = created.filter { FileNames.isSamePath($0.deletingLastPathComponent(), destination) }
            .map(\.lastPathComponent)
        if FileNames.isSamePath(destination, folderURL), !names.isEmpty {
            pendingSelection = names
            load()
        } else if let other = otherPane?(), FileNames.isSamePath(other.folderURL, destination), !names.isEmpty {
            other.pendingSelection = names
            other.load()
        }
        guard !failures.isEmpty else { return }
        showError(String(localized: "Some items could not be copied or moved."),
                  detail: Self.failureList(failures.map { "\($0.name): \(Self.text($0.reason))" }))
    }

    /// Failures named in the alert after a copy or move; the rest are counted.
    private static let failuresListed = 8

    /// The alert's lines for failed items: the first `failuresListed`, then `extra`, then how many more failed.
    static func failureList(_ lines: [String], extra: [String] = []) -> String {
        let shown = failuresListed
        let more = lines.count > shown ? "\n" + String(localized: "and \(lines.count - shown) more") : ""
        return (lines.prefix(shown) + extra).joined(separator: "\n") + more
    }

    private static func text(_ reason: FileOperation.Failure.Reason) -> String {
        switch reason {
        case .intoItself: return String(localized: "A folder cannot be copied or moved into itself.")
        case .replaceContainsSource: return String(localized: "The item to replace contains the item being moved.")
        case .error(let message): return message
        case .originalNotTrashed(let message):
            return String(localized: "Copied, but the original could not be moved to the Trash: \(message)")
        }
    }

    func askConflict(name: String, isFolder: Bool, several: Bool,
                     reply: @escaping @Sendable (FileOperation.Resolution, Bool) -> Void) {
        #if DEBUG
        if let answer = debugConflictAnswer { return reply(answer, true) }
        #endif
        let alert = Self.conflictAlert(name: name, isFolder: isFolder, several: several)
        present(alert) { response in
            reply(Self.resolution(for: response), alert.suppressionButton?.state == .on)
        }
    }

    /// Keep Both / Replace / Skip / Stop, with Apply to all when several items are copied.
    static func conflictAlert(name: String, isFolder: Bool, several: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = isFolder
            ? String(localized: "A folder named “\(name)” already exists in the destination.")
            : String(localized: "An item named “\(name)” already exists in the destination.")
        alert.informativeText = String(localized: "Replace moves the existing item to the Trash. Keep Both gives the new one a numbered name.")
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Stop"))
        if several {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to all")
        }
        return alert
    }

    static func resolution(for response: NSApplication.ModalResponse) -> FileOperation.Resolution {
        switch response {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return .stop
        }
    }

    // MARK: - Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let entries = targetEntries
        func add(_ title: String, _ action: Selector, enabled: Bool = true, checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        let hasFile = entries.contains { !$0.isFolder }
        if !entries.isEmpty {
            add(String(localized: "Open"), #selector(openSelection))
            add(String(localized: "Open in Default App"), #selector(openWithDefaultApp))
            add(String(localized: "Edit"), #selector(editSelection), enabled: hasFile)
            if !editSessions(for: entries).isEmpty {
                add(String(localized: "Stop Editing"), #selector(stopEditing))
            }
            add(String(localized: "Show in Preview Pane"), #selector(previewSelection), enabled: hasFile)
            menu.addItem(.separator())
            add(String(localized: "Copy to Other Pane"), #selector(copyToOtherPane))
            add(String(localized: "Move to Other Pane"), #selector(moveToOtherPane))
            add(String(localized: "Rename"), #selector(renameSelection), enabled: entries.count == 1)
            add(String(localized: "Move to Trash"), #selector(moveToTrash))
            menu.addItem(.separator())
            add(String(localized: "Copy Path"), #selector(copyPaths))
            add(String(localized: "Reveal in Finder"), #selector(revealInFinder), enabled: !isRemote)
            menu.addItem(.separator())
        }
        add(String(localized: "New Folder"), #selector(newFolder))
        add(isRemote ? String(localized: "Open SSH Terminal Here") : String(localized: "Open Terminal Here"),
            #selector(openTerminalHere))
        add(String(localized: "Show Hidden Files"), #selector(toggleHiddenFiles), checked: showHidden)
        if !isRemote {
            add(String(localized: "Follow Terminal"), #selector(toggleFollowTerminal), checked: followsTerminal)
        }
        return menu
    }

    // MARK: - Alerts

    func showError(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? ""
        present(alert) { _ in }
    }

    /// As a sheet on the window (modal when the pane is not in one).
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
