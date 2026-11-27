import Foundation

/// The folder tree of a files pane (#484, docs/guide/files.md "Folder tree"): the rules the app's outline view
/// follows, kept here so they can be unit-tested. Paths are absolute POSIX paths, on this Mac or on an SSH host.
public enum FolderTree {
    /// The root to show while the pane lists `folder`: `root` as long as `folder` is it or lies inside it, else
    /// `folder` itself (going outside the root, or above it, starts the tree there).
    public static func root(_ root: String?, showing folder: String) -> String {
        guard let root, RemotePath.isSameOrInside(folder, root) else { return RemotePath.normalized(folder) }
        return RemotePath.normalized(root)
    }

    /// The folders to open, in order, so that `folder` shows in a tree starting at `root`: `root` first, then each
    /// folder below it, `folder` last. Empty when `folder` is not inside `root`.
    public static func chain(from root: String, to folder: String) -> [String] {
        guard RemotePath.isSameOrInside(folder, root) else { return [] }
        let base = RemotePath.normalized(root)
        let rest = RemotePath.components(RemotePath.normalized(folder)).dropFirst(RemotePath.components(base).count)
        var chain = [base]
        for name in rest { chain.append(RemotePath.join(chain[chain.count - 1], name)) }
        return chain
    }

    /// A folder's entries as the tree lists them: hidden ones only when the pane shows them, folders first, each
    /// group by name like the Finder.
    public static func children(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        FileSorting.sorted(FileSorting.visible(entries, showHidden: showHidden), by: .name, ascending: true)
    }

    /// The name of a tree row: the last component (`/` for the root of the disk).
    public static func name(_ path: String) -> String { RemotePath.name(path) }
}
