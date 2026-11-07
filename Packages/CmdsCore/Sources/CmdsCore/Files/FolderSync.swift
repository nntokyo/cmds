import Foundation

/// Comparing two folders and planning a sync between them (docs/guide/files.md "Comparing and syncing folders").
/// Both folders are read through `FileTree`, so this Mac, a server, or one of each work the same way, and the rules
/// are tested without a network. The sync itself runs as a `TransferJob` (`.sync`) in the transfer queue.
///
/// Rules:
/// - Items are matched by name, folder by folder; folders on both sides are compared inside, a folder on one side only
///   is one item (copied as a whole). Files are the same when their sizes are equal and their modification dates are
///   within `timeTolerance` (SFTP v3 reports whole seconds); otherwise modified. A file on one side and a folder on
///   the other is modified too (`kindsDiffer`).
/// - Symbolic links and special files are listed (`.skipped`) and never followed or synced. A folder that cannot be
///   listed on one side is `.unreadable`: nothing inside it is compared or synced.
/// - Hidden items (names starting with a dot) are left out unless `includeHidden`; transfers' own part files
///   (`TransferNames.isPart`) always are.
/// - At most `maxItems` items are read; past that the comparison is `truncated` and cannot be synced (an item not
///   read could look missing on one side).
/// - One-way: new and modified items are copied from the source side; items only on the target side go to the Trash
///   only with `deleteExtra`. Two-way: items on one side only are copied to the other (never trashed: without a record
///   of an earlier sync, a missing item cannot be told from a deleted one), and every modified item is a conflict,
///   settled by the rule (newer wins, left wins, right wins, skip) or per item.
public enum FolderSync {
    public enum Side: String, Codable, Sendable, CaseIterable {
        case left, right

        public var other: Side { self == .left ? .right : .left }
    }

    public enum Status: String, Codable, Sendable {
        case leftOnly, rightOnly, modified, same
        /// A symbolic link or special file on either side: shown, never followed or synced.
        case skipped
        /// A folder that could not be listed on one side: nothing in it is compared.
        case unreadable
    }

    /// Dates closer than this count as the same (SFTP v3 has whole seconds; copies keep the date to the second).
    public static let timeTolerance: TimeInterval = 1
    /// Items read (both sides together) before a comparison stops as truncated.
    public static let defaultMaxItems = 50_000

    // MARK: - Comparison

    public struct Entry: Equatable, Sendable {
        /// Relative path on each side (`/`-separated). The sides may spell a name differently (Unicode normalization);
        /// each side's own spelling is kept, and an item missing on one side gets the other side's name there.
        public var leftPath: String
        public var rightPath: String
        public var left: FileItem?
        public var right: FileItem?
        public var status: Status
        /// `.unreadable`: why the folder could not be listed.
        public var error: String?

        public init(leftPath: String, rightPath: String, left: FileItem?, right: FileItem?, status: Status,
                    error: String? = nil) {
            self.leftPath = leftPath
            self.rightPath = rightPath
            self.left = left
            self.right = right
            self.status = status
            self.error = error
        }

        /// The path as shown (the left side's spelling).
        public var path: String { leftPath }

        public var isFolder: Bool { (left ?? right)?.kind == .folder }

        /// A file on one side and a folder on the other.
        public var kindsDiffer: Bool {
            guard let left, let right else { return false }
            return left.kind != right.kind
        }

        /// The side whose item was modified later, when both are files and their dates are further apart than
        /// `timeTolerance`.
        public var newer: Side? {
            guard let left, let right, left.kind == .file, right.kind == .file,
                  let a = left.modified, let b = right.modified, abs(a.timeIntervalSince(b)) > timeTolerance else {
                return nil
            }
            return a > b ? .left : .right
        }

        public func item(_ side: Side) -> FileItem? { side == .left ? left : right }
        public func path(_ side: Side) -> String { side == .left ? leftPath : rightPath }
    }

    public struct Comparison: Equatable, Sendable {
        public var entries: [Entry]
        /// Stopped at `maxItems`: not everything was read, so it cannot be synced.
        public var truncated: Bool
        /// Items read on both sides.
        public var itemsRead: Int

        public init(entries: [Entry], truncated: Bool, itemsRead: Int) {
            self.entries = entries
            self.truncated = truncated
            self.itemsRead = itemsRead
        }

        /// Everything except `.same`.
        public var differences: [Entry] { entries.filter { $0.status != .same } }
    }

    public struct CompareOptions: Equatable, Sendable {
        public var includeHidden: Bool
        public var maxItems: Int

        public init(includeHidden: Bool = false, maxItems: Int = FolderSync.defaultMaxItems) {
            self.includeHidden = includeHidden
            self.maxItems = maxItems
        }
    }

    /// The comparison was cancelled.
    public struct Cancelled: Error, Equatable {}

