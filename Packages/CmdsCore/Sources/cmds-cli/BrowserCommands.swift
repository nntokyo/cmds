import CmdsCore
import Foundation

// `cmds browser device`: device size, user agent and color scheme of a browser pane (#168, docs/reference/cli.md).
extension CLI {
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
        let result: JSONValue
        do {
            result = try ctx.call("browser.set_viewport", browserTarget(ctx).merging(change.params) { $1 })
        } catch let error as CLIError where error.message.contains("method not found") {
            throw CLIError.failure("this cmds app has no device sizes for browser panes; update cmds")
        }
        if ctx.json { return ctx.printJSON(result) }
        print(BrowserEmulation(json: result).summary)
    }

    /// The change a command line asks for; bad values are usage errors (nothing is sent).
    static func browserViewportChange(_ args: Arguments) throws -> BrowserViewportChange {
        do {
            var change = BrowserViewportChange()
            if let device = args.positionals.first { change.size = try BrowserViewportChange.parseSize(device) }
            change.rotate = args.has("rotate")
            if let agent = args[option: "ua"] { change.userAgent = try BrowserEmulation.checkedUserAgent(agent) ?? "" }
            change.colorScheme = try args[option: "scheme"].map(BrowserViewportChange.parseColorScheme)
            return change
        } catch let error as RPCError {
            throw CLIError.usage(error.message)
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
