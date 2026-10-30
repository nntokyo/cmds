import Foundation

// Moving workspaces and their AI agent sessions to another cmds instance (docs/guide/ai-agents.md "Moving to a new version",
// docs/reference/cli.md `cmds export` / `cmds import`). `state.export` writes a `WorkspaceBundle`; `state.import` recreates
// its workspaces and offers each pane's agent session for resuming, like a relaunch does.

/// Versioned, self-contained description of workspaces: layout with each pane's kind and location, the agent
/// session that ran in each terminal pane, and which workspace was selected. Pane/workspace IDs are not included
/// (the importing instance assigns new ones).
public struct WorkspaceBundle: Codable, Equatable, Sendable {
    public static let formatID = "cmds.workspaces"
    public static let currentVersion = 1

    // Limits for `validated()` (and the CLI's file read). Generous for real use, small enough for one socket request.
    public static let maxBytes = 4 * 1024 * 1024
    public static let maxWorkspaces = 100
    public static let maxPanes = 500
    public static let maxDepth = 24
    static let maxPathLength = 1024
    static let maxURLLength = 8192
    static let maxTextLength = 200
    /// Split ratios are clamped to this range.
    static let splitRatioRange = 0.08...0.92

    /// Always `cmds.workspaces`.
    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var source: Source?
    /// Index into `workspaces` of the selected workspace.
    public var selectedIndex: Int?
    public var workspaces: [Workspace]

    public struct Source: Codable, Equatable, Sendable {
        /// App version and build of the exporting instance (nil for a legacy export).
        public var version: String?
        public var build: String?
        /// Built by the CLI from `workspace.list` / `agent.list` of an app without `state.export`.
        public var legacy: Bool?

        public init(version: String? = nil, build: String? = nil, legacy: Bool? = nil) {
            self.version = version
            self.build = build
            self.legacy = legacy
        }
    }

    public struct Workspace: Codable, Equatable, Sendable {
        /// User-assigned title; nil = derived from the directory.
        public var title: String?
        public var workingDirectory: String?
        /// Index of the focused pane in reading order of `layout`.
        public var focusedPaneIndex: Int?
        public var layout: Node

        public init(title: String? = nil, workingDirectory: String? = nil, focusedPaneIndex: Int? = nil, layout: Node) {
            self.title = title
            self.workingDirectory = workingDirectory
            self.focusedPaneIndex = focusedPaneIndex
            self.layout = layout
        }

        /// Panes in reading order (left-to-right, top-to-bottom), as `focusedPaneIndex` counts them.
        public var panes: [Pane] { layout.panes }
    }

