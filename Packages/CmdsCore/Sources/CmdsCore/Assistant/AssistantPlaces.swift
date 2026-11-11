import Foundation

/// Folders the assistant may start an agent in when the place said is no workspace (#243): a folder of that name under
/// the user's project folders (Settings › Assistant › Project folders; by default ~/Source, ~/Developer, ~/Projects and
/// ~/src, those that exist), up to three levels down. Git repositories come first and are not searched inside. Only
/// folders that exist are ever offered.
public struct AssistantPlaces: Sendable {
    /// What the search reads: the subfolders of a folder and whether it is a repository. `fileSystem` in the app, a
    /// fake tree in tests.
    public struct Tree: Sendable {
        public var folders: @Sendable (String) -> [String]
        public var isRepository: @Sendable (String) -> Bool

        public init(folders: @escaping @Sendable (String) -> [String], isRepository: @escaping @Sendable (String) -> Bool) {
            self.folders = folders
            self.isRepository = isRepository
        }

        /// The disk: visible subfolders (not packages, not symbolic links), and `.git` inside.
        public static let fileSystem = Tree(folders: { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])) ?? []
            return items.compactMap { item in
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      values.isSymbolicLink != true, values.isPackage != true else { return nil }
                return item.lastPathComponent
            }
        }, isRepository: { path in
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
        })
    }

    /// The default project folders, under the home folder.
    public static let defaultRoots = ["~/Source", "~/Developer", "~/Projects", "~/src"]
    /// How deep below a project folder the search goes.
    public static let maxDepth = 3
    /// The most folders looked at in one search.
    public static let maxVisited = 4000
    /// Folders never searched inside.
    static let skipped: Set<String> = ["node_modules", "build", "dist", "vendor", "Pods", "DerivedData", "target", "out"]

    /// Absolute paths of the project folders.
    public var roots: [String]
    public var tree: Tree

    public init(roots: [String], tree: Tree = .fileSystem) {
        self.roots = roots
        self.tree = tree
    }

    /// The project folders from the setting (comma or newline separated; empty: the defaults that exist), with `~`
    /// expanded against `home`.
    public static func roots(setting: String, home: String, exists: (String) -> Bool) -> [String] {
        let listed = setting.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let paths = (listed.isEmpty ? defaultRoots : listed).map { path -> String in
            path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && exists($0) && seen.insert($0).inserted }
    }

    /// The folders `name` means, best first and only those of the best kind: named exactly so (spaces, case, width
    /// folded) and repositories before other folders, then those whose name sounds the same (シーエムディーエス for
    /// cmds). "tools cmds" also finds …/tools/cmds. Empty when none fits.
    public func find(_ name: String) -> [String] {
        let key = AssistantText.key(name)
        guard !key.isEmpty else { return [] }
        let saidReadings = AssistantVocabulary.readings(name)
        // (rank, path): 0 exact repository, 1 exact folder, 2 sounds the same (repository), 3 sounds the same.
        var found: [(rank: Int, path: String)] = []
        var visited = 0
        var queue: [(path: String, relative: String, depth: Int)] = roots.map { ($0, "", 0) }
        while !queue.isEmpty, visited < Self.maxVisited {
            let (path, relative, depth) = queue.removeFirst()
            for child in tree.folders(path).sorted() {
                visited += 1
                let childPath = (path as NSString).appendingPathComponent(child)
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                let repository = tree.isRepository(childPath)
                let childKey = AssistantText.key(child)
                if childKey == key || (key.count > childKey.count && AssistantText.key(childRelative).hasSuffix(key)
                                       && key.hasSuffix(childKey)) {
                    found.append((repository ? 0 : 1, childPath))
                } else if !childKey.isEmpty, !saidReadings.isDisjoint(with: AssistantVocabulary.readings(child)) {
                    found.append((repository ? 2 : 3, childPath))
                }
                if !repository, depth + 1 < Self.maxDepth, !Self.skipped.contains(child) {
                    queue.append((childPath, childRelative, depth + 1))
                }
            }
        }
        guard let best = found.map(\.rank).min() else { return [] }
        var seen = Set<String>()
        return found.filter { $0.rank == best && seen.insert($0.path).inserted }.map(\.path)
    }
}
