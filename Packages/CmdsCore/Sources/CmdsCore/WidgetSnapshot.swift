import Foundation

/// What the cmds widget shows (#96): the menu bar item's figures (#95), written by the app to `widget.json` in its
/// support folder and read by the widget extension, which is sandboxed and may read only that file. Additive: a newer
/// app may add fields, an older widget ignores them; a widget that cannot read the file shows "Open cmds".
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "widget.json"
    /// Workspaces listed; the medium widget shows up to four.
    public static let maxWorkspaces = 6

    public struct Workspace: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var state: MenuBarSummary.State
        /// The agent and what it does or asks (`Claude · Add login validation`); empty when unknown.
        public var detail: String
        /// When it started to wait for the user (needs you only).
        public var waitingSince: Date?

        public init(id: String, title: String, state: MenuBarSummary.State, detail: String = "", waitingSince: Date? = nil) {
            self.id = id
            self.title = title
            self.state = state
            self.detail = detail
            self.waitingSince = waitingSince
        }
    }

    /// One ring: CPU, memory, or an account limit window.
    public struct Gauge: Codable, Equatable, Sendable {
        /// `CPU`, `Mem`, `Claude 5h`, …
        public var label: String
        /// 0…1.
        public var fraction: Double
        /// `normal`, `warning`, `critical` (`UsageLevel`), or `pressure` levels for memory.
        public var level: Level
        /// The limit's reset, nil for CPU and memory.
        public var resetsAt: Date?

        public enum Level: String, Codable, Sendable {
            case normal, warning, critical, accent

            /// An account limit's level: green, orange from 80 %, red from 95 %.
            public init(usage: UsageLevel) {
                switch usage {
                case .normal: self = .normal
                case .warning: self = .warning
                case .critical: self = .critical
                }
            }

            /// Memory by pressure: green, yellow on warning, red on critical (green while unknown).
            public init(pressure: MemoryPressure) {
                switch pressure {
                case .critical: self = .critical
                case .warning: self = .warning
                case .normal, .unknown: self = .normal
                }
            }
        }

        public init(label: String, fraction: Double, level: Level, resetsAt: Date? = nil) {
            self.label = label
            self.fraction = fraction
            self.level = level
            self.resetsAt = resetsAt
        }
    }

    public var updatedAt: Date
    public var needingUser: Int
    public var working: Int
    /// Why the menu bar's red dot shows (a limit at 95 % or more, critical memory pressure); nil when it does not.
    public var warning: String?
    public var workspaces: [Workspace]
    public var gauges: [Gauge]

    public init(updatedAt: Date, needingUser: Int, working: Int, warning: String? = nil, workspaces: [Workspace],
                gauges: [Gauge]) {
        self.updatedAt = updatedAt
        self.needingUser = needingUser
        self.working = working
        self.warning = warning
        self.workspaces = Array(workspaces.prefix(Self.maxWorkspaces))
        self.gauges = gauges
    }

    /// Same content apart from `updatedAt`: the app reloads the widget's timeline only when this changes.
    public func sameContent(as other: WidgetSnapshot) -> Bool {
        var copy = other
        copy.updatedAt = updatedAt
        return copy == self
    }

    /// `widget.json` in the support folder of the user's own cmds (`~/Library/Application Support/cmds`; the Debug
    /// widget reads `…/cmds-dev`, its app's folder, #247), from the real home: a sandboxed extension's
    /// `NSHomeDirectory()` is its container. Isolated instances (`CMDS_SUPPORT_DIR`) write theirs elsewhere, so they
    /// never change the user's widget.
    public static func defaultURL(home: String = realHomeDirectory(), folderName: String = CmdsEnv.supportFolderName) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The account's home folder from the user database, not `$HOME` or the sandbox container.
    public static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// By name (`needsUser`, `working`, …), so the order of the cases never matters to a stored file; an unknown name
/// (from a newer app) reads as `idle`.
extension MenuBarSummary.State: Codable {
    private static let names: [MenuBarSummary.State: String] = [
        .needsUser: "needsUser", .working: "working", .done: "done", .idle: "idle", .stopped: "stopped",
    ]

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = Self.names.first { $0.value == name }?.key ?? .idle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.names[self] ?? "idle")
    }
}
