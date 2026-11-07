import AppKit
import CmdsCore
import os
import UserNotifications

private let editLog = Logger(subsystem: "tokyo.n-n.cmds", category: "remote-edit")

/// One server file being edited in an app on this Mac.
@MainActor
final class RemoteEditSession {
    let host: String
    /// The server's file, absolute with links resolved. After Save Mine as a Copy, the copy's path (later saves go
    /// there).
    var remotePath: String
    /// The editable copy on this Mac, in a folder of its own (`folder`).
    let copy: URL
    let folder: URL
    /// The server's file as last downloaded or uploaded.
    var version: RemoteFileVersion
    /// Hash of the content the server has (last downloaded or uploaded): the copy is uploaded only when it differs.
    var syncedHash: String
    var uploads = RemoteEditUploads()
    var watcher: FileWatcher?
    var timer: DispatchWorkItem?
    /// The upload running for `uploads` (its job id), and every save job this edit started (a retried one may finish
    /// later).
    var runningJob: Int?
    var jobs = Set<Int>()
    /// The last upload failed or stopped at a conflict: the copy holds changes the server does not have.
    var notUploaded = false
    weak var pane: FilesPane?

    init(host: String, remotePath: String, copy: URL, version: RemoteFileVersion, syncedHash: String, pane: FilesPane) {
        self.host = host
        self.remotePath = remotePath
        self.copy = copy
        folder = copy.deletingLastPathComponent()
        self.version = version
        self.syncedHash = syncedHash
        self.pane = pane
    }

    var name: String { RemotePath.name(remotePath) }

    /// The copy may hold changes the server does not have (pending, running or failed upload, or written since).
    var hasChangesNotUploaded: Bool {
        uploads.isBusy || notUploaded || ContentHash.ofFile(copy.path).map { $0 != syncedHash } ?? false
    }
}

/// Editing files of SSH hosts (docs/guide/files.md "Editing files on a server"): Edit (F4) in a remote files pane
/// downloads the file into an editable copy in a folder of its own, opens it in its default app and watches it; each
/// save is uploaded over the server's file by a `.save` job of the transfer queue (Window › Transfers lists it), after
/// `RemoteEditUploads.debounce` seconds without further writes, one upload at a time. A change made on the server
/// meanwhile is asked (Keep Mine / Keep Theirs / Save Mine as a Copy / Cancel). Editing ends with Stop Editing, when
/// its pane closes (after uploading what is pending) and when cmds quits. Copies are removed when their edit ends with
/// everything uploaded; a copy holding changes the server does not have is kept (quitting warns first).
@MainActor
final class RemoteEdits {
    static let shared = RemoteEdits()

    private(set) var sessions: [RemoteEditSession] = []
    private var finishObserver: NSObjectProtocol?

