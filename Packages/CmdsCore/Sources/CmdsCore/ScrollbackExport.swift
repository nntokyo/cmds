import Foundation

/// Writing a terminal pane's whole scrollback to a file (#253): where it may go, the file (mode 0600, written beside
/// the target and moved into place), and the export in chunks of rows so a long history is never read at once. The
/// terminal reads are the app's (`TerminalSurface.screenText`); here they are closures, so the chunking is testable.
public enum ScrollbackExport {
    /// Rows read per step (one read of the terminal while its lock is held).
    public static let chunkRows = 2000
    /// How far past a chunk's end a step looks for a line that ends there (not soft-wrapped into the next row).
    public static let boundarySearchRows = 200
    /// The export file's mode: only the owner reads it (a scrollback may hold passwords or tokens).
    public static let fileMode: mode_t = 0o600
    /// The title used for a pane without one (`fileName`).
    static let untitled = "Terminal"
    /// Characters of a pane's title kept in the suggested file name.
    static let fileNameTitleLimit = 60

    /// `path` checked for `pane.export`: absolute, its folder exists, not a folder itself, and not an existing file
    /// unless `force`. Returns it standardized.
    public static func validatedPath(_ path: String, force: Bool, fileManager: FileManager = .default) throws -> String {
        guard path.hasPrefix("/") else { throw RPCError.invalidParams("path must be absolute: \(path)") }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !path.hasSuffix("/"), standardized != "/" else { throw RPCError.invalidParams("path names a folder: \(path)") }
        let folder = (standardized as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RPCError.invalidParams("no such folder: \(folder)")
        }
        // lstat: a symlink at the path counts as existing (it is replaced, never written through).
        var info = stat()
        if lstat(standardized, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFDIR { throw RPCError.invalidParams("path names a folder: \(standardized)") }
            if !force { throw RPCError.invalidParams("\(standardized) exists (use force to overwrite)") }
        }
        return standardized
    }

    /// The save panel's suggested name for a pane titled `title`: `<title> scrollback.txt`, without characters that
    /// file names cannot hold and at most 60 characters of the title.
    public static func fileName(title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || "/:\\".unicodeScalars.contains($0) ? "-" : Character($0) }
        var base = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.count > fileNameTitleLimit {
            base = String(base.prefix(fileNameTitleLimit)).trimmingCharacters(in: .whitespaces)
        }
        return (base.isEmpty ? untitled : base) + " scrollback.txt"
    }

    /// One line for `cmds pane export`: `wrote 1234 rows to /path (56789 bytes)`, plus the rows lost.
    public static func summary(_ result: JSONValue) -> String {
        var line = "wrote \(result["rows"]?.intValue ?? 0) rows to \(result["path"]?.stringValue ?? "?")"
        line += " (\(result["bytes"]?.intValue ?? 0) bytes)"
        if let lost = result["lost"]?.intValue, lost > 0 {
            line += "; \(lost) older rows were dropped by the scrollback limit before they were read"
        }
        return line
    }

    /// Whether `probe`, the plain text of two consecutive rows read as one selection, shows a line ending on the first
    /// row: the second row is not its soft-wrapped continuation (a newline between them) and the first row is not
    /// blank. Cutting chunks there joins them with one newline and loses nothing, however the reader trims blank rows
    /// at the edges of a selection.
    public static func isLineBoundary(_ probe: String) -> Bool {
        guard let newline = probe.firstIndex(of: "\n") else { return false }
        return newline != probe.startIndex
    }

    /// A chunk as read (VT text may end rows with CR LF, and the last chunk with a newline for the cursor's row)
    /// without newlines at its end (the export adds them), with colours reset at its end so the next chunk starts plain.
    public static func normalized(_ text: String, ansi: Bool) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        while result.hasSuffix("\n") || result.hasSuffix("\r") { result.removeLast() }
        if ansi, result.contains("\u{1B}"), !result.hasSuffix(reset) { result += reset }
        return result
    }

    static let reset = "\u{1B}[0m"

    /// The terminal (its surface or scrollbar) cannot be read at all.
    public static var cannotReadTerminal: RPCError { RPCError(code: 500, message: "cannot read the terminal") }

    /// One export: rows `next ..< end` in absolute numbering (screen row + rows pruned so far), so rows that the
    /// scrollback limit drops while it runs are counted as `lost` instead of shifting what is read.
    public struct Job: Sendable {
        public let ansi: Bool
        public let chunkRows: Int
        public let searchRows: Int
        public let start: Int
        public private(set) var next: Int
        public let end: Int
        /// Rows dropped by the scrollback limit before they were read.
        public private(set) var lost = 0
        /// A chunk has been read (the next one is joined with a newline).
        private var started = false
        /// Some text was produced (the export then ends with a newline).
        private var hasText = false

        /// The whole screen as it is now (history and the visible rows).
        public init(scrollbar: TerminalScrollbar, ansi: Bool, chunkRows: Int = ScrollbackExport.chunkRows,
                    searchRows: Int = ScrollbackExport.boundarySearchRows) {
            self.ansi = ansi
            self.chunkRows = max(1, chunkRows)
            self.searchRows = max(0, searchRows)
            start = scrollbar.pruned
            next = start
            end = start + scrollbar.total
        }

        public var isDone: Bool { next >= end }
        /// Rows the export covers (the whole screen when it started), and of those the rows written.
        public var rows: Int { end - start }
        public var rowsWritten: Int { next - start - lost }

        /// Reads the next chunk with `read(rows, ansi)` (screen rows, inclusive; nil when they cannot be read) given the
        /// terminal's `scrollbar` now, and returns its text to append (empty once done). The last chunk ends with a
        /// newline.
        public mutating func step(scrollbar: TerminalScrollbar?, read: (ClosedRange<Int>, Bool) -> String?) throws -> String {
            guard !isDone else { return "" }
            guard let bar = scrollbar else { throw ScrollbackExport.cannotReadTerminal }
            var first = next - bar.pruned
            if first < 0 {
                lost += min(-first, end - next)
                next = min(bar.pruned, end)
                first = 0
                if isDone { return ending }
            }
            let available = min(end - bar.pruned, bar.total)  // a cleared history can be shorter
            guard first < available else {
                lost += end - next  // gone with a cleared history
                next = end
                return ending
            }
            var last = min(first + chunkRows, available) - 1
            if last < available - 1 {
                let limit = min(last + searchRows, available - 2)
                var row = last
                while row <= limit {
                    if let probe = read(row...(row + 1), false), ScrollbackExport.isLineBoundary(probe) { break }
                    row += 1
                }
                last = min(row, limit + 1, available - 1)  // none found: cut at the limit anyway
            }
            guard let text = read(first...last, ansi) else {
                throw RPCError(code: 500, message: "cannot read rows \(first)–\(last) of the terminal")
            }
            var chunk = ScrollbackExport.normalized(text, ansi: ansi)
            if !chunk.isEmpty { hasText = true }
            if started { chunk = "\n" + chunk }
            started = true
            next += last - first + 1
            if isDone { chunk += ending }
            return chunk
        }

        /// What the export ends with once done: a newline after some text, nothing for an empty one.
        private var ending: String { hasText ? "\n" : "" }
    }
}

