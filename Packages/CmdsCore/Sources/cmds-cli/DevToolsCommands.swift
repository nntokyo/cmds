import CmdsCore
import Foundation

// `cmds browser console|tree|click|fill|wait-for`: DevTools for agents in browser panes (#167, docs/reference/cli.md).
extension CLI {
    /// A browser.* request; an app without the method says to update.
    static func devToolsCall(_ ctx: Context, _ method: String, _ params: [String: JSONValue?], timeout: TimeInterval = 60) throws -> JSONValue {
        do {
            return try ctx.call(method, browserTarget(ctx).merging(params) { $1 }, timeout: timeout)
        } catch let error as CLIError where error.message.contains("method not found") {
            throw CLIError.failure("this cmds app has no \(method); update cmds")
        }
    }

    static func usageError<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as RPCError { throw CLIError.usage(error.message) }
    }

    static let consoleCommand = Command(
        name: "browser console",
        usage: "browser console [--pane P] [--level L] [--limit N] [--clear] [--follow]",
        summary: "Print a browser pane's console messages, uncaught errors and unhandled promise rejections.",
        details: """
            cmds records them from the start of every page (the last \(ConsoleBuffer.defaultCapacity), also before you
            ask). --level debug|log|info|warn|error keeps that level and more severe ones; --limit the newest N; --clear
            empties the record after printing; --follow keeps printing new ones until interrupted. Only the main frame
            (no iframes; in the responsive view, the first frame).
            \(browserPaneNote)
            """,
        options: ["pane", "level", "limit"], flags: ["clear", "follow"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser console [--pane P] [--level L] [--limit N] [--clear] [--follow]")
        var params: [String: JSONValue] = [:]
        if let level = ctx.args[option: "level"] { params["level"] = .string(level) }
        if let limit = try ctx.args.int("limit") { params["limit"] = .number(Double(limit)) }
        if ctx.args.has("clear") { params["clear"] = .bool(true) }
        var request = try usageError { try BrowserConsoleRequest(params: .object(params)) }
        var result = try devToolsCall(ctx, "browser.console", request.params)
        func show(_ result: JSONValue) {
            if ctx.json { return ctx.printJSON(result, compact: ctx.args.has("follow")) }
            let entries = (try? result["entries"]?.decode([ConsoleEntry].self)) ?? []
            for entry in entries { print(entry.line()) }
        }
        show(result)
        if !ctx.json, !ctx.args.has("follow"), let dropped = result["dropped"]?.intValue, dropped > 0 {
            printError("(\(dropped) older messages were dropped)")
        }
        guard ctx.args.has("follow") else { return }
        request.clear = false
        request.limit = nil
        while true {
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.5)
            request.since = result["last"]?.intValue ?? request.since
            result = try devToolsCall(ctx, "browser.console", request.params)
            show(result)
        }
    }

    static let treeCommand = Command(
        name: "browser tree",
        usage: "browser tree [--pane P] [--selector S] [--max N]",
        summary: "Print a browser pane's page as a tree of roles and names, with refs for click / fill.",
        details: """
            One line per element an agent can read or act on: links, buttons, form fields, headings, images, landmarks
            and lists, e.g. `- button "Sign in" [ref=e3]`. Refs stay valid until the page changes or navigates.
            --selector starts at that element; --max caps the nodes (\(PageScripts.maxNodes) at most). --json gives the
            nodes as JSON.
            \(browserPaneNote)
            """,
        options: ["pane", "selector", "max"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser tree [--pane P] [--selector S] [--max N]")
        var params: [String: JSONValue] = [:]
        if let selector = ctx.args[option: "selector"] { params["selector"] = .string(selector) }
        if let max = try ctx.args.int("max") { params["maxNodes"] = .number(Double(max)) }
        let action = try usageError { try BrowserPageAction(method: "browser.snapshot_tree", params: .object(params)) }
        let result = try devToolsCall(ctx, action.method, action.params, timeout: 120)
        if ctx.json { return ctx.printJSON(result) }
        print(result["text"]?.stringValue ?? "", terminator: "")
        if result["truncated"]?.boolValue == true { printError("(cut at \(result["count"]?.intValue ?? 0) nodes; use --selector)") }
    }

    static let clickCommand = Command(
        name: "browser click",
        usage: "browser click [--pane P] <ref|selector>",
        summary: "Click an element of a browser pane's page, by ref (from `cmds browser tree`) or CSS selector.",
        details: "Scrolls it into view and sends pointer and mouse events, then a click.\n" + browserPaneNote,
        options: ["pane"]
    ) { ctx in
        try ctx.args.expectPositionals(1...1, usage: "cmds browser click [--pane P] <ref|selector>")
        let target = try usageError { try ElementTarget.parse(ctx.args.positionals[0]) }
        let result = try devToolsCall(ctx, "browser.click", BrowserPageAction.click(target).params)
        if ctx.json { return ctx.printJSON(result) }
        print("clicked \(result["ref"]?.stringValue ?? target.description)")
    }

    static let fillCommand = Command(
        name: "browser fill",
        usage: "browser fill [--pane P] <ref|selector> <value|->",
        summary: "Fill a text field, select or checkbox of a browser pane's page, as typing would.",
        details: """
            Sets the value and sends `input` and `change` events, so frameworks such as React see it. A select takes an
            option's value or text; a checkbox or radio button true/false. `-` reads the value from stdin.
            \(browserPaneNote)
            """,
        options: ["pane"]
    ) { ctx in
        try ctx.args.expectPositionals(2...2, usage: "cmds browser fill [--pane P] <ref|selector> <value|->")
        let target = try usageError { try ElementTarget.parse(ctx.args.positionals[0]) }
        var value = ctx.args.positionals[1]
        if value == "-" {
            value = readStandardInput()
            if value.hasSuffix("\n") { value.removeLast() }
        }
        let action = try usageError {
            try BrowserPageAction(method: "browser.fill", params: .object(target.params.compactMapValues { $0 }.merging(["value": .string(value)]) { $1 }))
        }
        let result = try devToolsCall(ctx, action.method, action.params)
        if ctx.json { return ctx.printJSON(result) }
        print("filled \(result["ref"]?.stringValue ?? target.description)")
    }

    static let waitForCommand = Command(
        name: "browser wait-for",
        usage: "browser wait-for [--pane P] (--selector S | --text T) [--timeout SEC]",
        summary: "Wait until an element matching a selector, or some text, is visible in a browser pane's page.",
        details: """
            Prints the element's ref. Fails (exit 1) after --timeout seconds (default \(Int(PageScripts.defaultWaitTimeout)), at most \(Int(PageScripts.maxWaitTimeout))).
            \(browserPaneNote)
            """,
        options: ["pane", "selector", "text", "timeout"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser wait-for [--pane P] (--selector S | --text T) [--timeout SEC]")
        var params: [String: JSONValue] = [:]
        if let selector = ctx.args[option: "selector"] { params["selector"] = .string(selector) }
        if let text = ctx.args[option: "text"] { params["text"] = .string(text) }
        if let raw = ctx.args[option: "timeout"] {
            guard let seconds = Double(raw) else { throw CLIError.usage("--timeout expects seconds") }
            params["timeout"] = .number(seconds)
        }
        let action = try usageError { try BrowserPageAction(method: "browser.wait_for", params: .object(params)) }
        let result = try devToolsCall(ctx, action.method, action.params, timeout: PageScripts.maxWaitTimeout + 30)
        if ctx.json { return ctx.printJSON(result) }
        print(result["ref"]?.stringValue ?? "")
    }
}
