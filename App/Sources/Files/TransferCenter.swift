import AppKit
import CmdsCore
import os

let transferLog = Logger(subsystem: "tokyo.n-n.cmds", category: "transfers")

extension Notification.Name {
    /// The transfer queue changed (posted on main, throttled).
    static let transfersDidChange = Notification.Name("transfersDidChange")
    /// A transfer finished (`userInfo["job"]`: its `TransferJob.Snapshot`), posted on main: panes showing its folders
    /// list them again.
    static let transferDidFinish = Notification.Name("transferDidFinish")
}

/// The app's transfer queue (docs/guide/files.md "Transfers"): copies and moves that involve an SSH host. Jobs run on
/// their own threads (`TransferQueue`); conflicts are asked in the window of the files pane that started the job.
@MainActor
final class TransferCenter {
    static let shared = TransferCenter()

    let queue = TransferQueue()
    /// Answers name conflicts of jobs a pane started (the pane may be gone by then).
    private var askers: [Int: () -> FilesPane?] = [:]
    private var finishedReported = Set<Int>()

    private init() {
        let queue = queue
        // Hosts with a job that is not finished keep their connections open.
        RemoteConnections.shared.busyHosts = {
            var hosts = Set<String>()
            for job in queue.snapshots where !job.state.isFinished {
                for location in job.sources + [job.destination] {
                    if let host = location.host { hosts.insert(host) }
                }
            }
            return hosts
        }
        queue.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.queueChanged() }
        }
    }

    /// The part files transfers are writing (`transfer-parts.json` in the support folder). Ones an earlier run left
    /// (quit or crash mid-transfer) are removed at launch on this Mac (`removeLeftoverParts`) and when a host is
    /// connected (`RemoteConnections`).
    nonisolated static let partJournal = TransferPartJournal(url: TransferPartJournal.url())

    /// Launch: removes this Mac's part files left by an earlier run, off the main thread.
    nonisolated static func removeLeftoverParts() {
        DispatchQueue.global(qos: .utility).async {
            let removed = partJournal.clean(host: nil, tree: LocalFileTree())
            if removed > 0 { transferLog.notice("removed \(removed) leftover part files on this Mac") }
        }
    }

    /// Queues a copy or move; conflicts are asked in `pane`'s window.
    @discardableResult
    func start(_ mode: TransferJob.Mode, sources: [FileLocation], destination: FileLocation,
               from pane: FilesPane?) -> TransferJob {
        let job = TransferJob(id: queue.makeID(), mode: mode, sources: sources, destination: destination)
        job.tree = { location in try RemoteConnections.shared.tree(for: location) }
        job.partJournal = Self.partJournal
        askers[job.id] = { [weak pane] in pane }
        let id = job.id
        job.onConflict = { name, isFolder, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    TransferCenter.shared.askConflict(jobID: id, name: name, isFolder: isFolder,
                                                      several: sources.count > 1, reply: reply)
                }
            }
        }
        queue.add(job)
        return job
    }

    private func askConflict(jobID: Int, name: String, isFolder: Bool, several: Bool,
                             reply: @escaping @Sendable (TransferJob.Resolution, Bool) -> Void) {
        if let pane = askers[jobID]?(), pane.window != nil {
            pane.askConflict(name: name, isFolder: isFolder, several: several, reply: reply)
            return
        }
        // The pane is gone: ask in the Transfers window.
        TransfersWindowController.shared.showWindow(nil)
        let alert = FilesPane.conflictAlert(name: name, isFolder: isFolder, several: several)
        if let window = TransfersWindowController.shared.window {
            alert.beginSheetModal(for: window) { response in
                reply(FilesPane.resolution(for: response), alert.suppressionButton?.state == .on)
            }
        } else {
            reply(.skip, false)
        }
    }

    func job(id: Int) throws -> TransferJob {
        guard let job = queue.job(id: id) else { throw RPCError.notFound("no transfer \(id)") }
        return job
    }

    func pause(id: Int) throws { try job(id: id).pause() }
    func resume(id: Int) throws { try job(id: id).resume() }
    func cancel(id: Int) throws { try job(id: id).cancel() }

    func retry(id: Int) throws {
        _ = try job(id: id)
        guard queue.retry(id: id) else { throw RPCError.invalidParams("transfer \(id) has not failed or been cancelled") }
        finishedReported.remove(id)
    }

    func clearFinished() {
        queue.clearFinished()
    }

    /// App quit: stop every job (each removes its own partial file when it gets to it) and close connections.
    func shutdown() {
        queue.cancelAll()
        RemoteConnections.shared.closeAll()
    }

    private func queueChanged() {
        let snapshots = queue.snapshots
        for snapshot in snapshots where snapshot.state.isFinished && !finishedReported.contains(snapshot.id) {
            finishedReported.insert(snapshot.id)
            askers[snapshot.id] = nil
            NotificationCenter.default.post(name: .transferDidFinish, object: self, userInfo: ["job": snapshot])
        }
        NotificationCenter.default.post(name: .transfersDidChange, object: self)
    }
}