/// A new file written in pieces with mode 0600: created beside `path` under a temporary name (never following a
/// symlink, never an existing file) and moved to `path` by `finish`, refusing to replace a file that appeared meanwhile
/// unless `force`. `cancel` (or a failure) removes the temporary file and leaves `path` as it was.
public final class PrivateFileWriter {
    public let path: String
    public let force: Bool
    private let temporaryPath: String
    private var descriptor: Int32
    public private(set) var bytes = 0

    public init(path: String, force: Bool) throws {
        self.path = path
        self.force = force
        let url = URL(fileURLWithPath: path)
        temporaryPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).cmds-\(UUID().uuidString.prefix(8))").path
        descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, ScrollbackExport.fileMode)
        guard descriptor >= 0 else { throw Self.error("cannot create a file in", url.deletingLastPathComponent().path) }
        // Whatever the umask (the file is created with at most this mode, so a failure here leaves it no more open).
        guard fchmod(descriptor, ScrollbackExport.fileMode) == 0 else {
            let error = Self.error("cannot set the mode of", temporaryPath)
            cancel()
            throw error
        }
    }

    public func write(_ text: String) throws {
        guard descriptor >= 0 else { throw Self.closed }
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                let error = Self.error("cannot write", temporaryPath)
                cancel()
                throw error
            }
            offset += written
        }
        bytes += data.count
    }

    /// Moves the file into place.
    public func finish() throws {
        guard descriptor >= 0 else { throw Self.closed }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        descriptor = -1
        guard synced else {
            let error = Self.error("cannot write", path)
            unlink(temporaryPath)
            throw error
        }
        let moved = force ? rename(temporaryPath, path) : renamex_np(temporaryPath, path, UInt32(RENAME_EXCL))
        guard moved == 0 else {
            let exists = errno == EEXIST
            let error = exists ? RPCError.invalidParams("\(path) exists (use force to overwrite)") : Self.error("cannot write", path)
            unlink(temporaryPath)
            throw error
        }
    }

    public func cancel() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        unlink(temporaryPath)
    }

    deinit { cancel() }

    private static var closed: RPCError { RPCError(code: 500, message: "the export file is closed") }

    private static func error(_ what: String, _ path: String) -> RPCError {
        RPCError(code: 500, message: "\(what) \(path): \(String(cString: strerror(errno)))")
    }
}
