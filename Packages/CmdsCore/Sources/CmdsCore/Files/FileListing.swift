import Foundation

/// One row of a files pane (docs/guide/files.md): what the list shows and sorts by. The app reads it from the file
/// system; the sorting and naming rules live here so they can be unit-tested.
public struct FileEntry: Equatable, Sendable {
    public var name: String
    /// A folder the pane can open (packages such as `.app` bundles are files here).
    public var isFolder: Bool
    /// Starts with a dot or has the hidden flag.
    public var isHidden: Bool
    /// Bytes for files; nil for folders.
    public var size: Int64?
    public var modified: Date?
    /// Type description ("Folder", "PNG image"); localized by the app.
    public var kind: String

    public init(name: String, isFolder: Bool, isHidden: Bool = false, size: Int64? = nil, modified: Date? = nil,
                kind: String = "") {
        self.name = name
        self.isFolder = isFolder
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.kind = kind
    }
}

/// The column a files pane is sorted by.
public enum FileSortKey: String, Codable, Sendable, CaseIterable {
    case name
    case size
    case modified
    case kind
}

public enum FileSorting {
    /// Folders first, then files, each group ordered by `key` (names compared like the Finder: `file2` before
    /// `file10`, case-insensitive). Ties fall back to the name, ascending. Folders have no size: sorted by size they
    /// stay in name order.
    public static func sorted(_ entries: [FileEntry], by key: FileSortKey, ascending: Bool) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: ComparisonResult
            switch key {
            case .name:
                order = compareNames(a.name, b.name)
            case .size:
                order = compare(a.size ?? 0, b.size ?? 0)
            case .modified:
                order = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind:
                order = a.kind.localizedStandardCompare(b.kind)
            }
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            let byName = compareNames(a.name, b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.name < b.name
        }
    }

    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    /// Entries the pane shows: hidden ones only when asked for.
    public static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }
}

/// Names and paths for file operations.
public enum FileNames {
    /// A name that can be used in a folder: not empty, not `.`/`..`, no `/` or NUL, at most 255 UTF-8 bytes.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    /// "Keep both" for a name that is taken, like the Finder: `photo.jpg` → `photo 2.jpg`, `photo 2.jpg` →
    /// `photo 3.jpg`, `Folder` → `Folder 2`. Only the last extension is kept apart (`a.tar.gz` → `a.tar 2.gz`);
    /// folders and dot files without another dot (`.zshrc`) have none. `taken` says whether a name exists.
    public static func keepBoth(_ name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        let (stem, ext) = split(name, isFolder: isFolder)
        var base = stem
        var number = 2
        // `photo 2` → base `photo`, next number 3.
        if let space = stem.lastIndex(of: " "), let existing = Int(stem[stem.index(after: space)...]), existing >= 2,
           existing < 1_000_000, space != stem.startIndex {
            base = String(stem[..<space])
            number = existing + 1
        }
        while true {
            let candidate = "\(base) \(number)\(ext)"
            if !taken(candidate) { return candidate }
            number += 1
        }
    }

    /// Stem and extension (with its dot) of a file name.
    static func split(_ name: String, isFolder: Bool) -> (stem: String, ext: String) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// `path` is `folder` or lies inside it (both absolute; compared by standardized components). Copying or moving
    /// a folder into itself is refused with this.
    public static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        let a = (path as NSString).standardizingPath.split(separator: "/")
        let b = (folder as NSString).standardizingPath.split(separator: "/")
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    /// Both file URLs name the same path once standardized (`..`, trailing slash).
    public static func isSamePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// A path typed into Go to Folder: absolute, `~/…`, or relative to `folder`. Surrounding spaces are ignored.
    public static func resolve(typed: String, in folder: String) -> String {
        let path = (typed.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
    }

    /// The closest folder above `path` that still exists (`/` at the latest): where a pane goes when its folder is
    /// deleted or moved away.
    public static func nearestFolder(above path: String, isFolder: (String) -> Bool) -> String {
        var parent = (path as NSString).deletingLastPathComponent
        while parent != "/", !isFolder(parent) { parent = (parent as NSString).deletingLastPathComponent }
        return parent
    }
}

/// Which row a files pane selects after rows go away.
public enum FileSelection {
    /// After `removed` leave `rows` (names in list order), like the Finder: the next row that stays after the first
    /// removed one, else the last one before it; nil when nothing stays.
    public static func afterRemoving(_ removed: Set<String>, from rows: [String]) -> String? {
        let first = rows.firstIndex { removed.contains($0) } ?? 0
        return rows[first...].first { !removed.contains($0) } ?? rows[..<first].last { !removed.contains($0) }
    }
}
