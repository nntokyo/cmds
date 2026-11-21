import Foundation

/// Where the bookmarks bar of browser panes reads bookmarks from (Settings › General, #377): Google Chrome and other
/// Chromium browsers (the same `Bookmarks` / `AccountBookmarks` JSON in their own folders), or Safari
/// (`~/Library/Safari/Bookmarks.plist`). Read only.
public enum BookmarkSource: String, CaseIterable, Sendable {
    case chrome, edge, brave, vivaldi, arc, safari

    public var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .safari: "Safari"
        }
    }

    /// A Chromium browser: profiles with `Bookmarks` files, `Local State` naming them.
    public var isChromium: Bool { self != .safari }

    /// The browser's data folder under `~/Library` (Chromium: the folder with `Local State` and the profiles).
    public func folder(home: String = NSHomeDirectory()) -> URL {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        switch self {
        case .chrome: return support.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .edge: return support.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .brave: return support.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .vivaldi: return support.appendingPathComponent("Vivaldi", isDirectory: true)
        case .arc: return support.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .safari: return library.appendingPathComponent("Safari", isDirectory: true)
        }
    }
}

/// Safari's `Bookmarks.plist`: the Favorites bar (`BookmarksBar`) and the Bookmarks menu (`BookmarksMenu`, shown as
/// Other Bookmarks); the Reading List is left out.
public enum SafariBookmarks {
    public static func parse(_ data: Data) -> ChromeBookmarks.Tree? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let lists = root["Children"] as? [[String: Any]] else { return nil }
        var budget = ChromeBookmarks.maxItems
        func items(_ list: [String: Any], depth: Int) -> [ChromeBookmarks.Item] {
            guard depth < ChromeBookmarks.maxDepth, let children = list["Children"] as? [[String: Any]] else { return [] }
            var result: [ChromeBookmarks.Item] = []
            for child in children {
                guard budget > 0 else { break }
                budget -= 1
                switch child["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    guard let raw = child["URLString"] as? String, let url = URL(string: raw),
                          ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { continue }
                    let title = ((child["URIDictionary"] as? [String: Any])?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    result.append(.link(title: title ?? url.host ?? raw, url: url))
                case "WebBookmarkTypeList":
                    result.append(.folder(title: child["Title"] as? String ?? "", items: items(child, depth: depth + 1)))
                default:
                    continue
                }
            }
            return result
        }
        func list(_ title: String) -> [String: Any]? { lists.first { $0["Title"] as? String == title } }
        return ChromeBookmarks.Tree(bar: list("BookmarksBar").map { items($0, depth: 0) } ?? [],
                                    other: list("BookmarksMenu").map { items($0, depth: 0) } ?? [])
    }
}
