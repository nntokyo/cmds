import AppKit
import CmdsCore
import CryptoKit
import UniformTypeIdentifiers

/// Remote files panes (docs/guide/files.md "Folders on SSH hosts"): listing over SFTP off the main thread, the
/// commands that work on the server (rename, new folder, the server's Trash, open / preview through a downloaded
/// copy), and transfers through the queue for anything that crosses between this Mac and a host or two hosts.
extension FilesPane {
    struct RemoteListing: Sendable {
        /// Absolute (resolved by the server).
        var folder: String
        var entries: [FileEntry]
        /// The path named a file: its folder is listed with it selected.
        var select: String?
    }

    // MARK: - Listing

    func loadRemote() {
        guard let host else { return }
        let token = nextGeneration()
        let path = folder
        if allEntries.isEmpty, loadError == nil {
            statusLabel.stringValue = String(localized: "Connecting to \(host)…")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.readRemote(host: host, path: path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.applyRemote(result)
                }
            }
        }
    }

    private func applyRemote(_ result: Result<RemoteListing, Error>) {
        switch result {
        case .success(let listing):
            connectionError = nil
            setResolvedFolder(listing.folder)
            if let name = listing.select { pendingSelection = [name] }
            apply(.success(listing.entries))
        case .failure(let error):
            let message = Self.remoteErrorText(error)
            connectionError = Self.isConnectionError(error) ? message : nil
            loadError = message
            allEntries = []
            applyRows(keepSelection: false)
        }
    }

    /// Resolves `path` on the server (`~`, `~/…`, relative to home, `..`), then lists it. Blocks; never on main.
    nonisolated static func readRemote(host: String, path: String) throws -> RemoteListing {
        let tree = try RemoteConnections.shared.tree(host: host)
        let client = tree.client
        var folder = try client.realpath(RemotePath.absolute(path, home: tree.home))
        var select: String?
        if try client.stat(folder).fileType != .folder {
            select = RemotePath.name(folder)
            folder = RemotePath.parent(folder)
        }
        // Names with `/`, `.`, `..` or NUL from the server are left out (they would escape a folder on the Mac).
        let entries = try client.list(folder).filter { FileNames.isValid($0.name) }.map { item -> FileEntry in
            var isFolder = item.attributes.fileType == .folder
            if item.attributes.fileType == .symlink {
                // A link to a folder opens like a folder.
                isFolder = (try? client.stat(RemotePath.join(folder, item.name)).fileType) == .folder
            }
            return FileEntry(name: item.name, isFolder: isFolder, isHidden: item.name.hasPrefix("."),
                             size: isFolder ? nil : Int64(item.attributes.size ?? 0), modified: item.attributes.modified,
                             kind: kindDescription(name: item.name, isFolder: isFolder))
        }
        return RemoteListing(folder: folder, entries: entries, select: select)
    }

    nonisolated static func kindDescription(name: String, isFolder: Bool) -> String {
        if isFolder { return UTType.folder.localizedDescription ?? "Folder" }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return UTType.data.localizedDescription ?? "Document"
        }
        return type.localizedDescription ?? ext
    }

    /// The icon of a remote row (by type; the file is not on this Mac).
    func remoteIcon(_ entry: FileEntry) -> NSImage {
        if entry.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (entry.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    nonisolated static func isConnectionError(_ error: Error) -> Bool {
        if error is SSHConnectError { return true }
        if case .disconnected? = error as? SFTPError { return true }
        return false
    }

    /// What the user reads when a remote operation fails.
    nonisolated static func remoteErrorText(_ error: Error) -> String {
        if let error = error as? SSHConnectError { return error.failure.localizedText }
        if let error = error as? SFTPError {
            switch error.statusCode {
            case .noSuchFile: return String(localized: "No such file or folder on the server.")
            case .permissionDenied: return String(localized: "Permission denied on the server.")
            default: break
            }
            switch error {
            case .disconnected(let reason):
                // ssh's failure, classified, in the app's words; ssh's own last line as it came.
                let text = SSHFailure(description: reason)?.localizedText ?? reason
                return String(localized: "The connection to the server was closed: \(text)")
            case .protocolError(let message):
                return String(localized: "SFTP protocol error: \(message)")
            case .status(let code, let message):
                // The server's own message, else the app's text for the code.
                if !message.isEmpty, message.lowercased() != "failure" { return message }
                switch SFTP.StatusCode(rawValue: code) {
                case .unsupported: return String(localized: "Not supported by the server.")
                case .eof: return String(localized: "End of file.")
                default: return String(localized: "The server reported a failure.")
                }
            }
        }
        if let failure = error as? TransferFailure { return failure.localizedText }
        return TransferFailure(error).localizedText
    }

    // MARK: - Running work on the server

    /// Runs `work` with the host's tree off the main thread, showing `activity` in the status line, then `completion`
    /// on main with the error, if any.
    func onServer(_ activity: String?, _ work: @escaping @Sendable (SFTPFileTree) throws -> Void,
                  completion: @escaping @MainActor (Error?) -> Void) {
        guard let host else { return }
        remoteActivity = activity
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try work(try RemoteConnections.shared.tree(host: host))
            } catch {
                failure = error
            }
            let reported = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.remoteActivity = nil
                    self.updateStatus()
                    completion(reported)
                }
            }
        }
    }

    func remotePath(_ entry: FileEntry) -> String { RemotePath.join(folder, entry.name) }

    // MARK: - Commands

    /// Opens files through a downloaded copy (read only, in the cache), in their default app.
    func openRemoteFiles(_ entries: [FileEntry]) {
        for entry in entries where !entry.isFolder {
            downloadForViewing(entry) { path in NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }

    func previewRemote(_ entry: FileEntry) {
        downloadForViewing(entry) { [weak self] path in self?.onPreview?(path) }
    }

    /// The cache folder for copies of remote files opened or previewed (in the support folder for isolated instances).
    nonisolated static func remoteCacheFolder(host: String, folder: String) -> URL {
        let base = cacheBase(cache: "remote-files", isolated: "remote-cache")
        let digest = SHA256.hash(data: Data("\(host):\(folder)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("\(safeName(host))-\(digest)", isDirectory: true)
    }

    /// `name` in cmds' cache folder, or `isolated` in the support folder of an isolated instance.
    nonisolated static func cacheBase(cache name: String, isolated: String) -> URL {
        if let support = CmdsEnv.supportDirectoryOverride() {
            return URL(fileURLWithPath: support).appendingPathComponent(isolated, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tokyo.n-n.cmds/\(name)", isDirectory: true)
    }

    /// A host as part of a folder name.
    nonisolated static func safeName(_ host: String) -> String {
        String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    /// Downloads one file into the cache (a fresh copy each time), then calls `then` with its local path.
    func downloadForViewing(_ entry: FileEntry, then: @escaping @MainActor (String) -> Void) {
        guard let host else { return }
        let source = remotePath(entry)
        let cache = Self.remoteCacheFolder(host: host, folder: folder)
        let target = cache.appendingPathComponent(entry.name).path
        onServer(String(localized: "Downloading “\(entry.name)”…"), { tree in
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let part = try RemoteFileCopy.downloadToPart(source, from: tree, nextTo: target).part
            // The previous copy is ours (the cache), never the user's file.
            try? FileManager.default.removeItem(atPath: target)
            try FileManager.default.moveItem(atPath: part, toPath: target)
            // Read only: it is a copy; editing it does not change the server's file.
            chmod(target, 0o444)
        }, completion: { [weak self] error in
            if let error {
                self?.showError(String(localized: "Could not download “\(entry.name)”."), detail: Self.remoteErrorText(error))
            } else {
                then(target)
            }
        })
    }

    // MARK: - Editing (RemoteEdits)

    /// F4 / Edit: each selected file is downloaded into an editable copy, opened in its default app, and uploaded
    /// whenever it is saved.
    func editRemoteFiles(_ entries: [FileEntry], open: Bool = true) {
        guard let host else { return }
        for entry in entries where !entry.isFolder {
            RemoteEdits.shared.edit(host: host, path: remotePath(entry), from: self, open: open)
        }
    }

    /// The edits of these files (by any pane), if any.
    func editSessions(for entries: [FileEntry]) -> [RemoteEditSession] {
        guard let host else { return [] }
        let paths = Set(entries.map(remotePath))
        return RemoteEdits.shared.sessions.filter { $0.host == host && paths.contains($0.remotePath) }
    }

    /// Edits started or ended: the footer counts them.
    func editsChanged() { updateStatus() }

    /// The footer follows an upload of an edited file like a transfer this pane started.
    func showSave(_ jobID: Int) {
        startedTransfers.insert(jobID)
        updateStatus()
    }

    /// " — editing 2 files" for the footer.
    var editingSuffix: String {
        let count = RemoteEdits.shared.sessions(of: self).count
        return count == 0 ? "" : " — " + String(localized: "\(count) being edited")
    }

    /// An edited file changed on the server since it was downloaded or last uploaded.
    func askSaveConflict(name: String, reply: @escaping @Sendable (FileOperation.Resolution, Bool) -> Void) {
        #if DEBUG
        if let answer = debugConflictAnswer { return reply(answer, false) }
        #endif
        let alert = Self.saveConflictAlert(name: name)
        present(alert) { response in reply(Self.saveResolution(for: response), false) }
    }

    /// Keep Mine / Keep Theirs / Save Mine as a Copy / Cancel.
    static func saveConflictAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” has changed on the server since you downloaded or last uploaded it.")
        alert.informativeText = String(localized: "Keep Mine uploads your version over it. Keep Theirs replaces your edited copy with the server's version. Save Mine as a Copy uploads your version under a numbered name, and later saves go there. Cancel uploads nothing now; saving again asks again.")
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: String(localized: "Keep Theirs"))
        alert.addButton(withTitle: String(localized: "Save Mine as a Copy"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    /// The save's answer as a transfer resolution: Replace keeps mine, Skip keeps theirs, Keep Both saves a copy.
    static func saveResolution(for response: NSApplication.ModalResponse) -> FileOperation.Resolution {
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .keepBoth
        default: return .stop
        }
    }

    func renameRemote(_ entry: FileEntry, to newName: String) {
        let source = remotePath(entry)
        let target = RemotePath.join(folder, newName)
        onServer(nil, { tree in
            if tree.exists(target) { throw FileTreeError(String(localized: "“\(newName)” already exists in this folder.")) }
            try tree.rename(source, to: target)
        }, completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.showError(String(localized: "Could not rename “\(entry.name)”."), detail: Self.remoteErrorText(error))
            } else {
                self.pendingSelection = [newName]
            }
            self.load()
        })
    }

    func newRemoteFolder() {
        let base = String(localized: "untitled folder")
        let parent = folder
        let names = Set(allEntries.map(\.name))
        let name = names.contains(base) ? FileNames.keepBoth(base, isFolder: true) { names.contains($0) } : base
        onServer(nil, { tree in
            try tree.makeFolder(RemotePath.join(parent, name), permissions: nil)
        }, completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.showError(String(localized: "Could not create a folder here."), detail: Self.remoteErrorText(error))
            } else {
                self.pendingSelection = [name]
                self.pendingRename = name
            }
            self.load()
        })
    }

    /// To the server's Trash (`~/.local/share/Trash`); never deleted.
    func trashRemote(_ entries: [FileEntry]) {
        let paths = entries.map(remotePath)
        let next = FileSelection.afterRemoving(Set(entries.map(\.name)), from: rows.map(\.name))
        onServer(String(localized: "Moving to the server's Trash…"), { tree in
            var failures: [String] = []
            for path in paths {
                do {
                    try tree.trash(path)
                } catch {
                    failures.append("\(RemotePath.name(path)): \(Self.remoteErrorText(error))")
                }
            }
            if !failures.isEmpty { throw FileTreeError(failures.joined(separator: "\n")) }
        }, completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.showError(String(localized: "Could not move to the server's Trash. Nothing was deleted."),
                               detail: Self.remoteErrorText(error))
            }
            self.pendingSelection = next.map { [$0] } ?? []
            self.load()
        })
    }

    // MARK: - Transfers

    /// Queues a copy or move that involves a server; its progress shows in this pane's footer and in Window ›
    /// Transfers.
    func startTransfer(_ mode: TransferJob.Mode, sources: [FileLocation], destination: FileLocation) {
        let job = TransferCenter.shared.start(mode, sources: sources, destination: destination, from: self)
        startedTransfers.insert(job.id)
        updateStatus()
    }

    /// Follows the queue: the footer shows this pane's running job, and finished jobs that touched the shown folder
    /// list it again.
    func observeTransfers() {
        guard transferObservers.isEmpty else { return }
        let center = NotificationCenter.default
        transferObservers = [
            center.addObserver(forName: .transfersDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatus() }
            },
            center.addObserver(forName: .transferDidFinish, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let job = note.userInfo?["job"] as? TransferJob.Snapshot else { return }
                    self.transferFinished(job)
                }
            },
        ]
    }

    private func transferFinished(_ job: TransferJob.Snapshot) {
        let shown = location
        let touched = job.destination == shown || job.sources.contains { $0.parent == shown }
        // Local folders are watched; remote ones are listed again here.
        if touched, isRemote {
            if job.destination == shown {
                let names = job.log.compactMap { entry -> String? in
                    guard !entry.path.contains("/") else { return nil }
                    switch entry.outcome {
                    case .copied, .moved, .replaced, .merged: return entry.path
                    case .keptBoth(let name): return name
                    default: return nil
                    }
                }
                if !names.isEmpty { pendingSelection = names }
            }
            load()
        }
        updateStatus()
        // A failed upload of an edited file is reported by RemoteEdits.
        if job.state == .failed, job.mode != .save, startedTransfers.contains(job.id) {
            let failures = job.log.filter { $0.outcome.isFailure }.map { "\($0.path): \($0.outcome.localizedText)" }
            showError(String(localized: "Some items could not be copied or moved."),
                      detail: Self.failureList(failures, extra: job.error.map { [$0.localizedText] } ?? []) + "\n\n"
                          + String(localized: "Retry it in Window › Transfers."))
        }
    }

    /// The running job this pane started (footer), if any.
    var activeTransfer: TransferJob.Snapshot? {
        guard !startedTransfers.isEmpty else { return nil }
        return TransferCenter.shared.queue.snapshots.first { startedTransfers.contains($0.id) && !$0.state.isFinished }
    }

    /// Footer text and progress of the running job; true when there is one.
    func showActiveTransfer() -> Bool {
        guard let job = activeTransfer else {
            progressIndicator.isHidden = true
            cancelButton.isHidden = true
            return false
        }
        statusLabel.stringValue = job.localizedTitle + " — " + job.localizedStatus(bytes: byteFormatter)
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = job.progress.bytesTotal > 0
            ? Double(job.progress.bytesDone) / Double(job.progress.bytesTotal) : 0
        cancelButton.isHidden = false
        return true
    }

    /// Items on the pasteboard or in a drag: remote rows (`remoteFileType`) or files on this Mac.
    static func locations(_ pasteboard: NSPasteboard) -> [FileLocation]? {
        let remote = (pasteboard.pasteboardItems ?? []).compactMap { item -> FileLocation? in
            guard let text = item.string(forType: remoteFileType), let location = try? FileLocation.parse(text),
                  location.isRemote else { return nil }
            return location
        }
        if !remote.isEmpty { return remote }
        return fileURLs(pasteboard)?.map { .local($0.path) }
    }

    /// Pasteboard type of a remote row (`host:/path`); other apps get the same text as a string.
    static let remoteFileType = NSPasteboard.PasteboardType("tokyo.n-n.cmds.remote-file")

    func pasteboardItem(for entry: FileEntry) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let text = location(of: entry).description
        item.setString(text, forType: Self.remoteFileType)
        item.setString(text, forType: .string)
        return item
    }
}