    /// Two items are the same: both files of equal size and (when both dates are known) dates within
    /// `timeTolerance`, or both folders.
    public static func isSame(_ a: FileItem, _ b: FileItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .folder: return true
        case .file:
            guard a.size == b.size else { return false }
            guard let x = a.modified, let y = b.modified else { return true }
            return abs(x.timeIntervalSince(y)) <= timeTolerance
        case .symlink, .other: return false
        }
    }

    /// Compares `leftRoot` in `left` with `rightRoot` in `right`, recursively (folders sorted by name, an item before
    /// its contents). Blocks; call it off the main thread. `isCancelled` is checked before each folder is listed;
    /// `progress` gets the number of items read so far. Throws `Cancelled`, a lost connection, or why either root
    /// cannot be listed.
    public static func compare(left: FileTree, _ leftRoot: String, right: FileTree, _ rightRoot: String,
                               options: CompareOptions = CompareOptions(), isCancelled: @escaping () -> Bool = { false },
                               progress: @escaping (Int) -> Void = { _ in }) throws -> Comparison {
        var walk = Walk(left: left, leftRoot: leftRoot, right: right, rightRoot: rightRoot, options: options,
                        isCancelled: isCancelled, progress: progress)
        // The roots must be readable; anything below that is not becomes an `.unreadable` entry.
        let leftItems = try walk.list(left, leftRoot)
        let rightItems = try walk.list(right, rightRoot)
        try walk.compare(leftItems, rightItems, leftPath: "", rightPath: "")
        return Comparison(entries: walk.entries, truncated: walk.truncated, itemsRead: walk.itemsRead)
    }

    private struct Walk {
        let left: FileTree
        let leftRoot: String
        let right: FileTree
        let rightRoot: String
        let options: CompareOptions
        let isCancelled: () -> Bool
        let progress: (Int) -> Void
        var entries: [Entry] = []
        var truncated = false
        var itemsRead = 0

        init(left: FileTree, leftRoot: String, right: FileTree, rightRoot: String, options: CompareOptions,
             isCancelled: @escaping () -> Bool, progress: @escaping (Int) -> Void) {
            self.left = left
            self.leftRoot = leftRoot
            self.right = right
            self.rightRoot = rightRoot
            self.options = options
            self.isCancelled = isCancelled
            self.progress = progress
        }

        /// The items of a folder that take part (hidden ones only with `includeHidden`, never part files).
        mutating func list(_ tree: FileTree, _ path: String) throws -> [FileItem] {
            if isCancelled() { throw Cancelled() }
            let items = try tree.list(path).filter { item in
                FileNames.isValid(item.name) && !TransferNames.isPart(item.name)
                    && (options.includeHidden || !item.name.hasPrefix("."))
            }
            itemsRead += items.count
            progress(itemsRead)
            return items
        }

        static func join(_ relative: String, _ name: String) -> String {
            relative.isEmpty ? name : relative + "/" + name
        }

        mutating func compare(_ leftItems: [FileItem], _ rightItems: [FileItem], leftPath: String,
                              rightPath: String) throws {
            // Swift compares names by canonical equivalence, so NFC and NFD spellings of a name match.
            var rightByName: [String: FileItem] = [:]
            for item in rightItems { rightByName[item.name] = item }
            var names = leftItems.map(\.name)
            let leftNames = Set(names)
            names += rightItems.map(\.name).filter { !leftNames.contains($0) }
            let leftByName = Dictionary(leftItems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if truncated { return }
                let l = leftByName[name]
                let r = rightByName[name]
                let lp = Self.join(leftPath, l?.name ?? name)
                let rp = Self.join(rightPath, r?.name ?? l?.name ?? name)
                try compareItem(l, r, leftPath: lp, rightPath: rp)
            }
        }

        mutating func compareItem(_ l: FileItem?, _ r: FileItem?, leftPath: String, rightPath: String) throws {
            func add(_ status: Status, error: String? = nil) {
                entries.append(Entry(leftPath: leftPath, rightPath: rightPath, left: l, right: r, status: status,
                                     error: error))
            }
            if [l?.kind, r?.kind].contains(.symlink) || [l?.kind, r?.kind].contains(.other) {
                return add(.skipped)
            }
            guard let l else { return add(.rightOnly) }
            guard let r else { return add(.leftOnly) }
            guard l.kind == .folder, r.kind == .folder else {
                return add(FolderSync.isSame(l, r) ? .same : .modified)
            }
            add(.same)
            if itemsRead >= options.maxItems {
                truncated = true
                return
            }
            let leftItems: [FileItem]
            let rightItems: [FileItem]
            do {
                leftItems = try list(left, left.paths.join(leftRoot, leftPath))
                rightItems = try list(right, right.paths.join(rightRoot, rightPath))
            } catch let error as Cancelled {
                throw error
            } catch let error as SFTPError {
                if case .disconnected = error { throw error }
                entries[entries.count - 1].status = .unreadable
                entries[entries.count - 1].error = error.description
                return
            } catch {
                entries[entries.count - 1].status = .unreadable
                entries[entries.count - 1].error = TransferFailure(error).description
                return
            }
            try compare(leftItems, rightItems, leftPath: leftPath, rightPath: rightPath)
        }
    }

    // MARK: - Plan

    public enum Direction: String, Codable, Sendable, CaseIterable {
        case leftToRight, rightToLeft, both

        /// The side copied from (one-way only).
        public var source: Side? {
            switch self {
            case .leftToRight: return .left
            case .rightToLeft: return .right
            case .both: return nil
            }
        }
    }

    /// How modified items of a two-way sync are settled.
    public enum ConflictRule: String, Codable, Sendable, CaseIterable {
        /// The later date wins; equal dates (with different sizes) and a file against a folder stay unsettled.
        case newer
        case left, right
        /// Nothing is copied.
        case skip
    }

    public struct Options: Equatable, Sendable {
        public var direction: Direction
        /// One-way only: items only on the target side go to its Trash.
        public var deleteExtra: Bool
        public var conflictRule: ConflictRule

        public init(direction: Direction, deleteExtra: Bool = false, conflictRule: ConflictRule = .newer) {
            self.direction = direction
            self.deleteExtra = deleteExtra
            self.conflictRule = conflictRule
        }
    }

    /// What a per-item choice makes of a modified item (overrides the direction or rule).
    public enum Choice: String, Codable, Sendable {
        /// The left item over the right one.
        case useLeft
        /// The right item over the left one.
        case useRight
        case skip
    }

    public struct Action: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Copy the item from the other side to `to`; what is there goes to that side's Trash first.
            case copy(to: Side)
            /// Move the item on that side to its Trash.
            case trash(Side)
        }

        public var kind: Kind
        /// Relative paths on each side.
        public var leftPath: String
        public var rightPath: String
        /// What the comparison saw on each side. Before writing, the job checks that the side it changes still
        /// looks like that (`matches`); otherwise the item changed since the comparison and is left alone.
        public var left: FileItem?
        public var right: FileItem?

        public init(_ kind: Kind, entry: Entry) {
            self.kind = kind
            leftPath = entry.leftPath
            rightPath = entry.rightPath
            left = entry.left
            right = entry.right
        }

        public var path: String { leftPath }
        public func path(_ side: Side) -> String { side == .left ? leftPath : rightPath }
        public func item(_ side: Side) -> FileItem? { side == .left ? left : right }

        /// The side this action changes.
        public var changes: Side {
            switch kind {
            case .copy(let to): return to
            case .trash(let side): return side
            }
        }
    }

    public struct Decision: Equatable, Sendable {
        public var entry: Entry
        /// Nil: nothing to do (same, skipped, unreadable, an extra item kept, an unsettled conflict).
        public var action: Action?
        /// Two-way: the item was modified on a side, and without a record of an earlier sync it is not known which.
        public var isConflict: Bool
        /// One-way: the item replaced on the target side is newer than the source's.
        public var replacesNewer: Bool
    }

    /// What a sync of `comparison` would do with each difference (`.same` entries are left out). `choices` (by
    /// `Entry.path`) override the direction or rule for modified items.
    public static func plan(_ entries: [Entry], options: Options, choices: [String: Choice] = [:]) -> [Decision] {
        entries.compactMap { entry in
            guard entry.status != .same else { return nil }
            return decide(entry, options: options, choice: choices[entry.path])
        }
    }

    static func decide(_ entry: Entry, options: Options, choice: Choice?) -> Decision {
        func decision(_ kind: Action.Kind?, conflict: Bool = false) -> Decision {
            let action = kind.map { Action($0, entry: entry) }
            var replacesNewer = false
            if case .copy(let to)? = kind, options.direction != .both, entry.newer == to { replacesNewer = true }
            return Decision(entry: entry, action: action, isConflict: conflict, replacesNewer: replacesNewer)
        }
        switch entry.status {
        case .same, .skipped, .unreadable:
            return decision(nil)
        case .leftOnly, .rightOnly:
            let present: Side = entry.status == .leftOnly ? .left : .right
            guard let source = options.direction.source, source != present else {
                return decision(.copy(to: present.other))
            }
            return decision(options.deleteExtra ? .trash(present) : nil)
        case .modified:
            let conflict = options.direction == .both
            if let choice {
                switch choice {
                case .useLeft: return decision(.copy(to: .right), conflict: conflict)
                case .useRight: return decision(.copy(to: .left), conflict: conflict)
                case .skip: return decision(nil, conflict: conflict)
                }
            }
            if let source = options.direction.source { return decision(.copy(to: source.other)) }
            switch options.conflictRule {
            case .newer: return decision(entry.newer.map { .copy(to: $0.other) }, conflict: true)
            case .left: return decision(.copy(to: .right), conflict: true)
            case .right: return decision(.copy(to: .left), conflict: true)
            case .skip: return decision(nil, conflict: true)
            }
        }
    }

    /// The item at a path still looks as the comparison saw it: nothing there when it saw nothing; else the same kind,
    /// and for files the same size and date (to the second).
    public static func matches(_ current: FileItem?, _ seen: FileItem?) -> Bool {
        guard let current, let seen else { return current == nil && seen == nil }
        guard current.kind == seen.kind else { return false }
        guard current.kind == .file else { return true }
        guard current.size == seen.size else { return false }
        guard let a = current.modified, let b = seen.modified else { return true }
        return abs(a.timeIntervalSince(b)) < 1
    }

    /// Counts of a plan (the preview's summary line).
    public struct Summary: Equatable, Sendable {
        public var toLeft = 0
        public var toRight = 0
        public var trashLeft = 0
        public var trashRight = 0
        /// Conflicts no rule or choice settled (nothing is copied for them).
        public var unsettled = 0

        public init(_ actions: [Action], unsettled: Int = 0) {
            for action in actions {
                switch action.kind {
                case .copy(to: .left): toLeft += 1
                case .copy(to: .right): toRight += 1
                case .trash(.left): trashLeft += 1
                case .trash(.right): trashRight += 1
                }
            }
            self.unsettled = unsettled
        }

        public var isEmpty: Bool { toLeft + toRight + trashLeft + trashRight == 0 }
    }
}

