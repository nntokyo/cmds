import Darwin
import Foundation
import CmdsCore

/// A Codex process of our user found by `ProcessScanner`.
struct CodexProcess: Sendable {
    var pid: pid_t
    var started: Date
    /// Our pane running this session process; nil for shared services.
    var paneID: String?
    /// `codex app-server` daemon (or another server running sessions for clients).
    var isService: Bool
    var cwd: String?
    /// `rollout-*.jsonl` files it holds open.
    var rolloutFiles: [String]
}

/// Where a pane's `agentUsage` comes from.
enum AgentSource: Equatable {
    /// `agent.report` (Claude Code's status line). `process` is the reporting agent when known.
    case report(process: AgentProcessRef?)
    /// The session file of a Codex process running in the pane.
    case codexSession
}

/// A process identified across pid reuse (pid + start time).
struct AgentProcessRef: Equatable {
    var pid: pid_t
    /// `pbi_start_tvsec * 1e6 + pbi_start_tvusec`.
    var start: UInt64

    init?(pid: pid_t) {
        guard let start = Self.startTime(pid) else { return nil }
        self.pid = pid
        self.start = start
    }

    var isAlive: Bool { Self.startTime(pid) == start }

    /// Start time of a live (non-zombie) process.
    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != 5 /* SZOMB */ else {
            return nil
        }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }
}

/// What the Codex session files say, per pane.
struct CodexWatchResult: Sendable {
    /// Panes with a running Codex session process (whether or not its file is known yet).
    var panes: Set<String> = []
    /// Usage per pane, once its session file has a usage event.
    var usage: [String: AgentUsage] = [:]
    /// Newest account limits seen in those files.
    var limits: AgentLimits?
}

/// Follows the session files of the Codex processes in our panes (see `CodexSessionMatcher` for how files are
/// matched to panes when the Codex app-server daemon holds them). A file is read only when its size or mtime
/// changed, and only what was appended since the last read (at most the last 256 KB); the first line
/// (`session_meta`) is read once for its cwd. PRIVACY: only usage figures are parsed (`CodexRollout`); no content is
/// logged or kept. Not thread-safe: use from the metadata queue.
final class CodexSessionWatcher: @unchecked Sendable {
    static let tailBytes: UInt64 = 256 * 1024
    static let metaBytes = 256 * 1024

    private struct FileState {
        var inode: UInt64 = 0
        var size: UInt64 = 0
        var modified = Date.distantPast
        var birth: Date?
        /// Bytes consumed so far (a line boundary).
        var offset: UInt64 = 0
        var snapshot = CodexRollout.Snapshot()
        var meta: CodexRollout.SessionMeta?
        var metaRead = false
    }

    private var files: [String: FileState] = [:]

    func update(_ processes: [CodexProcess]) -> CodexWatchResult {
        var panes: [String: CodexSessionMatcher.Pane] = [:]
        for process in processes {
            guard let paneID = process.paneID else { continue }
            var pane = panes[paneID] ?? CodexSessionMatcher.Pane(paneID: paneID, started: process.started, cwd: nil)
            pane.started = min(pane.started, process.started)
            pane.cwd = pane.cwd ?? process.cwd
            pane.openFiles += process.rolloutFiles.filter { !pane.openFiles.contains($0) }
            panes[paneID] = pane
        }
        guard !panes.isEmpty else {
            files.removeAll()
            return CodexWatchResult()
        }
        let held = Set(panes.values.flatMap(\.openFiles))
        var shared = Set<String>()
        if panes.values.contains(where: { $0.openFiles.isEmpty }) {
            for process in processes where process.isService { shared.formUnion(process.rolloutFiles) }
            shared.subtract(held)
        }
        let directories = panes.values.filter { $0.openFiles.isEmpty }.map(\.cwd)

        var candidates: [CodexSessionMatcher.File] = []
        for path in held.union(shared) {
            guard var state = fileState(path: path) else { continue }
            if shared.contains(path) {
                if !state.metaRead { readMeta(path, into: &state) }
                // A daemon session in a directory no Codex pane is in: never read its contents.
                if !directories.contains(where: { CodexSessionMatcher.sameDirectory($0, state.meta?.cwd) }) {
                    files[path] = state
                    continue
                }
            }
            readAppended(path, into: &state)
            files[path] = state
            candidates.append(.init(path: path, cwd: state.meta?.cwd, created: state.meta?.timestamp ?? state.birth,
                                    modified: state.modified, hasUsage: state.snapshot.hasUsage))
        }
        let known = held.union(shared)
        files = files.filter { known.contains($0.key) }

        var result = CodexWatchResult(panes: Set(panes.keys))
        for (paneID, path) in CodexSessionMatcher.match(panes: Array(panes.values), files: candidates) {
            guard let state = files[path] else { continue }
            let id = CodexRollout.sessionID(fromPath: path) ?? state.meta?.id
            result.usage[paneID] = state.snapshot.usage(sessionID: id, fallbackDate: state.modified)
        }
        for candidate in candidates {
            guard let state = files[candidate.path],
                  let limits = state.snapshot.accountLimits(fallbackDate: state.modified) else { continue }
            if limits.updatedAt > (result.limits?.updatedAt ?? .distantPast) { result.limits = limits }
        }
        return result
    }

    /// Refreshes size/mtime/inode; a replaced or truncated file starts over.
    private func fileState(path: String) -> FileState? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var state = files[path] ?? FileState()
        let inode = UInt64(info.st_ino)
        let size = UInt64(max(0, info.st_size))
        if state.inode != inode || size < state.offset {
            state = FileState()
            state.inode = inode
        }
        state.size = size
        state.modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        state.birth = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
        return state
    }

    private func readMeta(_ path: String, into state: inout FileState) {
        state.metaRead = true
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.metaBytes), let newline = head.firstIndex(of: 0x0A) else { return }
        state.meta = CodexRollout.sessionMeta(firstLine: head[head.startIndex..<newline])
    }

    /// Parses what was appended since the last read (at most the last `tailBytes`).
    private func readAppended(_ path: String, into state: inout FileState) {
        guard state.size > state.offset else { return }
        var start = state.offset
        var cut = false
        if state.size - start > Self.tailBytes {
            start = state.size - Self.tailBytes
            cut = true
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.read(upToCount: Int(state.size - start)), !data.isEmpty else { return }
        var skipped: UInt64 = 0
        if cut { // starts mid-line
            guard let newline = data.firstIndex(of: 0x0A) else { return }
            skipped = UInt64(newline - data.startIndex + 1)
            data = data.suffix(from: newline + 1)
        }
        let (snapshot, consumed) = CodexRollout.parse(Data(data))
        state.snapshot.merge(snapshot)
        state.offset = start + skipped + UInt64(consumed)
    }
}
