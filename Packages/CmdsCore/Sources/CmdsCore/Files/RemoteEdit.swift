import CryptoKit
import Foundation

/// Editing a file of an SSH host in an app on this Mac (docs/guide/files.md "Editing files on a server"): the file is
/// downloaded to an editable copy, the copy is watched, and each save is uploaded over the server's file by a
/// `TransferJob` in `.save` mode. The pure parts live here: what the server's file was when it was last read or
/// written (`RemoteFileVersion`, to notice changes made on the server meanwhile) and when to upload
/// (`RemoteEditUploads`, debounced, one upload at a time).

/// The server's file as cmds last saw it (downloaded or uploaded): size and modification time, which SFTP v3 gives in
/// whole seconds.
public struct RemoteFileVersion: Equatable, Sendable {
    public var size: Int64
    public var modified: Date?

    public init(size: Int64, modified: Date?) {
        self.size = size
        self.modified = modified
    }

    public init(_ item: FileItem) {
        self.init(size: item.size, modified: item.modified)
    }

    /// What happened to the server's file since this version.
    public enum Change: Equatable, Sendable {
        /// Same size and time: nobody wrote it (as far as SFTP v3 can tell).
        case unchanged
        /// Written or replaced on the server (another size or time).
        case changed
        /// Nothing is there any more (deleted, renamed).
        case missing
        /// Something else is there now (a folder, a link).
        case notAFile
    }

    /// Compares with what is at the path now (`FileTree.item`, not following a link).
    public func change(to current: FileItem?) -> Change {
        guard let current else { return .missing }
        guard current.kind == .file else { return .notAFile }
        return current.size == size && current.modified == modified ? .unchanged : .changed
    }
}

/// The editable copy of a server's file.
public enum RemoteEditCopy {
    /// What `download` made.
    public struct Downloaded: Equatable, Sendable {
        /// The server's file, absolute with links resolved (saves go there, not over a link).
        public var path: String
        public var version: RemoteFileVersion
        public var contentHash: String
    }

    /// Downloads the server's file at `path` (a link is followed to its file) into `copy`, a new file on this Mac
    /// readable by this user only (written as a part file next to it, then renamed). Blocks; never on the main thread.
    public static func download(_ path: String, from tree: SFTPFileTree, to copy: String) throws -> Downloaded {
        let resolved = try tree.client.realpath(path)
        guard let item = try tree.item(at: resolved) else { throw TransferFailure.noSuchItem }
        guard item.kind == .file else { throw TransferFailure.notAFile(name: RemotePath.name(resolved)) }
        let local = LocalFileTree()
        let part = local.paths.join(local.paths.parent(copy), TransferNames.part(for: local.paths.name(copy)))
        let reader = try tree.openForReading(resolved)
        defer { reader.close() }
        let writer = try local.createFile(part, permissions: 0o600)
        var hash = ContentHash()
        do {
            while true {
                let chunk = try reader.read()
                if chunk.isEmpty { break }
                try writer.write(chunk)
                hash.update(chunk)
            }
            try writer.finish()
            try local.rename(part, to: copy)
        } catch {
            writer.abandon()
            try? local.removePart(part)
            throw error
        }
        return Downloaded(path: resolved, version: RemoteFileVersion(item), contentHash: hash.finalize())
    }
}

/// SHA-256 of a file's content in hex: whether an edited copy differs from what was last uploaded or downloaded
/// (an editor that saves without changing anything, or only touches the file, uploads nothing).
public struct ContentHash: Sendable {
    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ data: Data) { hasher.update(data: data) }

    public func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Of a file on this Mac (read in chunks); nil when it cannot be read.
    public static func ofFile(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = ContentHash()
        while true {
            // nil at the end of the file.
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: LocalFileTree.chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hash.update(chunk)
        }
        return hash.finalize()
    }
}

/// When an edited copy is uploaded: a change starts (or restarts) the debounce timer; when it fires, one upload runs;
/// changes during an upload make another one after it (again debounced). Ending the edit uploads what is pending first.
/// A value type with no clock or I/O, so every order of events is unit-tested; the app runs the actions.
public struct RemoteEditUploads: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing to do.
        case idle
        /// A change was seen; the timer runs.
        case waiting
        /// An upload is running; `dirty`: the copy changed again since it started.
        case uploading(dirty: Bool)
        /// Ended: nothing is watched or uploaded any more.
        case ended
    }

    public enum Event: Equatable, Sendable {
        /// The copy was written (the watcher fired).
        case changed
        /// The debounce timer fired.
        case timerFired
        /// The upload finished (also when there was nothing to upload, it failed or was stopped at a conflict).
        case uploadFinished
        /// The user ended the edit or its pane closed.
        case end
    }

    public enum Action: Equatable, Sendable {
        /// (Re)start the debounce timer.
        case startTimer
        case cancelTimer
        /// Upload the copy if it differs from what was last uploaded or downloaded.
        case upload
        /// Stop watching; the edit is over.
        case finish
    }

    /// Seconds without further changes before an upload starts (editors often write a file in several steps).
    public static let debounce: TimeInterval = 1

    public private(set) var phase: Phase = .idle
    /// End once the running or pending upload is done.
    public private(set) var ending = false

    public init() {}

    /// An upload is running or pending (the copy may hold changes the server does not have yet).
    public var isBusy: Bool {
        switch phase {
        case .waiting, .uploading: return true
        case .idle, .ended: return false
        }
    }

    public mutating func handle(_ event: Event) -> [Action] {
        switch (phase, event) {
        case (.ended, _):
            return []
        case (.idle, .changed), (.waiting, .changed):
            phase = .waiting
            return [.startTimer]
        case (.uploading, .changed):
            phase = .uploading(dirty: true)
            return []
        case (.waiting, .timerFired):
            phase = .uploading(dirty: false)
            return [.upload]
        case (_, .timerFired):
            // A timer that fired after it was cancelled.
            return []
        case (.uploading(let dirty), .uploadFinished):
            if dirty {
                // Changed again meanwhile: upload that too (now if ending, else after the debounce).
                if ending {
                    phase = .uploading(dirty: false)
                    return [.upload]
                }
                phase = .waiting
                return [.startTimer]
            }
            if ending {
                phase = .ended
                return [.finish]
            }
            phase = .idle
            return []
        case (_, .uploadFinished):
            return []
        case (.idle, .end):
            phase = .ended
            return [.finish]
        case (.waiting, .end):
            ending = true
            phase = .uploading(dirty: false)
            return [.cancelTimer, .upload]
        case (.uploading, .end):
            ending = true
            return []
        }
    }
}
