import CmdsCore
import Foundation

// `cmds browser device` (device size, user agent and color scheme, #168), `browser snapshot` (#169) and
// `browser responsive` (#170), docs/reference/cli.md; and the helpers the browser commands share.
extension CLI {
    /// `body`, with a bad value it reports (`RPCError`) as a usage error: nothing is sent.
    static func usageError<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as RPCError { throw CLIError.usage(error.message) }
    }

    /// `ctx.call`; an app without `method` (older than the feature) fails with `unsupported`, by default
    /// `CLIError.olderApp(method)`.
    static func callNewMethod(_ ctx: Context, _ method: String, _ params: [String: JSONValue?], unsupported: String? = nil,
                              timeout: TimeInterval = 60) throws -> JSONValue {
        do {
            return try ctx.call(method, params, timeout: timeout)
        } catch let error as CLIError where error.isMethodNotFound {
            throw CLIError.failure(unsupported ?? CLIError.olderApp(method))
        }
    }

    /// What WKWebView does not emulate (also in the MCP tool and the pane's Device menu).
    static let browserDeviceLimits = """
        This sets the layout width and height, the user agent and prefers-color-scheme. WebKit on the Mac does not \
        emulate the device pixel ratio, touch events, pointer: coarse / hover: none, <meta name="viewport"> scaling or \
        prefers-reduced-motion; check those on a real device.
        """

    static let browserDeviceCommand = Command(
        name: "browser device",
        usage: "browser device [--pane P] [--rotate] [--ua UA] [--scheme light|dark|system] [--list] [<device|WxH|off>]",
        summary: "Show a browser pane at a device size, with a user agent and color scheme.",
        details: """
            <device> is a preset (see --list), WIDTHxHEIGHT in CSS pixels (\(ViewportSize.range.lowerBound)–\(ViewportSize.range.upperBound)), or off to fill the pane again.
            The page gets that layout size and is scaled down to fit the pane. A preset also sets its user agent;
            --ua sets another one ("" = WebKit's own). --rotate swaps width and height. --scheme sets
            prefers-color-scheme (system follows the Mac). Without arguments, prints the pane's current settings.
            The setting is kept per pane across relaunches.
            \(browserDeviceLimits)
            \(browserPaneNote)
            """,
        options: ["pane", "ua", "scheme"], flags: ["rotate", "list"]
    ) { ctx in
        let usage = "cmds browser device [--pane P] [--rotate] [--ua UA] [--scheme light|dark|system] [--list] [<device|WxH|off>]"
        try ctx.args.expectPositionals(0...1, usage: usage)
        if ctx.args.has("list") {
            if ctx.json { return ctx.printJSON(.array(DevicePreset.all.map(presetJSON))) }
            return print(presetTable(), terminator: "")
        }
        let change = try browserViewportChange(ctx.args)
        let result = try callNewMethod(ctx, "browser.set_viewport", browserTarget(ctx).merging(change.params) { $1 },
                                       unsupported: "this cmds app has no device sizes for browser panes; update cmds")
        if ctx.json { return ctx.printJSON(result) }
        print(BrowserEmulation(json: result).summary)
    }

    static let browserSnapshotCommand = Command(
        name: "browser snapshot",
        usage: "browser snapshot [--pane P] [--full] [--selector S] [--device D[,D…]] [-o file.png]",
        summary: "Save a PNG of a browser pane's page: what is visible, the full page, one element, or other sizes.",
        details: """
            --full captures the whole page (up to \(BrowserSnapshotRequest.maxHeight) CSS pixels tall), --selector the
            first element matching a CSS selector. --device captures at a preset (see `cmds browser device --list`) or
            WIDTHxHEIGHT instead of the pane's size; up to \(BrowserSnapshotRequest.maxTargets) comma-separated ones load
            the page again off screen, one after another (same cookies, not the pane's in-page state), and need -o:
            -o shot.png writes shot-iphone.png, shot-ipad.png, … The pane itself is not scrolled or resized.
            Without -o a single PNG is written to stdout when it is not a terminal. Prints the files written.
            \(browserPaneNote)
            """,
        options: ["pane", "output", "selector", "device"], flags: ["full"], aliases: ["o": "output"]
    ) { ctx in
        try ctx.args.expectPositionals(0...0, usage: "cmds browser snapshot [--pane P] [--full] [--selector S] [--device D[,D…]] [-o file.png]")
        let request = try browserSnapshotRequest(ctx.args)
        let output = ctx.args[option: "output"]
        if request.targets.count > 1, output == nil, !ctx.json {
            throw CLIError.usage("several devices give several images; use -o file.png (written as file-<device>.png)")
        }
        let result = try ctx.call("browser.snapshot", browserTarget(ctx).merging(request.params) { $1 }, timeout: 300)
        let images: [BrowserSnapshotImage]
        if let read = BrowserSnapshotImage.images(from: result) {
            images = read
        } else if request.isPlain, let base64 = result["png_base64"]?.stringValue, let png = Data(base64Encoded: base64) {
            images = [BrowserSnapshotImage(device: nil, width: 0, height: 0, png: png)]  // an app older than #169
        } else if request.isPlain {
            throw CLIError.failure("snapshot returned no image")
        } else {
            throw CLIError.failure(BrowserSnapshotImage.unsupportedMessage)
        }
        if ctx.json { return ctx.printJSON(result) }
        guard !images.isEmpty else { throw CLIError.failure("snapshot returned no image") }
        guard let output else {
            guard images.count == 1 else {  // a pane in the responsive view: one image per frame
                throw CLIError.usage("the pane gave \(images.count) images (responsive view); use -o file.png (written as file-<device>.png)")
            }
            guard isatty(STDOUT_FILENO) == 0 else { throw CLIError.usage("refusing to write PNG to a terminal; use -o file.png") }
            return FileHandle.standardOutput.write(images[0].png)
        }
        for (path, image) in zip(snapshotPaths(absolutePath(output), images: images), images) {
            do { try image.png.write(to: URL(fileURLWithPath: path)) } catch {
                throw CLIError.failure("cannot write \(path): \(error.localizedDescription)")
            }
            print(path)
        }
    }

    static let browserResponsiveCommand = Command(
        name: "browser responsive",
        usage: "browser responsive [--pane P] [--devices D,D[,D…]] [--no-sync-scroll | --sync-scroll] [--off] [--no-focus] [<url>]",
        summary: "Show a page at several sizes side by side in one browser pane (the responsive view).",
        details: """
            With a URL, opens it in a new browser split (prints the pane id); otherwise acts on a browser pane.
            --devices takes \(BrowserResponsive.frameCount.lowerBound)–\(BrowserResponsive.frameCount.upperBound) presets (see `cmds browser device --list`) or WIDTHxHEIGHT sizes, left to right
            (default \(BrowserResponsive.defaultDevices.joined(separator: ","))). Navigating in any frame loads the page in
            the others; scrolling one scrolls the others to the same proportion of their page (--no-sync-scroll turns
            that off). Reload reloads every frame, and a file:// page reloads when the file changes. --off shows the
            page once again. Each frame is its own WebKit process. Kept per pane across relaunches.
            \(browserPaneNote)
            """,
        options: ["pane", "devices"], flags: ["no-sync-scroll", "sync-scroll", "off", "no-focus"]
    ) { ctx in
        let usage = "cmds browser responsive [--pane P] [--devices D,D[,D…]] [--no-sync-scroll | --sync-scroll] [--off] [--no-focus] [<url>]"
        try ctx.args.expectPositionals(0...1, usage: usage)
        let change = try browserResponsiveChange(ctx.args)
        func setResponsive(_ target: [String: JSONValue?]) throws -> JSONValue {
            try callNewMethod(ctx, "browser.set_responsive", target.merging(change.params) { $1 },
                              unsupported: "this cmds app has no responsive view; update cmds")
        }
        if let url = ctx.args.positionals.first {
            guard ctx.args[option: "pane"] == nil else { throw CLIError.usage("give either --pane or a URL") }
            guard change.on != false else { throw CLIError.usage("--off needs a pane, not a URL") }
            let opened = try ctx.call("browser.open", ["pane": ctx.pane.json, "url": .string(url),
                                                       "focus": ctx.args.has("no-focus") ? false : nil])
            guard let id = opened["id"]?.stringValue else { throw CLIError.failure("the app returned no pane id") }
            let result = try setResponsive(["pane": .string(id)])
            if ctx.json { return ctx.printJSON(.object(["id": .string(id), "responsive": result])) }
            return print(id)
        }
        let result = try setResponsive(browserTarget(ctx))
        if ctx.json { return ctx.printJSON(result) }
        print(BrowserResponsive.summary(result))
    }

    /// The change a command line asks for (on unless --off); bad values are usage errors.
    static func browserResponsiveChange(_ args: Arguments) throws -> BrowserResponsiveChange {
        guard !(args.has("sync-scroll") && args.has("no-sync-scroll")) else {
            throw CLIError.usage("give --sync-scroll or --no-sync-scroll, not both")
        }
        var params: [String: JSONValue] = ["on": .bool(!args.has("off"))]
        if let devices = args[option: "devices"] { params["devices"] = .string(devices) }
        if args.has("sync-scroll") { params["syncScroll"] = .bool(true) }
        if args.has("no-sync-scroll") { params["syncScroll"] = .bool(false) }
        return try usageError { try BrowserResponsiveChange(params: .object(params)) }
    }

    /// The request a command line asks for; bad values are usage errors (nothing is sent).
    static func browserSnapshotRequest(_ args: Arguments) throws -> BrowserSnapshotRequest {
        var params: [String: JSONValue] = [:]
        if args.has("full") { params["fullPage"] = .bool(true) }
        if let selector = args[option: "selector"] { params["selector"] = .string(selector) }
        if let devices = args[option: "device"] { params["devices"] = .string(devices) }
        return try usageError { try BrowserSnapshotRequest(params: .object(params)) }
    }

    /// `output` for one image; `name-<device>.png` for each of several.
    static func snapshotPaths(_ output: String, images: [BrowserSnapshotImage]) -> [String] {
        guard images.count > 1 else { return [output] }
        let url = URL(fileURLWithPath: output)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let base = url.deletingPathExtension().path
        return images.enumerated().map { index, image in "\(base)-\(image.device ?? String(index + 1)).\(ext)" }
    }

    /// The change a command line asks for; bad values are usage errors (nothing is sent).
    static func browserViewportChange(_ args: Arguments) throws -> BrowserViewportChange {
        try usageError {
            var change = BrowserViewportChange()
            if let device = args.positionals.first { change.size = try BrowserViewportChange.parseSize(device) }
            change.rotate = args.has("rotate")
            if let agent = args[option: "ua"] { change.userAgent = try BrowserEmulation.checkedUserAgent(agent) ?? "" }
            change.colorScheme = try args[option: "scheme"].map(BrowserViewportChange.parseColorScheme)
            return change
        }
    }

    static func presetJSON(_ preset: DevicePreset) -> JSONValue {
        .object([
            "id": .string(preset.id), "name": .string(preset.name), "category": .string(preset.category.rawValue),
            "width": .number(Double(preset.size.width)), "height": .number(Double(preset.size.height)),
            "pixelRatio": .number(preset.pixelRatio),
            "userAgent": preset.userAgent.map { .string($0) } ?? .null,
        ])
    }

    static func presetTable() -> String {
        let idWidth = DevicePreset.all.map(\.id.count).max() ?? 0
        let nameWidth = DevicePreset.all.map(\.name.count).max() ?? 0
        return DevicePreset.all.map { preset in
            let agent = preset.userAgent.map(BrowserEmulation.userAgentName) ?? "WebKit"
            return [preset.id.padding(toLength: idWidth, withPad: " ", startingAt: 0),
                    preset.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0),
                    preset.size.description.padding(toLength: 10, withPad: " ", startingAt: 0),
                    agent].joined(separator: "  ") + "\n"
        }.joined()
    }
}
