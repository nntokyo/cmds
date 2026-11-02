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
        var target = path
        if target.isEmpty || target == "~" {
            target = tree.home
        } else if target.hasPrefix("~/") {
            target = RemotePath.join(tree.home, String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = RemotePath.join(tree.home, target)
        }
        var folder = try client.realpath(target)
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
            if case .disconnected(let reason) = error {
                return String(localized: "The connection to the server was closed: \(reason)")
            }
            return error.description
        }
        return "\(error)"
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
        let base: URL
        if let isolated = CmdsEnv.supportDirectoryOverride() {
            base = URL(fileURLWithPath: isolated).appendingPathComponent("remote-cache", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tokyo.n-n.cmds/remote-files", isDirectory: true)
        }
        let digest = SHA256.hash(data: Data("\(host):\(folder)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let safeHost = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent("\(safeHost)-\(digest)", isDirectory: true)
    }

    /// Downloads one file into the cache (a fresh copy each time), then calls `then` with its local path.
    func downloadForViewing(_ entry: FileEntry, then: @escaping @MainActor (String) -> Void) {
        guard let host else { return }
        let source = remotePath(entry)
        let cache = Self.remoteCacheFolder(host: host, folder: folder)
        let target = cache.appendingPathComponent(entry.name).path
        onServer(String(localized: "Downloading “\(entry.name)”…"), { tree in
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let part = cache.appendingPathComponent(TransferNames.part(for: entry.name)).path
            let local = LocalFileTree()
            let reader = try tree.openForReading(source)
            defer { reader.close() }
            let writer = try local.createFile(part, permissions: 0o600)
            do {
                while true {
                    let chunk = try reader.read()
                    if chunk.isEmpty { break }
                    try writer.write(chunk)
                }
                try writer.finish()
            } catch {
                writer.abandon()
                try? local.removePart(part)
                throw error
            }
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
        if job.state == .failed {
            let failures = job.log.filter { $0.outcome.isFailure }
            let lines = failures.prefix(8).map { "\($0.path): \($0.outcome.localizedText)" }
                + (job.error.map { [$0] } ?? [])
            let more = failures.count > 8 ? "\n" + String(localized: "and \(failures.count - 8) more") : ""
            if startedTransfers.contains(job.id) {
                showError(String(localized: "Some items could not be copied or moved."),
                          detail: lines.joined(separator: "\n") + more + "\n\n"
                              + String(localized: "Retry it in Window › Transfers."))
            }
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
