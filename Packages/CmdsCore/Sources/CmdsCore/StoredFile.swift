import Foundation

/// Loading a persisted JSON file without losing it when it is damaged (#3, #4): an unreadable file is moved aside
/// to `<name>.corrupt-<UTC timestamp>` (kept, never deleted), so the next save starts a new file instead of
/// overwriting the user's data.
public enum StoredFile {
    public enum LoadResult<Value> {
        /// No file yet.
        case missing
        case loaded(Value)
        /// The file exists but could not be read or decoded (`error`). `movedTo` is where it was moved, or the error
        /// that prevented the move (then the file is still in place and must not be overwritten).
        case unreadable(error: Error, movedTo: Result<URL, Error>)
    }

    public static func load<Value: Decodable>(_ type: Value.Type, from url: URL,
                                              decoder: JSONDecoder = JSONDecoder(),
                                              now: Date = Date()) -> LoadResult<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return .missing }
            return .unreadable(error: error, movedTo: Result { try moveAside(url, now: now) })
        }
        do {
            return .loaded(try decoder.decode(type, from: data))
        } catch {
            return .unreadable(error: error, movedTo: Result { try moveAside(url, now: now) })
        }
    }

    /// Renames `url` to `<name>.corrupt-<yyyyMMdd'T'HHmmss'Z'>` in the same directory (`-2`, `-3`… if taken)
    /// and returns the new location.
    @discardableResult
    public static func moveAside(_ url: URL, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "\(url.lastPathComponent).corrupt-\(formatter.string(from: now))"
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        var target = directory.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try fm.moveItem(at: url, to: target)
        return target
    }
}