    /// Split tree. JSON: `{"pane": {...}}` or `{"split": {"axis", "ratio", "first", "second"}}`.
    public indirect enum Node: Codable, Equatable, Sendable {
        case pane(Pane)
        case split(axis: SplitAxis, ratio: Double, first: Node, second: Node)

        public var panes: [Pane] {
            switch self {
            case .pane(let pane): return [pane]
            case .split(_, _, let first, let second): return first.panes + second.panes
            }
        }

        var depth: Int {
            switch self {
            case .pane: return 1
            case .split(_, _, let first, let second): return 1 + max(first.depth, second.depth)
            }
        }

        private enum CodingKeys: String, CodingKey { case pane, split }
        private enum SplitKeys: String, CodingKey { case axis, ratio, first, second }

        public init(from decoder: Decoder) throws {
            // Bounded before recursing further (each level adds two coding-path entries).
            guard decoder.codingPath.count <= WorkspaceBundle.maxDepth * 2 + 4 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "layout is nested too deeply"))
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.pane) {
                self = .pane(try c.decode(Pane.self, forKey: .pane))
                return
            }
            let s = try c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            self = .split(axis: try s.decode(SplitAxis.self, forKey: .axis), ratio: try s.decode(Double.self, forKey: .ratio),
                          first: try s.decode(Node.self, forKey: .first), second: try s.decode(Node.self, forKey: .second))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pane(let pane):
                try c.encode(pane, forKey: .pane)
            case .split(let axis, let ratio, let first, let second):
                var s = c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
                try s.encode(axis, forKey: .axis)
                try s.encode(ratio, forKey: .ratio)
                try s.encode(first, forKey: .first)
                try s.encode(second, forKey: .second)
            }
        }
    }

    /// One pane. `kind` terminal: `cwd`, or `host` (+ `remoteCwd`) for an SSH pane; browser: `url`; preview: `path`
    /// (+ `format`). `agentSession` only on terminal panes (on an SSH pane its `host` is the pane's).
    public struct Pane: Codable, Equatable, Sendable {
        public var kind: PaneKind
        public var cwd: String?
        public var host: String?
        public var remoteCwd: String?
        public var url: String?
        public var path: String?
        /// Preview: forced rendering (`markdown`, `diff`, `quickLook`).
        public var format: String?
        public var agentSession: AgentSession?

        public init(kind: PaneKind, cwd: String? = nil, host: String? = nil, remoteCwd: String? = nil, url: String? = nil,
                    path: String? = nil, format: String? = nil, agentSession: AgentSession? = nil) {
            self.kind = kind
            self.cwd = cwd
            self.host = host
            self.remoteCwd = remoteCwd
            self.url = url
            self.path = path
            self.format = format
            self.agentSession = agentSession
        }

        public static func terminal(cwd: String?, session: AgentSession? = nil) -> Pane {
            Pane(kind: .terminal, cwd: cwd, agentSession: session)
        }

        public static func ssh(host: String, remoteCwd: String?, session: AgentSession? = nil) -> Pane {
            Pane(kind: .terminal, host: host, remoteCwd: remoteCwd, agentSession: session)
        }
    }

    public init(workspaces: [Workspace], selectedIndex: Int? = nil, source: Source? = nil, exportedAt: Date = Date()) {
        format = Self.formatID
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.source = source
        self.selectedIndex = selectedIndex
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, source, selectedIndex, workspaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        // Checked before the rest, so a newer bundle gets a clear message rather than a schema error.
        guard format == Self.formatID else { throw TransferError("not a cmds workspace bundle (format \"\(format.prefix(40))\")") }
        guard version >= 1 else { throw TransferError("unsupported bundle version \(version)") }
        guard version <= Self.currentVersion else {
            throw TransferError("bundle version \(version) was written by a newer cmds (this one reads up to \(Self.currentVersion)); update cmds")
        }
        exportedAt = c.lenientDate(.exportedAt) ?? Date()
        source = try c.decodeIfPresent(Source.self, forKey: .source)
        selectedIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(exportedAt.timeIntervalSince1970, forKey: .exportedAt)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(selectedIndex, forKey: .selectedIndex)
        try c.encode(workspaces, forKey: .workspaces)
    }

    public var paneCount: Int { workspaces.reduce(0) { $0 + $1.panes.count } }
    public var agentSessionCount: Int { workspaces.reduce(0) { $0 + $1.panes.filter { $0.agentSession != nil }.count } }
}

/// Invalid or unsupported bundle; `message` says what (English, for the CLI and the API).
public struct TransferError: Error, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Reading and validating

extension WorkspaceBundle {
    /// Decodes and validates a bundle file (at most `maxBytes`).
    public static func read(_ data: Data) throws -> WorkspaceBundle {
        guard data.count <= maxBytes else { throw TransferError("bundle is too large (\(data.count) bytes, max \(maxBytes))") }
        guard !data.isEmpty else { throw TransferError("bundle is empty") }
        let bundle: WorkspaceBundle
        do {
            bundle = try JSONDecoder().decode(WorkspaceBundle.self, from: data)
        } catch let error as TransferError {
            throw error
        } catch let error as DecodingError {
            throw TransferError("invalid bundle: \(describe(error))")
        } catch {
            throw TransferError("invalid bundle: \(error.localizedDescription)")
        }
        return try bundle.validated()
    }

    /// Decodes and validates a bundle given as a JSON value (`state.import`).
    public static func read(_ value: JSONValue) throws -> WorkspaceBundle {
        guard case .object = value else { throw TransferError("bundle must be a JSON object") }
        return try read(try JSONEncoder().encode(value))
    }

    /// The bundle with checked values: throws for anything the importer must not use (unknown kinds, relative or
    /// control-character paths, bad hosts, URLs other than http/https/file/about, sessions on non-terminal panes or
    /// for another host, too many workspaces/panes, too deep a layout, indexes out of range). Ratios are clamped and
    /// texts trimmed.
    public func validated() throws -> WorkspaceBundle {
        var copy = self
        guard workspaces.count <= Self.maxWorkspaces else { throw TransferError("too many workspaces (\(workspaces.count), max \(Self.maxWorkspaces))") }
        guard paneCount <= Self.maxPanes else { throw TransferError("too many panes (\(paneCount), max \(Self.maxPanes))") }
        if let selectedIndex, !workspaces.indices.contains(selectedIndex) {
            throw TransferError("selectedIndex \(selectedIndex) is out of range")
        }
        if let source = copy.source {
            copy.source = Source(version: try Self.text(source.version, "source.version"),
                                 build: try Self.text(source.build, "source.build"), legacy: source.legacy)
        }
        for index in copy.workspaces.indices {
            let label = "workspace \(index + 1)"
            var workspace = copy.workspaces[index]
            guard workspace.layout.depth <= Self.maxDepth else { throw TransferError("\(label): layout is nested too deeply") }
            workspace.title = try Self.text(workspace.title, "\(label) title")
            workspace.workingDirectory = try Self.path(workspace.workingDirectory, "\(label) workingDirectory", remote: true)
            if let focused = workspace.focusedPaneIndex, !workspace.panes.indices.contains(focused) {
                throw TransferError("\(label): focusedPaneIndex \(focused) is out of range")
            }
            workspace.layout = try Self.validate(workspace.layout, label)
            copy.workspaces[index] = workspace
        }
        return copy
    }

