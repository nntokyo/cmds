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
        return info.startMicroseconds
    }
}

/// What the Codex session files say, per pane.
struct CodexWatchResult: Sendable {
    /// Panes with a running Codex session process (whether or not its file is known yet).
    var panes: Set<String> = []
    /// Working directory of each such pane's Codex, when known (matches hook payloads to panes).
    var directories: [String: String] = [:]
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
///
/// Account limits also come from recent session files no pane holds (`codex exec` / `codex review` runs, sessions
/// that ended before cmds saw them, #227): every `recentScanInterval` the day folders of today and yesterday under
/// `$CODEX_HOME/sessions` (else `~/.codex/sessions`) are listed, and the `recentMaxFiles` newest files modified in the
/// last `recentWindow` are followed like the panes' files (appended part only, at most `recentTailBytes`), for their
/// limits only.
final class CodexSessionWatcher: @unchecked Sendable {
    static let tailBytes: UInt64 = 256 * 1024
    static let metaBytes = 256 * 1024
    static let recentScanInterval: TimeInterval = 15
    static let recentWindow: TimeInterval = 6 * 3600
    static let recentMaxFiles = 4
    static let recentTailBytes: UInt64 = 64 * 1024
    /// Today's and yesterday's day folders are listed for recent files.
    private static let recentDays = 2
    private static let secondsPerDay: TimeInterval = 86400

    /// `$CODEX_HOME/sessions` of cmds' own environment (as Codex resolves it), else `~/.codex/sessions`.
    static func sessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return (home as NSString).appendingPathComponent("sessions")
    }

    private struct FileState {
        var inode: UInt64 = 0
        var size: UInt64 = 0
        var modified = Date.distantPast
        var birth: Date?
        /// Bytes consumed so far (a line boundary).
        var offset: UInt64 = 0
        /// File size at the last read.
        var readSize: UInt64 = 0
        var snapshot = CodexRollout.Snapshot()
        var meta: CodexRollout.SessionMeta?
        var metaRead = false
    }

    private var files: [String: FileState] = [:]
    /// Recent files followed for their limits only.
    private var recent: [String: FileState] = [:]
    private var lastRecentScan: Date?
    private let sessionsDirectory: String

    init(sessionsDirectory: String = CodexSessionWatcher.sessionsDirectory()) {
        self.sessionsDirectory = sessionsDirectory
    }

    func update(_ processes: [CodexProcess], now: Date = Date()) -> CodexWatchResult {
        var (result, read) = updatePanes(processes)
        result.limits = Self.newer(recentLimits(now: now, skipping: read), than: result.limits)
        return result
    }

    /// `candidate` when it is newer than `current` (`updatedAt`), else `current`.
    private static func newer(_ candidate: AgentLimits?, than current: AgentLimits?) -> AgentLimits? {
        guard let candidate, candidate.updatedAt > (current?.updatedAt ?? .distantPast) else { return current }
        return candidate
    }

    /// The pane part of `update`; also returns the files it read.
    private func updatePanes(_ processes: [CodexProcess]) -> (CodexWatchResult, Set<String>) {
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
            return (CodexWatchResult(), [])
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
            guard var state = fileState(path: path, previous: files[path]) else { continue }
            if shared.contains(path) {
                if !state.metaRead { readMeta(path, into: &state) }
                // A daemon session whose directory is unknown or has no Codex pane: never read its contents.
                guard let cwd = state.meta?.cwd,
                      directories.contains(where: { $0 != nil && CodexSessionMatcher.sameDirectory($0, cwd) }) else {
                    files[path] = state
                    continue
                }
            }
            readAppended(path, into: &state, tailBytes: Self.tailBytes)
            files[path] = state
            candidates.append(.init(path: path, cwd: state.meta?.cwd, created: state.meta?.timestamp ?? state.birth,
                                    modified: state.modified, hasUsage: state.snapshot.hasUsage))
        }
        let known = held.union(shared)
        files = files.filter { known.contains($0.key) }