    private init() {
        finishObserver = NotificationCenter.default.addObserver(forName: .transferDidFinish, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let job = note.userInfo?["job"] as? TransferJob.Snapshot, job.mode == .save else { return }
                self?.saveFinished(job)
            }
        }
    }

    /// Where the editable copies are: `remote-edits` in cmds' cache folder (the support folder of isolated instances).
    nonisolated static var base: URL { FilesPane.cacheBase(cache: "remote-edits", isolated: "remote-edits") }

    func session(host: String, path: String) -> RemoteEditSession? {
        sessions.first { $0.host == host && $0.remotePath == path }
    }

    func sessions(of pane: FilesPane) -> [RemoteEditSession] {
        sessions.filter { $0.pane === pane }
    }

    // MARK: - Start

    /// Starts editing `path` on `host` (or opens the copy again when it is already being edited): downloads it, then
    /// opens the copy in its default app (unless `open` is false: tests).
    func edit(host: String, path: String, from pane: FilesPane, open: Bool = true) {
        if let existing = session(host: host, path: path) {
            if open { openCopy(existing) }
            return
        }
        let name = RemotePath.name(path)
        let folder = Self.base.appendingPathComponent("\(FilesPane.safeName(host))-\(UUID().uuidString.prefix(8))",
                                                      isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        let result = Downloaded()
        pane.onServer(String(localized: "Downloading “\(name)” for editing…"), { tree in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                result.value = try RemoteFileCopy.download(path, from: tree, to: copy.path)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }, completion: { [weak self, weak pane] error in
            guard let self else { return }
            guard let downloaded = result.value, error == nil else {
                pane?.showError(String(localized: "Could not download “\(name)” for editing."),
                                detail: error.map(FilesPane.remoteErrorText))
                return
            }
            // The same file under another name (a link): edit the copy that is already open.
            if let existing = self.session(host: host, path: downloaded.path) {
                try? FileManager.default.removeItem(at: folder)
                if open { self.openCopy(existing) }
                return
            }
            guard let pane else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            let session = RemoteEditSession(host: host, remotePath: downloaded.path, copy: copy,
                                            version: downloaded.version, syncedHash: downloaded.contentHash, pane: pane)
            self.sessions.append(session)
            session.watcher = FileWatcher(path: copy.path) { [weak self, weak session] in
                guard let self, let session else { return }
                self.handle(session, .changed)
            }
            editLog.notice("editing \(host, privacy: .public):\(downloaded.path, privacy: .private)")
            pane.editsChanged()
            if open { self.openCopy(session) }
        })
    }

    private final class Downloaded: @unchecked Sendable {
        var value: RemoteFileCopy.Downloaded?
    }

    private func openCopy(_ session: RemoteEditSession) {
        guard !NSWorkspace.shared.open(session.copy) else { return }
        session.pane?.showError(String(localized: "No app could open “\(session.name)”."),
                                detail: String(localized: "The copy is at \(session.copy.path)."))
    }

    // MARK: - End

    /// Stop Editing: uploads what is pending, then stops watching and removes the copy (kept when it holds changes
    /// that could not be uploaded).
    func end(_ session: RemoteEditSession) {
        handle(session, .end)
    }

    /// The pane closed: its edits end (pending uploads still run; a change on the server is then asked in the
    /// Transfers window).
    func paneClosed(_ pane: FilesPane) {
        for session in sessions(of: pane) { end(session) }
    }

    /// Quitting: names of the edits whose copies hold changes the server does not have.
    var namesNotUploaded: [String] {
        sessions.filter(\.hasChangesNotUploaded).map(\.name)
    }

    /// Quit: stop watching; remove the copies that hold nothing the server lacks, keep the others.
    func shutdown() {
        sessions.forEach(release)
        sessions.removeAll()
    }

    private func finish(_ session: RemoteEditSession) {
        release(session)
        sessions.removeAll { $0 === session }
        session.pane?.editsChanged()
    }

    /// Stops watching the copy and removes its folder, unless it holds changes the server does not have.
    private func release(_ session: RemoteEditSession) {
        session.timer?.cancel()
        session.watcher?.cancel()
        session.watcher = nil
        if session.hasChangesNotUploaded {
            editLog.notice("keeping the edited copy \(session.copy.path, privacy: .private): not uploaded")
        } else {
            try? FileManager.default.removeItem(at: session.folder)
        }
    }

    // MARK: - Uploads

    private func handle(_ session: RemoteEditSession, _ event: RemoteEditUploads.Event) {
        for action in session.uploads.handle(event) {
            switch action {
            case .startTimer:
                session.timer?.cancel()
                let item = DispatchWorkItem { [weak self, weak session] in
                    MainActor.assumeIsolated {
                        guard let self, let session else { return }
                        self.handle(session, .timerFired)
                    }
                }
                session.timer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + RemoteEditUploads.debounce, execute: item)
            case .cancelTimer:
                session.timer?.cancel()
                session.timer = nil
            case .upload:
                upload(session)
            case .finish:
                finish(session)
            }
        }
    }

    /// Starts a save job when the copy differs from what the server has (hashed off the main thread).
    private func upload(_ session: RemoteEditSession) {
        let path = session.copy.path
        DispatchQueue.global(qos: .userInitiated).async {
            let hash = ContentHash.ofFile(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    // Gone (the editor moved it away) or unchanged: nothing to upload.
                    guard let hash, hash != session.syncedHash else {
                        if hash != nil { session.notUploaded = false }
                        return self.handle(session, .uploadFinished)
                    }
                    let job = TransferCenter.shared.startSave(copy: path, host: session.host, path: session.remotePath,
                                                              base: session.version, from: session.pane)
                    session.runningJob = job.id
                    session.jobs.insert(job.id)
                    session.pane?.showSave(job.id)
                }
            }
        }
    }

    private func saveFinished(_ job: TransferJob.Snapshot) {
        guard let session = sessions.first(where: { $0.jobs.contains(job.id) }) else { return }
        if let saved = job.saved, job.state == .done {
            session.version = saved.version
            session.syncedHash = saved.contentHash
            session.notUploaded = false
            if !saved.keptTheirs {
                session.remotePath = RemotePath.join(RemotePath.parent(session.remotePath), saved.name)
            }
        } else {
            session.notUploaded = true
            if job.state == .failed { notifyFailure(session, job) }
        }
        if session.runningJob == job.id {
            session.runningJob = nil
            handle(session, .uploadFinished)
        } else if job.state == .done {
            // A retried upload finished later: upload the copy again if it changed since.
            handle(session, .changed)
        }
    }

    private func notifyFailure(_ session: RemoteEditSession, _ job: TransferJob.Snapshot) {
        let reasons = job.log.compactMap { entry -> String? in
            if case .failed(let reason) = entry.outcome { return reason.localizedText }
            return nil
        } + (job.error.map { [$0.localizedText] } ?? [])
        let title = String(localized: "Could not upload “\(session.name)” to \(session.host).")
        let detail = reasons.joined(separator: "\n") + "\n\n"
            + String(localized: "Your changes stay in the edited copy. Save it again, or retry in Window › Transfers.")
        if !NSApp.isActive { Self.postNotice(title: title, body: reasons.first ?? "") }
        if let pane = session.pane, pane.window != nil {
            pane.showError(title, detail: detail)
        }
    }

    /// A banner (cmds is usually in the background while a file is edited in another app).
    static func postNotice(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "cmds.remote-edit.\(UUID().uuidString)", content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