    private static func validate(_ node: Node, _ label: String) throws -> Node {
        switch node {
        case .pane(let pane):
            return .pane(try validate(pane, label))
        case .split(let axis, let ratio, let first, let second):
            guard ratio.isFinite else { throw TransferError("\(label): split ratio must be a number") }
            return .split(axis: axis, ratio: clampedRatio(ratio),
                          first: try validate(first, label), second: try validate(second, label))
        }
    }

    private static func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, splitRatioRange.lowerBound), splitRatioRange.upperBound)
    }

    private static func validate(_ pane: Pane, _ label: String) throws -> Pane {
        var pane = pane
        switch pane.kind {
        case .terminal:
            if let host = pane.host {
                do {
                    pane.host = try SSHLaunch.validateHost(host)
                    pane.remoteCwd = try SSHLaunch.validateRemoteCwd(pane.remoteCwd)
                } catch {
                    throw TransferError("\(label): SSH pane: \(error)")
                }
                pane.cwd = nil
            } else {
                guard pane.remoteCwd == nil else { throw TransferError("\(label): remoteCwd without host") }
                pane.cwd = try path(pane.cwd, "\(label) terminal cwd", remote: false)
            }
            guard pane.url == nil, pane.path == nil, pane.format == nil else {
                throw TransferError("\(label): terminal pane with url/path/format")
            }
            if var session = pane.agentSession {
                guard AgentResume.supports(session.agent), AgentResume.isValidSessionID(session.sessionID) else {
                    throw TransferError("\(label): agent session cannot be resumed")
                }
                guard session.host == pane.host else {
                    throw TransferError("\(label): agent session host \(session.host ?? "(local)") differs from the pane's \(pane.host ?? "(local)")")
                }
                session.cwd = try path(session.cwd, "\(label) agent session cwd", remote: true)
                session.title = try text(session.title, "\(label) agent session title")
                session.model = try text(session.model, "\(label) agent session model")
                pane.agentSession = session
            }
        case .browser:
            guard pane.cwd == nil, pane.host == nil, pane.remoteCwd == nil, pane.path == nil, pane.format == nil,
                  pane.agentSession == nil else { throw TransferError("\(label): browser pane with terminal/preview fields") }
            if let url = pane.url {
                pane.url = try checkedURL(url, label)
            }
        case .preview:
            guard pane.cwd == nil, pane.host == nil, pane.remoteCwd == nil, pane.url == nil, pane.agentSession == nil else {
                throw TransferError("\(label): preview pane with terminal/browser fields")
            }
            guard let raw = pane.path, let checked = try path(raw, "\(label) preview path", remote: false), checked.hasPrefix("/") else {
                throw TransferError("\(label): preview pane needs an absolute path")
            }
            pane.path = (checked as NSString).standardizingPath
            if let format = pane.format, PreviewFormat(rawValue: format) == nil {
                throw TransferError("\(label): unknown preview format \"\(format.prefix(20))\"")
            }
        }
        return pane
    }

    /// Absolute path or `~`/`~/…` (bounded, no control characters). Empty becomes nil.
    static func path(_ raw: String?, _ what: String, remote: Bool) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.count <= maxPathLength else { throw TransferError("\(what) is too long") }
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw TransferError("\(what) contains control characters")
        }
        guard raw.hasPrefix("/") || raw == "~" || raw.hasPrefix("~/") else { throw TransferError("\(what) must be absolute: \(raw.prefix(80))") }
        return raw
    }

    static func text(_ raw: String?, _ what: String) throws -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            .trimmingCharacters(in: .whitespaces)
        guard raw.count <= maxTextLength * 4 else { throw TransferError("\(what) is too long") }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maxTextLength))
    }

    /// A browser URL as the importer accepts it (http, https, file), else nil (start page).
    public static func portableURL(_ raw: String) -> String? { (try? checkedURL(raw, "")) ?? nil }

    static func checkedURL(_ raw: String, _ label: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxURLLength,
              !trimmed.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "about"].contains(scheme) else {
            throw TransferError("\(label): browser URL must be http, https, file or about: \(trimmed.prefix(80))")
        }
        return scheme == "about" ? nil : trimmed
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return keys.isEmpty ? "" : "\(keys.hasPrefix(".") ? String(keys.dropFirst()) : keys): "
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context))missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context))\(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}