        var result = CodexWatchResult(panes: Set(panes.keys), directories: panes.compactMapValues(\.cwd))
        for (paneID, path) in CodexSessionMatcher.match(panes: Array(panes.values), files: candidates) {
            guard let state = files[path] else { continue }
            let id = CodexRollout.sessionID(fromPath: path) ?? state.meta?.id
            result.usage[paneID] = state.snapshot.usage(sessionID: id, fallbackDate: state.modified)
        }
        for candidate in candidates {
            guard let state = files[candidate.path] else { continue }
            result.limits = Self.newer(state.snapshot.accountLimits(fallbackDate: state.modified), than: result.limits)
        }
        return (result, Set(candidates.map(\.path)))
    }

    /// Newest limits in the recent session files that `skipping` (the panes' files) does not cover; the folders are
    /// listed at most every `recentScanInterval`, in between the known files are only re-read when they grew.
    private func recentLimits(now: Date, skipping: Set<String>) -> AgentLimits? {
        if lastRecentScan.map({ now.timeIntervalSince($0) >= Self.recentScanInterval }) ?? true {
            lastRecentScan = now
            let newest = recentFiles(now: now)
            recent = recent.filter { newest.contains($0.key) }
            for path in newest where recent[path] == nil { recent[path] = FileState() }
        }
        var best: AgentLimits?
        for path in Array(recent.keys) where !skipping.contains(path) {
            guard var state = fileState(path: path, previous: recent[path]) else {
                recent[path] = nil
                continue
            }
            readAppended(path, into: &state, tailBytes: Self.recentTailBytes)
            recent[path] = state
            best = Self.newer(state.snapshot.accountLimits(fallbackDate: state.modified), than: best)
        }
        return best
    }

    /// The `recentMaxFiles` newest session files in the recent day folders modified in the last `recentWindow`.
    private func recentFiles(now: Date) -> [String] {
        var found: [(path: String, modified: Date)] = []
        for folder in recentDayFolders(now: now) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where CodexRollout.isRolloutPath(name) {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let info = Self.regularFileInfo(path) else { continue }
                let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                if now.timeIntervalSince(modified) <= Self.recentWindow { found.append((path, modified)) }
            }
        }
        return found.sorted { $0.modified > $1.modified }.prefix(Self.recentMaxFiles).map(\.path)
    }

    /// `<sessions>/YYYY/MM/DD` of today and the days before (`recentDays`), in local time as Codex names them.
    private func recentDayFolders(now: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (0..<Self.recentDays).compactMap { back in
            let day = now.addingTimeInterval(-Double(back) * Self.secondsPerDay)
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
            return String(format: "%@/%04d/%02d/%02d", sessionsDirectory, year, month, dayOfMonth)
        }
    }

    /// `lstat` of a regular file (not a link, folder or missing path).
    private static func regularFileInfo(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return info
    }

    /// Refreshes size/mtime/inode; a replaced or truncated file starts over.
    private func fileState(path: String, previous: FileState?) -> FileState? {
        guard let info = Self.regularFileInfo(path) else { return nil }
        var state = previous ?? FileState()
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

    /// Retried until the first line is complete (a just-created file may still be empty); a first line longer than
    /// `metaBytes` is given up on (cwd stays unknown, so the file is never matched).
    private func readMeta(_ path: String, into state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.metaBytes) else { return }
        guard let newline = head.firstIndex(of: 0x0A) else {
            if head.count >= Self.metaBytes { state.metaRead = true }
            return
        }
        state.metaRead = true
        state.meta = CodexRollout.sessionMeta(firstLine: head[head.startIndex..<newline])
    }

    /// Parses what was appended since the last read (at most the last `tailBytes`).
    private func readAppended(_ path: String, into state: inout FileState, tailBytes: UInt64) {
        // Unchanged since the last read (e.g. an unterminated line being written): nothing new to parse.
        guard state.size > state.offset, state.size != state.readSize else { return }
        state.readSize = state.size
        var start = state.offset
        var cut = false
        if state.size - start > tailBytes {
            start = state.size - tailBytes
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
