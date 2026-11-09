import CmdsCore
import Foundation

// `cmds mcp`: a Model Context Protocol server on stdin/stdout (newline-delimited JSON-RPC 2.0) that gives agents
// browser panes, previews and the sidebar status of the cmds terminal they run in (docs/guide/ai-agents.md, #76).
extension CLI {
    static let mcpCommand = Command(
        name: "mcp", usage: "mcp",
        summary: "Run an MCP server on stdin/stdout: browser panes, previews and sidebar status for agents (Claude Code, Codex, …).",
        details: """
            Register it with your agent (e.g. `claude mcp add cmds -- cmds mcp`); the agent starts it. Tools are offered
            only inside a cmds terminal (CMDS_PANE_ID set). Panes open without taking the keyboard focus, and
            close_pane closes only panes opened from that terminal (by this server or the cmds CLI). See
            docs/guide/ai-agents.md.
            """
    ) { ctx in
        let server = MCPServer(environment: ctx.environment) { method, params, timeout in
            try ctx.call(method, params, timeout: timeout)
        }
        server.serve()
    }
}

/// The MCP server behind `cmds mcp`. `handle` maps one incoming message to its response (nil for notifications);
/// `call` performs an app API request, so tests can run the server without the app.
final class MCPServer {
    typealias Call = (_ method: String, _ params: [String: JSONValue?], _ timeout: TimeInterval) throws -> JSONValue

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// App API timeouts: most requests, and eval / snapshot, which wait for the page.
    static let requestTimeout: TimeInterval = 60
    static let pageTimeout: TimeInterval = 120

    static let instructions = """
        You are running inside cmds, a terminal workspace app; these tools act on the cmds window next to your terminal.
        To open, check or show a web page (a dev server, docs, a page you changed), use browser_open and the other \
        browser_* tools instead of Chrome or another browser (no Chrome extension, no `open <url>`), so the user sees the \
        page beside the terminal. Use Chrome only when the user asks for it, when the page needs the user's Chrome \
        sign-ins or saved passwords (cmds browser panes do not share them), or for what browser_eval cannot do (file \
        uploads, native dialogs). Show generated files (images, PDFs, Markdown reports, diffs) with open_file. Close the \
        panes you opened when you are done (close_pane; it also closes panes opened from your terminal with the cmds \
        CLI, such as `cmds browser open` or `cmds open`).
        """

    static let notInsideCmds = """
        Not running inside a cmds terminal (CMDS_PANE_ID is not set), so cmds offers no tools here. Start the agent in \
        a cmds terminal to use cmds browser panes and previews. In a cmds terminal, an agent that starts MCP servers \
        with a cleaned environment must pass on CMDS_PANE_ID, CMDS_WORKSPACE_ID and CMDS_SOCKET_PATH (Codex: \
        env_vars in [mcp_servers.cmds]).
        """

    private let environment: [String: String]
    private let call: Call
    /// Panes this server opened, oldest first. close_pane accepts these, and panes the app says were opened from our
    /// terminal pane (`pane.close` with `openedBy`; #165).
    private(set) var openedPanes: [String] = []
    /// The browser pane browser_* tools use when no pane is given: the last one this server opened.
    private var lastBrowserPane: String?

    init(environment: [String: String], call: @escaping Call) {
        self.environment = environment
        self.call = call
    }

    private var envPane: String? { nonEmpty(environment[CmdsEnv.paneID]) }
    var insideCmds: Bool { envPane != nil }
    private var envWorkspace: String? { nonEmpty(environment[CmdsEnv.workspaceID]) }

