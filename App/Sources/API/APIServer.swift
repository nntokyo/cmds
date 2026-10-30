import AppKit
import Combine
import CmdsCore
import os

/// Socket API (docs/ARCHITECTURE.md, "Socket API"): maps JSON-RPC methods onto `AppController`.
/// Requests arrive on connection threads and are handled on the main actor in arrival order;
/// async methods (browser eval/snapshot) reply when done without blocking other requests.
/// With a `scope` (the socket an SSH pane forwards to its server) every request first goes through
/// `RemoteAPIPolicy`: only the pane's own methods, targets pinned to that pane/workspace, results filtered.
@MainActor
final class APIServer {
    private let controller: AppController
    private let server: SocketServer
    private let scope: RemoteScope?
    private var subscriptions: [Int: AnyCancellable] = [:]

    init(controller: AppController, path: String? = nil, scope: RemoteScope? = nil) {
        self.controller = controller
        self.scope = scope
        server = SocketServer(path: path ?? controller.socketPath)
        server.onRequest = { [weak self] request, connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(request, from: connection) }
            }
        }
        server.onClose = { [weak self] connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.subscriptions.removeValue(forKey: connection.id) }
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        do {
            try server.start()
            return true
        } catch {
            Logger(subsystem: "tokyo.n-n.cmds", category: "api").error("socket API unavailable at \(self.server.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func stop() {
        server.stop()
        subscriptions.removeAll()
    }

    // MARK: - Dispatch

    private func handle(_ request: RPCRequest, from connection: SocketConnection) {
        guard !connection.closed else { return }
        let id = request.id
        if let scope {
            do {
                let params = Params(try RemoteAPIPolicy.authorize(method: request.method, params: request.params, scope: scope))
                let result = try perform(request.method, params)
                connection.reply(id: id, result: RemoteAPIPolicy.filterResult(method: request.method, result: result, scope: scope))
            } catch {
                connection.reply(id: id, error: Self.rpcError(error))
            }
            return
        }
        let params = Params(request.params)
        do {
            switch request.method {
            case "browser.eval":
                let pane = try browserPaneID(params)
                let script = try params.required("script")
                Task { @MainActor in
                    await respond(id, to: connection) { ["value": try await self.controller.browserEvaluate(paneID: pane, script: script)] }
                }
            case "browser.snapshot":
                let pane = try browserPaneID(params)
                Task { @MainActor in
                    await respond(id, to: connection) {
                        let png = try await self.controller.browserSnapshot(paneID: pane)
                        return ["png_base64": .string(png.base64EncodedString())]
                    }
                }
            #if DEBUG
            case "debug.preview_snapshot":
                // Tests only: picture of a preview pane even when the window is not on screen.
                guard let preview = controller.pane(id: try params.required("pane"))?.preview else {
                    throw RPCError.invalidParams("not a preview pane")
                }
                Task { @MainActor in
                    await respond(id, to: connection) {
                        ["png_base64": .string(try await preview.debugSnapshot().base64EncodedString())]
                    }
                }
            #endif
            case "events.subscribe":
                subscribe(connection)
                connection.reply(id: id, result: ["subscribed": true])
            default:
                connection.reply(id: id, result: try perform(request.method, params))
            }
        } catch {
            connection.reply(id: id, error: Self.rpcError(error))
        }
    }

    private func respond(_ id: Int, to connection: SocketConnection, _ body: () async throws -> JSONValue) async {
        do {
            connection.reply(id: id, result: try await body())
        } catch {
            connection.reply(id: id, error: Self.rpcError(error))
        }
    }

    /// Synchronous methods. Returns nil for methods without a result.
    private func perform(_ method: String, _ params: Params) throws -> JSONValue? {
        switch method {
        case "system.ping":
            return ["pong": true]
        case "system.identify":
            let info = Bundle.main.infoDictionary ?? [:]
            return [
                "version": .string(info["CFBundleShortVersionString"] as? String ?? "0"),
                "build": .string(info["CFBundleVersion"] as? String ?? "0"),
                "pid": .number(Double(getpid())),
                "socketPath": .string(controller.socketPath),
                "cliPath": BundledCLI.executablePath.map { .string($0) } ?? .null,
            ]
        case "system.stats":
            return try .from(controller.statsSnapshot())
        case "sync.status":
            // Local socket only: not in RemoteAPIPolicy.allowedMethods, so SSH-pane sockets get 403.
            return try .from(SyncStatusReport.current())

        case "agent.list":
            return try .from(controller.agentList())
        case "agent.report":
            guard let raw = params.value?["usage"], case .object = raw,
                  let usage = try? raw.decode(AgentUsage.self) else {
                throw RPCError.invalidParams("usage must be an AgentUsage object")
            }
            let pid = try params.int("pid")
            try controller.reportAgentUsage(paneID: try params.string("pane"), usage: usage,
                                            pid: pid.flatMap { $0 > 0 && $0 <= Int(Int32.max) ? Int32($0) : nil })
        case "agent.claude_hook":
            try controller.claudeHook(paneID: try params.string("pane"), input: try params.json("input"))
        case "agent.claude_status":
            try controller.claudeStatus(paneID: try params.string("pane"), input: try params.json("input"))
        case "agent.sessions":
            return try .from(controller.agentSessionList(paneID: try params.string("pane")))
        case "agent.resume":
            let all = try params.bool("all") ?? false
            let pane = try params.string("pane")
            if all, pane != nil { throw RPCError.invalidParams("give either pane or all, not both") }
            return try .from(controller.resumeAgentSessions(paneID: pane, all: all))
        case "remote.location":
            try controller.setRemoteLocation(paneID: try params.string("pane"), cwd: try params.string("cwd"),
                                             branch: try params.string("branch"))

        case "workspace.list":
            return try .from(controller.listWorkspaces())
        case "workspace.create":
            if let host = try params.string("ssh") {
                let launch = try SSHLaunch.checked(host: host, remoteCwd: try params.string("remoteCwd"))
                return try .from(controller.createSSHWorkspace(launch, title: try params.string("title")))
            }
            return try .from(controller.createWorkspace(title: try params.string("title"), cwd: try params.string("cwd"),
                                                        command: try params.string("command")))
        case "workspace.select":
            try controller.selectWorkspace(id: try params.required("id"))
        case "workspace.close":
            try controller.closeWorkspace(id: try params.string("id"))
        case "workspace.rename":
            try controller.renameWorkspace(id: try params.string("id"), title: try params.required("title"))

        case "pane.list":
            return try .from(controller.listPanes(workspaceID: try params.string("workspace")))
        case "pane.split":
            let rawDirection = try params.string("direction") ?? "right"
            guard let direction = SplitDirection(rawValue: rawDirection) else {
                throw RPCError.invalidParams("direction must be \"right\" or \"down\"")
            }
            let rawKind = try params.string("kind") ?? (try params.string("url") != nil ? "browser" : "terminal")
            guard let kind = PaneKind(rawValue: rawKind), kind != .preview else {
                throw RPCError.invalidParams("kind must be \"terminal\" or \"browser\" (files: pane.open_file)")
            }
            let ssh = try params.string("ssh").map { try SSHLaunch.checked(host: $0, remoteCwd: try params.string("remoteCwd")) }
            return try .from(controller.split(paneID: try params.string("pane"), direction: direction, kind: kind,
                                              url: try params.string("url"), cwd: try params.string("cwd"),
                                              command: try params.string("command"),
                                              focus: try params.bool("focus") ?? true, ssh: ssh))
        case "pane.open_file":
            let rawDirection = try params.string("direction") ?? "right"
            guard let direction = SplitDirection(rawValue: rawDirection) else {
                throw RPCError.invalidParams("direction must be \"right\" or \"down\"")
            }
            let format = try params.string("format").map { raw -> PreviewFormat in
                guard let format = PreviewFormat(rawValue: raw == "quicklook" ? "quickLook" : raw) else {
                    throw RPCError.invalidParams("format must be \"markdown\", \"diff\" or \"quicklook\"")
                }
                return format
            }
            return try .from(controller.openFile(paneID: try params.string("pane"), path: try params.required("path"),
                                                 direction: direction, focus: try params.bool("focus") ?? true,
                                                 format: format))
        case "pane.reconnect":
            try controller.connectSSH(paneID: try params.string("pane"))
        case "pane.focus":
            try controller.focusPane(id: try params.required("pane"))
        case "pane.close":
            try controller.closePane(id: try params.string("pane"))
        case "pane.send_text":
            try controller.sendText(paneID: try params.string("pane"), text: try params.required("text"))
        case "pane.read_text":
            return ["text": .string(try controller.readText(paneID: try params.string("pane"), scrollback: try params.int("scrollback")))]

        case "notify":
            try controller.notify(paneID: try params.string("pane"), title: try params.string("title"), body: try params.required("body"))
        case "sidebar.set_status":
            try controller.setStatus(workspaceID: try params.string("workspace"), text: try params.required("text"))

        case "browser.open":
            return try .from(controller.openBrowser(paneID: try params.string("pane"), url: try params.required("url"),
                                                    focus: try params.bool("focus") ?? true))
        case "browser.navigate":
            try controller.browserNavigate(paneID: try browserPaneID(params), url: try params.required("url"))
        case "browser.get_url":
            let location = try controller.browserLocation(paneID: try browserPaneID(params))
            return ["url": location.url.map { .string($0) } ?? .null, "title": .string(location.title)]

        default:
            throw RPCError.methodNotFound(method)
        }
        return nil
    }

    /// `pane` if given; otherwise the focused browser pane of `workspace` (default: selected), else its first browser pane.
    private func browserPaneID(_ params: Params) throws -> String {
        if let pane = try params.string("pane") { return pane }
        let workspace: Workspace
        if let id = try params.string("workspace") {
            guard let found = controller.workspace(id: id) else { throw RPCError.notFound("workspace not found: \(id)") }
            workspace = found
        } else {
            guard let selected = controller.selectedWorkspace else { throw RPCError.notFound("no workspace") }
            workspace = selected
        }
        if let focused = workspace.focusedPane, focused.kind == .browser { return focused.id }
        if let first = workspace.orderedPanes.first(where: { $0.kind == .browser }) { return first.id }
        throw RPCError.notFound("no browser pane in workspace \(workspace.id) (open one with `cmds browser open <url>`)")
    }

    // MARK: - Events

    private func subscribe(_ connection: SocketConnection) {
        guard subscriptions[connection.id] == nil else { return }
        subscriptions[connection.id] = controller.changes.sink { [weak self, weak connection] change in
            guard let self, let connection else { return }
            if connection.closed {
                self.subscriptions[connection.id] = nil
                return
            }
            connection.send(self.event(for: change))
        }
    }

    private func event(for change: StateChange) -> RPCEvent {
        switch change {
        case .workspaces:
            return RPCEvent(event: "workspaces.changed", params: ["workspaces": (try? .from(controller.listWorkspaces())) ?? .array([])])
        case .workspace(let id):
            return RPCEvent(event: "workspace.changed", params: [
                "workspace": .string(id),
                "info": (try? .from(controller.workspaceInfo(id: id))) ?? .null,
            ])
        case .pane(let workspaceID, let paneID):
            return RPCEvent(event: "pane.changed", params: [
                "workspace": .string(workspaceID),
                "pane": .string(paneID),
                "info": (try? .from(controller.paneInfo(id: paneID))) ?? .null,
            ])
        case .notification(let workspaceID, let paneID, let title, let body):
            return RPCEvent(event: "notification", params: [
                "workspace": .string(workspaceID),
                "pane": .string(paneID),
                "title": title.map { .string($0) } ?? .null,
                "body": .string(body),
            ])
        }
    }

    private static func rpcError(_ error: Error) -> RPCError {
        if let error = error as? RPCError { return error }
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return RPCError(code: 500, message: "JavaScript exception: \(message)")
        }
        return RPCError(code: 500, message: nsError.localizedDescription)
    }
}