// MARK: - Import options and result

/// How `state.import` treats the workspaces already open.
public enum ImportMode: String, Codable, Sendable, CaseIterable {
    /// Add the imported workspaces after the existing ones (default).
    case append
    /// Close the existing workspaces once the imported ones are created.
    case replace
}

/// Result of `state.import`.
public struct ImportResult: Codable, Equatable, Sendable {
    public struct Offer: Codable, Equatable, Sendable {
        public var workspace: String
        public var pane: String
        public var agent: AgentKind
        public var sessionID: String
        public var command: String?

        public init(workspace: String, pane: String, agent: AgentKind, sessionID: String, command: String?) {
            self.workspace = workspace
            self.pane = pane
            self.agent = agent
            self.sessionID = sessionID
            self.command = command
        }
    }

    /// IDs of the created workspaces, in bundle order.
    public var workspaces: [String]
    public var panes: Int
    /// Workspaces closed by `replace`.
    public var closed: Int
    /// Resume mode used: `ask` offers (banner), `always` queues, `never` registers nothing.
    public var resume: AgentResumeMode
    /// Panes that got the bundle's agent session as resume offer.
    public var offers: [Offer]

    public init(workspaces: [String], panes: Int, closed: Int, resume: AgentResumeMode, offers: [Offer]) {
        self.workspaces = workspaces
        self.panes = panes
        self.closed = closed
        self.resume = resume
        self.offers = offers
    }
}

// MARK: - Legacy export (from the APIs of older builds)

extension WorkspaceBundle {
    /// Builds a bundle from `workspace.list` (+ `agent.list`, + `agent.sessions` where available) of a running app
    /// that has no `state.export`. Read as plain JSON, so fields an old build lacks (or new ones it never had) do not
    /// fail the export; anything that would not pass `validated()` is left out.
    ///
    /// Not covered by the old APIs: custom vs derived titles (a title differing from the directory name is kept),
    /// preview formats, and sessions of panes whose agent has already exited (unless `agent.sessions` lists them).
    public static func legacy(workspaces: JSONValue, agents: JSONValue?, sessions: JSONValue?,
                              home: String = NSHomeDirectory(), now: Date = Date()) throws -> WorkspaceBundle {
        guard let list = workspaces.arrayValue else { throw TransferError("workspace.list did not return a list") }
        // pane id → session: agent.sessions first (remembered, also exited agents), then live usage.
        var sessionByPane: [String: AgentSession] = [:]
        for entry in sessions?["sessions"]?.arrayValue ?? [] {
            guard let pane = entry["pane"]?.stringValue, let raw = entry["session"],
                  let session = try? raw.decode(AgentSession.self) else { continue }
            sessionByPane[pane] = session
        }
        var usageByPane: [String: JSONValue] = [:]
        for entry in agents?["panes"]?.arrayValue ?? [] {
            if let pane = entry["pane"]?.stringValue, let usage = entry["usage"] { usageByPane[pane] = usage }
        }

        var result: [Workspace] = []
        var selectedIndex: Int?
        for raw in list.prefix(maxWorkspaces) {
            let paneObjects = raw["panes"]?.arrayValue ?? []
            var byID: [String: JSONValue] = [:]
            for pane in paneObjects { if let id = pane["id"]?.stringValue { byID[id] = pane } }
            let tree: LegacyTree
            if let layout = raw["layout"], let parsed = LegacyTree(layout, depth: 0), Set(parsed.ids).isSubset(of: byID.keys) {
                tree = parsed
            } else {
                // No layout: the panes side by side.
                let ids = paneObjects.compactMap { $0["id"]?.stringValue }
                guard let first = ids.first else { continue }
                tree = ids.dropFirst().reduce(LegacyTree.pane(first)) { .split(.horizontal, 0.5, $0, .pane($1)) }
            }
            var kept: [String] = []
            func convert(_ node: LegacyTree) -> Node? {
                switch node {
                case .pane(let id):
                    guard let object = byID[id],
                          let pane = legacyPane(object, session: sessionByPane[id], usage: usageByPane[id] ?? object["agent"], now: now)
                    else { return nil }
                    kept.append(id)
                    return .pane(pane)
                case .split(let axis, let ratio, let first, let second):
                    let a = convert(first), b = convert(second)
                    guard let a, let b else { return a ?? b }
                    return .split(axis: axis, ratio: ratio.isFinite ? clampedRatio(ratio) : 0.5, first: a, second: b)
                }
            }
            guard let layout = convert(tree) else { continue }
            let focusedID = paneObjects.first { $0["focused"]?.boolValue == true }?["id"]?.stringValue
            let focused = focusedID.flatMap { kept.firstIndex(of: $0) }
            let cwd = try? path(raw["workingDirectory"]?.stringValue, "", remote: true)
            let title = raw["title"]?.stringValue.flatMap { title -> String? in
                derivedTitle(cwd ?? nil, home: home) == title ? nil : (try? text(title, "")) ?? nil
            }
            if raw["selected"]?.boolValue == true { selectedIndex = result.count }
            result.append(Workspace(title: title, workingDirectory: cwd ?? nil, focusedPaneIndex: focused, layout: layout))
        }
        let bundle = WorkspaceBundle(workspaces: result, selectedIndex: selectedIndex, source: Source(legacy: true), exportedAt: now)
        return try bundle.validated()
    }

