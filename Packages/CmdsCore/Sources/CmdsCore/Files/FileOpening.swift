import Foundation

/// Where a files pane opens a file (Return, ⌘↓ or a double-click; docs/guide/files.md "Opening and previewing files"):
/// in the workspace's preview pane, except files that only mean something to their own app (disk images, installers,
/// archives, applications, scripts to run, links), which open in their default app as in the Finder.
public enum FileOpening {
    /// Extensions opened in their default app, never in a pane.
    public static let defaultAppExtensions: Set<String> = [
        "dmg", "iso", "sparseimage", "sparsebundle", "pkg", "mpkg",
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "lz", "lzma", "zst", "xip",
        "app", "command", "tool", "terminal", "workflow", "prefpane", "saver", "mobileconfig",
        "webloc", "inetloc", "fileloc", "alias",
    ]

    /// Whether `path` opens in a preview pane rather than in its default app.
    public static func opensInPane(_ path: String) -> Bool {
        !defaultAppExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
