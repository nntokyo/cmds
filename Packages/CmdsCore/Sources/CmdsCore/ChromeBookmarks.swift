import Foundation

/// Google Chrome's bookmarks, read from its profile folder for the bookmarks bar of browser panes (Settings › General).
/// Chrome keeps them in `<profile>/Bookmarks` (JSON: `roots.bookmark_bar` / `other` / `synced`, each a folder of
/// `url` and `folder` nodes) and its profiles in `Local State` (`profile.last_used`, `profile.info_cache`). Read only;
/// cmds never writes there.
public enum ChromeBookmarks {
    /// A bookmark or a folder.
    public indirect enum Item: Equatable, Sendable {
        case link(title: String, url: URL)
        case folder(title: String, items: [Item])

        public var title: String {
            switch self {
            case .link(let title, _), .folder(let title, _): return title
            }
        }
    }

    /// The bookmarks of one profile: the bar's items, and the "Other" and "Mobile" folders (empty ones dropped).
    public struct Tree: Equatable, Sendable {
        public var bar: [Item]
        public var other: [Item]
        public var mobile: [Item]

        public init(bar: [Item], other: [Item] = [], mobile: [Item] = []) {
            self.bar = bar
            self.other = other
            self.mobile = mobile
        }

        public var isEmpty: Bool { bar.isEmpty && other.isEmpty && mobile.isEmpty }
    }

    /// A Chrome profile: its folder name (`Default`, `Profile 1`) and the name the user gave it.
    public struct Profile: Equatable, Sendable {
        public var directory: String
        public var name: String
    }

    /// `~/Library/Application Support/Google/Chrome`.
    public static func defaultChromeFolder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// Folders deeper than this are cut (a hand-edited or hostile file cannot recurse without end).
    public static let maxDepth = 32
    /// At most this many items are read (Chrome itself copes with tens of thousands; menus do not need more).
    public static let maxItems = 20_000
    /// Files larger than this are not read.
    public static let maxFileSize = 64 << 20

    /// Bookmarks of a `Bookmarks` file's contents. Links other than http, https and file (`javascript:`, `chrome:`)
    /// are left out; nil when the data is not a Chrome bookmarks file.
    public static func parse(_ data: Data) -> Tree? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: Any] else { return nil }
        var budget = maxItems
        func items(of root: String) -> [Item] {
            guard let folder = roots[root] as? [String: Any] else { return [] }
            return children(of: folder, depth: 0, budget: &budget)
        }
        return Tree(bar: items(of: "bookmark_bar"), other: items(of: "other"), mobile: items(of: "synced"))
    }

    private static func children(of folder: [String: Any], depth: Int, budget: inout Int) -> [Item] {
        guard depth < maxDepth, let nodes = folder["children"] as? [Any] else { return [] }
        var result: [Item] = []
        for case let node as [String: Any] in nodes {
            guard budget > 0 else { break }
            budget -= 1
            let title = (node["name"] as? String) ?? ""
            switch node["type"] as? String {
            case "url":
                guard let raw = node["url"] as? String, let url = URL(string: raw),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { continue }
                result.append(.link(title: title.isEmpty ? (url.host ?? raw) : title, url: url))
            case "folder":
                let items = children(of: node, depth: depth + 1, budget: &budget)
                result.append(.folder(title: title, items: items))
            default:
                continue
            }
        }
        return result
    }

    /// The profiles in `Local State` (sorted by folder, `Default` first) and the one Chrome used last.
    public static func profiles(localState data: Data) -> (profiles: [Profile], lastUsed: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any] else { return ([], nil) }
        let cache = profile["info_cache"] as? [String: Any] ?? [:]
        let profiles = cache.compactMap { directory, value -> Profile? in
            guard isProfileDirectory(directory) else { return nil }
            let name = ((value as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            return Profile(directory: directory, name: name)
        }.sorted { lhs, rhs in
            if (lhs.directory == "Default") != (rhs.directory == "Default") { return lhs.directory == "Default" }
            return lhs.directory.localizedStandardCompare(rhs.directory) == .orderedAscending
        }
        let lastUsed = (profile["last_used"] as? String).flatMap { isProfileDirectory($0) ? $0 : nil }
        return (profiles, lastUsed)
    }

    /// A profile folder name that stays inside Chrome's folder (no separators, not `.` / `..`).
    public static func isProfileDirectory(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// The `Bookmarks` file of `profile` (nil: the one Chrome used last, else `Default`) under `chromeFolder`.
    public static func bookmarksFile(profile: String?, chromeFolder: URL = defaultChromeFolder()) -> URL {
        var directory = profile.flatMap { isProfileDirectory($0) ? $0 : nil }
        if directory == nil, let data = try? Data(contentsOf: chromeFolder.appendingPathComponent("Local State")) {
            directory = profiles(localState: data).lastUsed
        }
        return chromeFolder.appendingPathComponent(directory ?? "Default", isDirectory: true)
            .appendingPathComponent("Bookmarks")
    }
}