    /// Reads messages until stdin closes.
    func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line: line) {
                FileHandle.standardOutput.write(Data((encodeJSON(response, pretty: false) + "\n").utf8))
            }
        }
    }

    func handle(line: String) -> JSONValue? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return Self.error(id: .null, code: -32700, message: "parse error")
        }
        if case .array(let batch) = message {  // 2025-03-26 batches
            if batch.isEmpty { return Self.error(id: .null, code: -32600, message: "invalid request: empty batch") }
            let responses = batch.compactMap(handle(message:))
            return responses.isEmpty ? nil : .array(responses)
        }
        return handle(message: message)
    }

    func handle(message: JSONValue) -> JSONValue? {
        guard case .object = message, let method = message["method"]?.stringValue else {
            if let id = message["id"], message["result"] == nil, message["error"] == nil {
                return Self.error(id: id, code: -32600, message: "invalid request")
            }
            return nil  // a response to a request we never send, or junk without an id
        }
        guard let id = message["id"] else { return nil }  // notifications (initialized, cancelled, …)
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(insideCmds ? Self.tools.map(\.definition) : [])]))
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = Self.tools.first(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "unknown tool: \(params["name"]?.stringValue ?? "")")
            }
            return Self.result(id: id, callTool(tool, arguments: params["arguments"] ?? .object([:])))
        default:
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": "cmds", "version": .string(CLI.version)]),
            "instructions": .string(insideCmds ? Self.instructions : Self.notInsideCmds),
        ])
    }

    // MARK: Tools

    struct Tool {
        let name: String
        let description: String
        var properties: [String: JSONValue] = [:]
        var required: [String] = []

        var definition: JSONValue {
            .object([
                "name": .string(name),
                "description": .string(description),
                "inputSchema": .object([
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                ]),
            ])
        }
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    private static let browserPane = string("Browser pane id. Default: the last browser pane this server opened, else the focused browser pane of the workspace.")

    static let tools: [Tool] = [
        Tool(name: "browser_open",
             description: "Open a URL in a new cmds browser pane split to the right of your terminal, without taking the keyboard focus. Returns the pane id. Use this instead of Chrome inside cmds.",
             properties: ["url": string("URL to load (http, https, file).")], required: ["url"]),
        Tool(name: "browser_navigate", description: "Load a URL in a cmds browser pane.",
             properties: ["url": string("URL to load."), "pane": browserPane], required: ["url"]),
        Tool(name: "browser_url", description: "The URL and title of a cmds browser pane.",
             properties: ["pane": browserPane]),
        Tool(name: "browser_eval",
             description: "Run JavaScript in a cmds browser pane and return its JSON value. The script may use top-level await (then `return` the value). Use it to read the page (document.body.innerText), click (el.click()) and fill inputs (set el.value, then dispatch an 'input' event).",
             properties: ["script": string("JavaScript to run in the page."), "pane": browserPane], required: ["script"]),
        Tool(name: "browser_snapshot", description: "A PNG screenshot of the visible page in a cmds browser pane.",
             properties: ["pane": browserPane]),
        Tool(name: "browser_set_viewport",
             description: "Show a cmds browser pane at a device size (the page gets that CSS layout width and height, scaled to fit the pane), with a user agent and light/dark color scheme, to check responsive layouts. Only the arguments given change; without any it returns the current settings. \(CLI.browserDeviceLimits)",
             properties: [
                "device": string("A preset (\(DevicePreset.all.map(\.id).joined(separator: ", "))), WIDTHxHEIGHT in CSS pixels (e.g. 375x667), or \"off\" to fill the pane again. A preset also sets its user agent."),
                "rotate": .object(["type": "boolean", "description": "Swap width and height (landscape / portrait)."]),
                "userAgent": string("User agent to send; \"\" = WebKit's own."),
                "colorScheme": .object(["type": "string", "enum": ["system", "light", "dark"],
                                        "description": "prefers-color-scheme of the page; system follows the Mac."]),
                "pane": browserPane,
             ]),
        Tool(name: "open_file",
             description: "Show a file on this Mac (image, PDF, video, Office, text/code, rendered Markdown, coloured diff) in a cmds preview pane split to the right, without taking the focus. The pane reloads when the file changes. Returns the pane id.",
             properties: ["path": string("Absolute path (relative paths are resolved against the server's working directory)."),
                          "diff": .object(["type": "boolean", "description": "Show the file as a unified diff."])],
             required: ["path"]),
        Tool(name: "close_pane",
             description: "Close a browser, preview or files pane opened from your terminal: by browser_open or open_file, or with the cmds CLI (`cmds browser open`, `cmds open`), also before this server restarted. Other panes are refused; close them with `cmds close-pane <id>` only when the user asks.",
             properties: ["pane": string("Pane id returned by browser_open, open_file or the cmds CLI.")], required: ["pane"]),
        Tool(name: "set_status",
             description: "Show a short progress text in the cmds sidebar for your workspace, without notifying the user (empty text clears it).",
             properties: ["text": string("Status text, e.g. \"Running tests (3/10)\".")], required: ["text"]),
    ]

    private struct ToolError: Error { let message: String }

    private func callTool(_ tool: Tool, arguments: JSONValue) -> JSONValue {
        guard insideCmds else { return Self.toolResult([Self.text(Self.notInsideCmds)], isError: true) }
        do {
            return Self.toolResult(try run(tool.name, arguments))
        } catch let error as ToolError {
            return Self.toolResult([Self.text(error.message)], isError: true)
        } catch let error as CLIError {
            return Self.toolResult([Self.text(error.message)], isError: true)
        } catch {
            return Self.toolResult([Self.text("\(error)")], isError: true)
        }
    }

    /// A string argument; `allowEmpty` accepts "" (set_status clears with it).
    private func argument(_ arguments: JSONValue, _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key]?.stringValue, allowEmpty || !value.isEmpty else {
            throw ToolError(message: "missing argument: \(key)")
        }
        return value
    }

    /// The id of the pane a request opened, remembered (also for browser_* defaults).
    private func recordOpenedPane(_ result: JSONValue) throws -> String {
        guard let id = result["id"]?.stringValue else { throw ToolError(message: "the app returned no pane id") }
        if !openedPanes.contains(id) { openedPanes.append(id) }
        return id
    }

    /// A browser_* request to `pane` if given, else the last browser pane we opened, else the workspace's browser pane
    /// (the app picks it). A last pane the user has meanwhile closed is forgotten and the workspace's pane used instead.
    private func browserCall(_ method: String, _ arguments: JSONValue, _ params: [String: JSONValue?] = [:],
                             timeout: TimeInterval) throws -> JSONValue {
        func send(_ target: [String: JSONValue?]) throws -> JSONValue {
            try call(method, params.merging(target) { $1 }, timeout)
        }
        if let pane = nonEmpty(arguments["pane"]?.stringValue) { return try send(["pane": .string(pane)]) }
        if let pane = lastBrowserPane {
            do {
                return try send(["pane": .string(pane)])
            } catch let error as CLIError where error.message.hasPrefix("pane not found") {
                lastBrowserPane = nil
                openedPanes.removeAll { $0 == pane }
            }
        }
        return try send(["workspace": envWorkspace.json])
    }

    private func run(_ name: String, _ arguments: JSONValue) throws -> [JSONValue] {
        switch name {
        case "browser_open":
            let result = try call("browser.open", ["pane": envPane.json, "url": .string(try argument(arguments, "url")),
                                                   "focus": .bool(false)], Self.requestTimeout)
            let id = try recordOpenedPane(result)
            lastBrowserPane = id
            return [Self.text("Opened browser pane \(id).")]
        case "browser_navigate":
            let url = try argument(arguments, "url")
            try browserCall("browser.navigate", arguments, ["url": .string(url)], timeout: Self.requestTimeout)
            return [Self.text("Loading \(url).")]
        case "browser_url":
            let result = try browserCall("browser.get_url", arguments, timeout: Self.requestTimeout)
            var lines = [result["url"]?.stringValue ?? ""]
            if let title = nonEmpty(result["title"]?.stringValue) { lines.append(title) }
            return [Self.text(lines.joined(separator: "\n"))]
        case "browser_eval":
            let script = try argument(arguments, "script")
            let result = try browserCall("browser.eval", arguments, ["script": .string(script)], timeout: Self.pageTimeout)
            let value = result["value"] ?? .null
            if case .string(let string) = value { return [Self.text(string)] }
            return [Self.text(encodeJSON(value, pretty: false))]
        case "browser_snapshot":
            let result = try browserCall("browser.snapshot", arguments, timeout: Self.pageTimeout)
            guard let base64 = result["png_base64"]?.stringValue, !base64.isEmpty else {
                throw ToolError(message: "the snapshot returned no image")
            }
            return [.object(["type": "image", "data": .string(base64), "mimeType": "image/png"])]
        case "browser_set_viewport":
            let change: BrowserViewportChange
            do {
                change = try BrowserViewportChange(params: arguments)
            } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            let result = try browserCall("browser.set_viewport", arguments, change.params, timeout: Self.requestTimeout)
            return [Self.text(BrowserEmulation(json: result).summary)]
        case "open_file":
            let path = absolutePath(try argument(arguments, "path"))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw ToolError(message: "no such file: \(path)")
            }
            guard !isDirectory.boolValue else { throw ToolError(message: "\(path) is a directory") }
            let result = try call("pane.open_file", [
                "pane": envPane.json, "path": .string(path), "focus": .bool(false),
                "format": arguments["diff"]?.boolValue == true ? "diff" : nil,
            ], Self.requestTimeout)
            let id = try recordOpenedPane(result)
            return [Self.text("Showing \(path) in preview pane \(id).")]
        case "close_pane":
            let pane = try argument(arguments, "pane")
            // Panes not opened by this server: the app closes them only if they were opened from our terminal pane
            // (a CLI `cmds browser open`, or a previous server), checked app-side so the answer cannot go stale.
            let openedBy: JSONValue?
            if openedPanes.contains(pane) {
                openedBy = nil
            } else if let envPane {
                openedBy = .string(envPane)
            } else {
                // Never an unchecked close of someone else's pane (tools/call already requires CMDS_PANE_ID).
                throw ToolError(message: "\(pane) was not opened by this server")
            }
            do {
                try call("pane.close", ["pane": .string(pane), "openedBy": openedBy], Self.requestTimeout)
            } catch let error as CLIError where openedBy != nil && error.message.contains("was not opened from") {
                throw ToolError(message: """
                    \(pane) was not opened from your terminal (\(envPane ?? "")), so close_pane leaves it open: it closes \
                    only browser, preview and files panes opened from your terminal (browser_open, open_file, `cmds \
                    browser open`, `cmds open`). If the user wants it closed, run `cmds close-pane \(pane)`.
                    """)
            }
            openedPanes.removeAll { $0 == pane }
            if lastBrowserPane == pane { lastBrowserPane = nil }
            return [Self.text("Closed \(pane).")]
        case "set_status":
            let text = try argument(arguments, "text", allowEmpty: true)
            try call("sidebar.set_status", ["workspace": envWorkspace.json, "text": .string(text)], Self.requestTimeout)
            return [Self.text(text.isEmpty ? "Cleared the status." : "Status set.")]
        default:
            throw ToolError(message: "unknown tool: \(name)")
        }
    }

    // MARK: JSON-RPC

    private static func text(_ string: String) -> JSONValue { .object(["type": "text", "text": .string(string)]) }

    private static func toolResult(_ content: [JSONValue], isError: Bool = false) -> JSONValue {
        .object(["content": .array(content), "isError": .bool(isError)])
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