/// Typed access to request params. `null` counts as absent; wrong types are `invalidParams`.
private struct Params {
    let value: JSONValue?

    init(_ value: JSONValue?) { self.value = value }

    func string(_ key: String) throws -> String? {
        switch value?[key] {
        case nil, .null?: return nil
        case .string(let string)?: return string
        default: throw RPCError.invalidParams("\(key) must be a string")
        }
    }

    func required(_ key: String) throws -> String {
        guard let string = try string(key) else { throw RPCError.invalidParams("missing param: \(key)") }
        return string
    }

    /// Any JSON value; a string is taken as JSON text (clients that cannot embed objects).
    func json(_ key: String) throws -> JSONValue {
        switch value?[key] {
        case nil, .null?: throw RPCError.invalidParams("missing param: \(key)")
        case .string(let text)?:
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
                throw RPCError.invalidParams("\(key) must be JSON")
            }
            return parsed
        case let other?: return other
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch value?[key] {
        case nil, .null?: return nil
        case .bool(let bool)?: return bool
        default: throw RPCError.invalidParams("\(key) must be a boolean")
        }
    }

    func int(_ key: String) throws -> Int? {
        switch value?[key] {
        case nil, .null?: return nil
        case .number(let number)? where number >= 0 && number == number.rounded() && number < 1e9: return Int(number)
        default: throw RPCError.invalidParams("\(key) must be a non-negative integer")
        }
    }
}
