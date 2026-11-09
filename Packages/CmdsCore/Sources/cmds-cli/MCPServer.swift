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
    /// Snapshots at other sizes load the page once per size.
    static let devicesTimeout: TimeInterval = 300

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
        Tool(name: "browser_snapshot",
             description: "A PNG screenshot of a cmds browser pane: the visible page, or the full page (fullPage), one element (selector), or the page at other sizes (device, or up to \(BrowserSnapshotRequest.maxTargets) devices at once, each loaded again off screen with the same cookies). Returns one image per size, each after a line naming it. The pane is not scrolled or resized.",
             properties: [
                "pane": browserPane,
                "fullPage": .object(["type": "boolean", "description": .string("Capture the whole page (up to \(BrowserSnapshotRequest.maxHeight) CSS pixels tall).")]),
                "selector": string("CSS selector of one element to capture (the first match)."),
                "device": string("Capture at a preset (\(DevicePreset.all.map(\.id).joined(separator: ", "))) or WIDTHxHEIGHT instead of the pane's size."),
                "devices": .object(["type": "array", "items": .object(["type": "string"]),
                                    "description": "Several presets or WIDTHxHEIGHT sizes in one call, e.g. [\"iphone\", \"ipad\", \"desktop-1440\"] (phone, tablet, desktop)."]),
             ]),
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
        Tool(name: "browser_console",
             description: "Console messages, uncaught errors and unhandled promise rejections of a cmds browser pane's page, recorded from the start of each page (the last \(ConsoleBuffer.defaultCapacity)). Check it after loading or acting on a page.",
             properties: [
                "pane": browserPane,
                "level": .object(["type": "string", "enum": ["debug", "log", "info", "warn", "error"],
                                  "description": "Only this level and more severe ones."]),
                "limit": .object(["type": "integer", "description": "Only the newest this many."]),
                "clear": .object(["type": "boolean", "description": "Empty the record after reading it."]),
             ]),
        Tool(name: "browser_snapshot_tree",
             description: "The page of a cmds browser pane as a compact tree of roles and names (links, buttons, form fields, headings, images, landmarks), one line each with a ref, e.g. `- button \"Sign in\" [ref=e3]`. Use the refs with browser_click and browser_fill. Cheaper than a screenshot for finding what to act on.",
             properties: ["pane": browserPane, "selector": string("Start at this element (CSS selector) instead of the body.")]),
        Tool(name: "browser_click",
             description: "Click an element of a cmds browser pane's page by ref (from browser_snapshot_tree) or CSS selector.",
             properties: ["pane": browserPane, "ref": string("Ref from browser_snapshot_tree, e.g. e3."),
                          "selector": string("CSS selector (the first match), instead of ref.")]),
        Tool(name: "browser_fill",
             description: "Fill a text field, select (option value or text) or checkbox (true/false) of a cmds browser pane's page as typing would (input and change events), by ref or CSS selector.",
             properties: ["pane": browserPane, "ref": string("Ref from browser_snapshot_tree."),
                          "selector": string("CSS selector, instead of ref."), "value": string("The value to enter.")],
             required: ["value"]),
        Tool(name: "browser_wait_for",
             description: "Wait until an element matching a CSS selector, or some text, is visible in a cmds browser pane's page. Errors after timeout seconds.",
             properties: ["pane": browserPane, "selector": string("CSS selector."), "text": string("Visible text, instead of selector."),
                          "timeout": .object(["type": "number", "description": .string("Seconds (default \(Int(PageScripts.defaultWaitTimeout)), at most \(Int(PageScripts.maxWaitTimeout))).")])]),
        Tool(name: "browser_responsive",
             description: "Show a page at several sizes side by side in one cmds browser pane (default phone, tablet and desktop: \(BrowserResponsive.defaultDevices.joined(separator: ", "))). With url it opens a new browser pane beside your terminal (no focus) and returns its id; otherwise it acts on a browser pane. Navigation and scrolling stay in step across the frames. browser_snapshot of such a pane returns one image per frame. Each frame is its own WebKit process: use off when done.",
             properties: [
                "url": string("URL to open in a new responsive browser pane."),
                "pane": browserPane,
                "devices": .object(["type": "array", "items": .object(["type": "string"]),
                                    "description": "2–4 presets or WIDTHxHEIGHT sizes, left to right."]),
                "syncScroll": .object(["type": "boolean", "description": "Scroll the other frames along (default true)."]),
                "off": .object(["type": "boolean", "description": "Show the page once again."]),
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

    /// A DevTools request (#167); an app without the method says to update.
    private func devToolsCall(_ method: String, _ arguments: JSONValue, _ params: [String: JSONValue?]) throws -> JSONValue {
        do {
            return try browserCall(method, arguments, params, timeout: Self.pageTimeout)
        } catch let error as CLIError where error.message.contains("method not found") {
            throw ToolError(message: "this cmds app has no \(method); update cmds")
        }
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
            let request: BrowserSnapshotRequest
            do {
                request = try BrowserSnapshotRequest(params: arguments)
            } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            let result = try browserCall("browser.snapshot", arguments, request.params,
                                         timeout: request.targets.isEmpty ? Self.pageTimeout : Self.devicesTimeout)
            guard let images = BrowserSnapshotImage.images(from: result) else {
                guard request.isPlain else { throw ToolError(message: BrowserSnapshotImage.unsupportedMessage) }
                guard let base64 = result["png_base64"]?.stringValue, !base64.isEmpty else {
                    throw ToolError(message: "the snapshot returned no image")
                }
                return [.object(["type": "image", "data": .string(base64), "mimeType": "image/png"])]  // older app
            }
            guard !images.isEmpty else { throw ToolError(message: "the snapshot returned no image") }
            if request.isPlain, images.count == 1 { return [Self.image(images[0])] }  // else: a responsive view's frames
            return images.flatMap { image -> [JSONValue] in
                let what = request.selector.map { "element \($0)" } ?? (request.fullPage ? "full page" : "visible page")
                let size = image.device.map { "\($0), " } ?? ""
                return [Self.text("\(size)\(what), \(image.width)×\(image.height) CSS px"), Self.image(image)]
            }
        case "browser_set_viewport":
            let change: BrowserViewportChange
            do {
                change = try BrowserViewportChange(params: arguments)
            } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            let result = try browserCall("browser.set_viewport", arguments, change.params, timeout: Self.requestTimeout)
            return [Self.text(BrowserEmulation(json: result).summary)]
        case "browser_console":
            let request: BrowserConsoleRequest
            do { request = try BrowserConsoleRequest(params: arguments) } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            let result = try devToolsCall("browser.console", arguments, request.params)
            let entries = (try? result["entries"]?.decode([ConsoleEntry].self)) ?? []
            var lines = entries.map { $0.line() }
            if let dropped = result["dropped"]?.intValue, dropped > 0 { lines.insert("(\(dropped) older messages dropped)", at: 0) }
            return [Self.text(lines.isEmpty ? "No console messages." : lines.joined(separator: "\n"))]
        case "browser_snapshot_tree", "browser_click", "browser_fill", "browser_wait_for":
            let method = "browser." + name.dropFirst("browser_".count)
            let action: BrowserPageAction
            do { action = try BrowserPageAction(method: method, params: arguments) } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            let result = try devToolsCall(method, arguments, action.params)
            switch action {
            case .tree:
                var text = "\(result["title"]?.stringValue ?? "") — \(result["url"]?.stringValue ?? "")\n"
                text += result["text"]?.stringValue ?? ""
                if result["truncated"]?.boolValue == true { text += "(cut at \(result["count"]?.intValue ?? 0) nodes; pass selector)\n" }
                return [Self.text(text)]
            case .click(let target): return [Self.text("Clicked \(result["ref"]?.stringValue ?? target.description).")]
            case .fill(let target, _): return [Self.text("Filled \(result["ref"]?.stringValue ?? target.description).")]
            case .waitFor:
                return [Self.text("Found [ref=\(result["ref"]?.stringValue ?? "")] after \(result["elapsed"]?.intValue ?? 0) ms.")]
            }
        case "browser_responsive":
            let change: BrowserResponsiveChange
            do {
                var params = arguments
                if case .object(var object) = arguments, object["off"]?.boolValue == true {
                    object["on"] = .bool(false)
                    params = .object(object)
                }
                change = try BrowserResponsiveChange(params: params)
            } catch let error as RPCError {
                throw ToolError(message: error.message)
            }
            var params = change.params
            if change.on == nil { params["on"] = .bool(true) }
            if let url = nonEmpty(arguments["url"]?.stringValue) {
                guard nonEmpty(arguments["pane"]?.stringValue) == nil else { throw ToolError(message: "give either url or pane") }
                guard change.on != false else { throw ToolError(message: "off needs a pane, not a url") }
                let opened = try call("browser.open", ["pane": envPane.json, "url": .string(url), "focus": .bool(false)],
                                      Self.requestTimeout)
                let id = try recordOpenedPane(opened)
                lastBrowserPane = id
                let result = try call("browser.set_responsive", params.merging(["pane": .string(id)]) { $1 },
                                      Self.requestTimeout)
                return [Self.text("Opened browser pane \(id): \(BrowserResponsive.summary(result)).")]
            }
            let result = try browserCall("browser.set_responsive", arguments, params, timeout: Self.requestTimeout)
            return [Self.text(BrowserResponsive.summary(result))]
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

    private static func image(_ image: BrowserSnapshotImage) -> JSONValue {
        .object(["type": "image", "data": .string(image.png.base64EncodedString()), "mimeType": "image/png"])
    }

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