// MARK: - Text

extension TransferJob.Snapshot {
    /// "Copying 3 items to host:/srv" (UI).
    var localizedTitle: String {
        let target = destination.isRemote ? destination.description : (destination.path as NSString).abbreviatingWithTildeInPath
        let what = sources.count == 1 ? "“\(sources[0].name)”" : String(localized: "\(sources.count) items")
        switch mode {
        case .copy: return String(localized: "Copy \(what) to \(target)")
        case .move: return String(localized: "Move \(what) to \(target)")
        }
    }

    /// Progress or result in one line (UI).
    func localizedStatus(bytes: ByteCountFormatter) -> String {
        let amount = progress.bytesTotal > 0
            ? String(localized: "\(bytes.string(fromByteCount: progress.bytesDone)) of \(bytes.string(fromByteCount: progress.bytesTotal))")
            : ""
        switch state {
        case .queued: return String(localized: "Waiting")
        case .running:
            if progress.counting { return String(localized: "Preparing…") }
            return [amount, progress.current ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
        case .paused: return amount.isEmpty ? String(localized: "Paused") : String(localized: "Paused — \(amount)")
        case .waiting: return String(localized: "Waiting for your answer about “\(asking ?? "")”")
        case .cancelled: return String(localized: "Cancelled")
        case .done:
            return summary.isEmpty ? String(localized: "Done") : String(localized: "Done — \(summary)")
        case .failed:
            if let error { return String(localized: "Failed: \(error.localizedText)") }
            return String(localized: "Failed — \(summary)")
        }
    }

    /// "3 copied, 1 skipped, 2 failed" (counts of the log, UI).
    var summary: String {
        let counts = counts
        var parts: [String] = []
        if counts.copied > 0 { parts.append(String(localized: "\(counts.copied) copied")) }
        if counts.moved > 0 { parts.append(String(localized: "\(counts.moved) moved")) }
        if counts.skipped > 0 { parts.append(String(localized: "\(counts.skipped) skipped")) }
        if counts.failed > 0 { parts.append(String(localized: "\(counts.failed) failed")) }
        return parts.joined(separator: ", ")
    }
}

extension TransferJob.Outcome {
    var localizedText: String {
        switch self {
        case .copied: return String(localized: "copied")
        case .moved: return String(localized: "moved")
        case .skipped: return String(localized: "skipped (the name is taken)")
        case .replaced: return String(localized: "replaced (the old item is in the Trash)")
        case .keptBoth(let name): return String(localized: "copied as “\(name)”")
        case .merged: return String(localized: "completed")
        case .originalKept(let reason): return String(localized: "copied, but the original could not be moved to the Trash: \(reason.localizedText)")
        case .notCopied: return String(localized: "not copied (special file)")
        case .failed(let reason): return String(localized: "failed: \(reason.localizedText)")
        }
    }
}