    /// The pane, or nil when it cannot be carried over (invalid values are dropped field by field first).
    private static func legacyPane(_ object: JSONValue, session: AgentSession?, usage: JSONValue?, now: Date) -> Pane? {
        let kind = object["kind"]?.stringValue.flatMap(PaneKind.init(rawValue:)) ?? .terminal
        let cwd = object["workingDirectory"]?.stringValue
        var pane: Pane
        switch kind {
        case .browser:
            pane = Pane(kind: .browser, url: object["url"]?.stringValue.flatMap(portableURL))
        case .preview:
            guard let file = object["file"]?.stringValue, file.hasPrefix("/") else { return nil }
            pane = Pane(kind: .preview, path: file)
        case .terminal:
            if let host = object["remote"]?["host"]?.stringValue {
                guard let checkedHost = try? SSHLaunch.validateHost(host) else { return nil }
                pane = .ssh(host: checkedHost, remoteCwd: (try? SSHLaunch.validateRemoteCwd(cwd)) ?? nil)
            } else {
                pane = .terminal(cwd: (try? path(cwd, "", remote: false)) ?? nil)
            }
            var record = session
            if record == nil, let usage, let agent = usage["agent"].flatMap({ try? $0.decode(AgentKind.self) }),
               AgentResume.supports(agent), let id = usage["sessionID"]?.stringValue, AgentResume.isValidSessionID(id) {
                let lastSeen = FlexibleDate.date(from: usage["updatedAt"]) ?? now
                record = AgentSession(agent: agent, sessionID: id, cwd: pane.host == nil ? pane.cwd : pane.remoteCwd,
                                      host: pane.host, title: AgentResume.cleanTitle(object["title"]?.stringValue),
                                      model: usage["model"]?.stringValue, lastSeen: lastSeen)
            }
            if var record, record.host == pane.host {
                record.cwd = (try? path(record.cwd, "", remote: true)) ?? nil
                record.title = (try? text(record.title, "")) ?? nil
                record.model = (try? text(record.model, "")) ?? nil
                pane.agentSession = record
            }
        }
        return (try? validate(pane, "")) ?? nil
    }

    /// The title cmds shows for a workspace without a custom one (`Workspace.title` in the app).
    static func derivedTitle(_ cwd: String?, home: String) -> String {
        guard let cwd else { return "Workspace" }
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    private indirect enum LegacyTree {
        case pane(String)
        case split(SplitAxis, Double, LegacyTree, LegacyTree)

        init?(_ value: JSONValue, depth: Int) {
            guard depth < WorkspaceBundle.maxDepth else { return nil }
            // LayoutNode's synthesized coding: {"pane": {"id": …}} / {"split": {"axis", "ratio", "first", "second"}}.
            if let id = value["pane"]?["id"]?.stringValue {
                self = .pane(id)
            } else if let split = value["split"], let axis = split["axis"]?.stringValue.flatMap(SplitAxis.init(rawValue:)),
                      case .number(let ratio)? = split["ratio"],
                      let first = split["first"].flatMap({ LegacyTree($0, depth: depth + 1) }),
                      let second = split["second"].flatMap({ LegacyTree($0, depth: depth + 1) }) {
                self = .split(axis, ratio, first, second)
            } else {
                return nil
            }
        }

        var ids: [String] {
            switch self {
            case .pane(let id): return [id]
            case .split(_, _, let a, let b): return a.ids + b.ids
            }
        }
    }
}