extension SSHFailure {
    /// The app's text for each failure (`description` stays English for the API and logs).
    var localizedText: String {
        switch self {
        case .authentication:
            return String(localized: "The server did not accept your SSH keys or agent. cmds never asks for passwords: add a key for this host (e.g. ssh-copy-id), or add a key with a passphrase to the agent (ssh-add).")
        case .unknownHostKey:
            return String(localized: "This server's host key is not known yet. Connect to it once in an SSH workspace or a terminal to check and accept the key; cmds never adds host keys by itself.")
        case .changedHostKey:
            return String(localized: "This server's host key has changed since it was saved in known_hosts. Someone may be intercepting the connection; check the key before connecting again.")
        case .unresolvedHost: return String(localized: "The host name could not be resolved.")
        case .refused: return String(localized: "The server refused the connection.")
        case .timedOut: return String(localized: "The connection timed out.")
        case .noSFTP: return String(localized: "The server does not offer SFTP.")
        case .other(let message): return message
        }
    }
}

extension TransferFailure {
    /// The app's text for each failure (`description` stays English for the API, CLI and logs). Only what a server
    /// or ssh said itself is shown as it came.
    nonisolated var localizedText: String {
        switch self {
        case .noSuchItem: return String(localized: "No such file or folder.")
        case .intoItself: return String(localized: "A folder cannot be copied or moved into itself.")
        case .replaceContainsSource: return String(localized: "The item to replace contains the item being moved.")
        case .existingNotTrashed(let reason):
            return String(localized: "The existing item could not be moved to the Trash: \(reason.localizedText)")
        case .appeared(let name, let reason):
            return String(localized: "“\(name)” appeared in the destination during the copy and was left as it is (\(reason.localizedText)).")
        case .trashItself:
            return String(localized: "The Trash itself, or a folder containing it, cannot be moved to the Trash.")
        case .alreadyInTrash: return String(localized: "This item is already in the Trash.")
        case .trashNotAFolder(let path): return String(localized: "“\(path)” is not a folder.")
        case .serverTrashFailed(let name, let reason):
            return String(localized: "Could not move “\(name)” to the server's Trash (\(reason.localizedText)). Nothing was deleted.")
        case .notAFile(let name):
            return String(localized: "“\(name)” on the server is not a file any more; nothing was uploaded.")
        case .sftp(let error): return FilesPane.remoteErrorText(error)
        case .connect(let failure): return failure.localizedText
        case .posix(let code, let name): return "\(Self.posixText(code)) (\(name))"
        case .system(_, let localized): return localized
        case .other(let text): return text
        }
    }

    /// The common `errno` values in the app's words; others as the system names them (English).
    private nonisolated static func posixText(_ code: Int32) -> String {
        switch code {
        case ENOENT: return String(localized: "No such file or folder.")
        case EACCES, EPERM: return String(localized: "Permission denied.")
        case ENOSPC, EDQUOT: return String(localized: "There is not enough space on the disk.")
        case EEXIST: return String(localized: "An item with this name already exists.")
        case EROFS: return String(localized: "The disk is read-only.")
        case ENAMETOOLONG: return String(localized: "The name is too long.")
        default: return String(cString: strerror(code))
        }
    }
}