/// A comparison and its plan as the socket API reports it (`files.compare`, `files.sync`, `cmds files compare`).
/// Locations are `HOST:PATH` for SSH hosts, paths for this Mac; dates are seconds since 1970.
public struct FolderCompareInfo: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// `file`, `folder`, `symlink` or `other`.
        public var kind: String
        public var size: Int64?
        public var modified: Double?

        public init(_ item: FileItem) {
            switch item.kind {
            case .file: kind = "file"
            case .folder: kind = "folder"
            case .symlink: kind = "symlink"
            case .other: kind = "other"
            }
            size = item.kind == .file ? item.size : nil
            modified = item.modified?.timeIntervalSince1970
        }
    }

    /// Planned action of an entry: copy to a side, or to a side's Trash.
    public enum Action: String, Codable, Equatable, Sendable {
        case toRight, toLeft, trashLeft, trashRight

        public init(_ kind: FolderSync.Action.Kind) {
            switch kind {
            case .copy(to: .right): self = .toRight
            case .copy(to: .left): self = .toLeft
            case .trash(.left): self = .trashLeft
            case .trash(.right): self = .trashRight
            }
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var status: FolderSync.Status
        public var left: Item?
        public var right: Item?
        public var newer: FolderSync.Side?
        public var action: Action?
        public var conflict: Bool
        public var error: String?
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var toRight: Int
        public var toLeft: Int
        public var trashLeft: Int
        public var trashRight: Int
        public var unsettled: Int
    }

    public var left: String
    public var right: String
    public var direction: FolderSync.Direction
    public var truncated: Bool
    public var itemsRead: Int
    /// Entries that differ (and the same ones when asked for).
    public var entries: [Entry]
    public var summary: Summary
    /// `files.sync`: the transfer that runs the plan (nil when there was nothing to do).
    public var transfer: Int?

    public init(left: FileLocation, right: FileLocation, comparison: FolderSync.Comparison,
                decisions: [FolderSync.Decision], options: FolderSync.Options, includeSame: Bool = false,
                transfer: Int? = nil) {
        self.left = left.description
        self.right = right.description
        direction = options.direction
        truncated = comparison.truncated
        itemsRead = comparison.itemsRead
        let byPath = Dictionary(decisions.map { ($0.entry.path, $0) }, uniquingKeysWith: { a, _ in a })
        entries = comparison.entries.compactMap { entry in
            guard includeSame || entry.status != .same else { return nil }
            let decision = byPath[entry.path]
            return Entry(path: entry.path, status: entry.status, left: entry.left.map(Item.init),
                         right: entry.right.map(Item.init), newer: entry.newer,
                         action: decision?.action.map { Action($0.kind) }, conflict: decision?.isConflict ?? false,
                         error: entry.error)
        }
        let counts = FolderSync.Summary(decisions.compactMap(\.action),
                                        unsettled: decisions.filter { $0.isConflict && $0.action == nil }.count)
        summary = Summary(toRight: counts.toRight, toLeft: counts.toLeft, trashLeft: counts.trashLeft,
                          trashRight: counts.trashRight, unsettled: counts.unsettled)
        self.transfer = transfer
    }
}
