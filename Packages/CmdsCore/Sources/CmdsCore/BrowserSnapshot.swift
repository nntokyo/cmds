import Foundation

// Browser screenshots beyond the visible page (#169; docs/reference/api.md `browser.snapshot`): the full page, one
// element, and the page at other sizes, captured off screen.

/// A `browser.snapshot` request. Empty: the visible part of the pane, as before.
public struct BrowserSnapshotRequest: Equatable, Sendable {
    /// A size to capture the page at, off screen (the pane keeps its own).
    public struct Target: Equatable, Sendable {
        /// Preset id, or nil for a custom size.
        public var preset: DevicePreset?
        public var size: ViewportSize

        public init(preset: DevicePreset) {
            self.preset = preset
            size = preset.size
        }

        public init(size: ViewportSize) {
            preset = nil
            self.size = size
        }

        /// `iphone`, or `390x844` for a custom size (also the CLI's file name suffix).
        public var label: String { preset?.id ?? "\(size.width)x\(size.height)" }
    }

    /// The whole page, not just what the viewport shows.
    public var fullPage: Bool
    /// CSS selector of one element to capture (the first match).
    public var selector: String?
    /// Sizes to capture at; empty = the pane as it is.
    public var targets: [Target]

    /// Params `browser.snapshot` knows; anything else is refused, so a client learns that this app lacks a feature.
    public static let knownParams: Set<String> = ["pane", "workspace", "fullPage", "selector", "device", "devices",
                                                  "width", "height"]
    /// Most sizes in one request (each loads the page in its own web view, one after another).
    public static let maxTargets = 4
    /// Tallest capture in CSS pixels.
    public static let maxHeight = 16_384
    public static let maxSelectorLength = 1_000
    /// Height of a `width`-only target.
    public static let defaultHeight = 900

    public init(fullPage: Bool = false, selector: String? = nil, targets: [Target] = []) {
        self.fullPage = fullPage
        self.selector = selector
        self.targets = targets
    }

    /// Nothing beyond the old visible-page snapshot.
    public var isPlain: Bool { !fullPage && selector == nil && targets.isEmpty }

    /// A preset id or `WIDTHxHEIGHT`.
    public static func parseTarget(_ raw: String) throws -> Target {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let preset = DevicePreset.named(text) { return Target(preset: preset) }
        if let size = try ViewportSize.parse(text) { return Target(size: size) }
        throw RPCError.invalidParams("unknown device \"\(text.prefix(40))\": use a preset (\(DevicePreset.all.map(\.id).joined(separator: ", "))) or WIDTHxHEIGHT")
    }

    /// `pane?`/`workspace?` (ignored here), `fullPage?`, `selector?`, `device?` (preset or `WIDTHxHEIGHT`), `devices?`
    /// (a list of those), or `width?` (+ `height?`, default 900). Unknown params are refused.
    public init(params: JSONValue?) throws {
        self.init()
        guard let params, params != .null else { return }
        guard case .object(let object) = params else { throw RPCError.invalidParams("params must be an object") }
        if let unknown = object.keys.filter({ !Self.knownParams.contains($0) }).sorted().first {
            throw RPCError.invalidParams("browser.snapshot does not support the parameter \"\(unknown.prefix(40))\" (unsupported by this cmds app)")
        }
        func value(_ key: String) -> JSONValue? {
            if case .null? = object[key] { return nil }
            return object[key]
        }
        switch value("fullPage") {
        case nil: break
        case .bool(let flag)?: fullPage = flag
        default: throw RPCError.invalidParams("fullPage must be a boolean")
        }
        switch value("selector") {
        case nil: break
        case .string(let text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw RPCError.invalidParams("selector is empty") }
            guard trimmed.count <= Self.maxSelectorLength else { throw RPCError.invalidParams("selector is too long") }
            selector = trimmed
        default: throw RPCError.invalidParams("selector must be a string")
        }
        func integer(_ key: String) throws -> Int? {
            switch value(key) {
            case nil: return nil
            case .number(let number)? where number.rounded() == number && abs(number) < 1e6: return Int(number)
            default: throw RPCError.invalidParams("\(key) must be a whole number of CSS pixels")
            }
        }
        let given = ["device", "devices", "width"].filter { value($0) != nil }
        guard given.count <= 1 else { throw RPCError.invalidParams("give only one of device, devices and width") }
        if value("height") != nil, value("width") == nil {
            throw RPCError.invalidParams("height goes with width")
        }
        switch value("device") {
        case nil: break
        case .string(let text)?: targets = [try Self.parseTarget(text)]
        default: throw RPCError.invalidParams("device must be a string")
        }
        switch value("devices") {
        case nil: break
        case .array(let items)?:
            targets = try items.map { item in
                guard case .string(let text) = item else { throw RPCError.invalidParams("devices must be strings") }
                return try Self.parseTarget(text)
            }
            guard !targets.isEmpty else { throw RPCError.invalidParams("devices is empty") }
        case .string(let text)?:  // "iphone,ipad"
            targets = try text.split(separator: ",").map { try Self.parseTarget(String($0)) }
            guard !targets.isEmpty else { throw RPCError.invalidParams("devices is empty") }
        default: throw RPCError.invalidParams("devices must be a list of presets or WIDTHxHEIGHT")
        }
        if let width = try integer("width") {
            let size = ViewportSize(width: width, height: try integer("height") ?? Self.defaultHeight)
            try size.validate()
            targets = [Target(size: size)]
        }
        guard targets.count <= Self.maxTargets else {
            throw RPCError.invalidParams("at most \(Self.maxTargets) devices per snapshot")
        }
    }

    /// The params `init(params:)` reads back (CLI and MCP); none for a plain snapshot.
    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        if fullPage { result["fullPage"] = .bool(true) }
        if let selector { result["selector"] = .string(selector) }
        if targets.count == 1 {
            result["device"] = .string(targets[0].label)
        } else if !targets.isEmpty {
            result["devices"] = .array(targets.map { .string($0.label) })
        }
        return result
    }

    /// Pixels per CSS pixel of the image: 2 (Retina), or 1 when that would make it taller than `maxRetinaHeight`.
    public static func outputScale(cssHeight: Double) -> Double {
        cssHeight * 2 <= Double(maxRetinaHeight) ? 2 : 1
    }

    /// Tallest image made at 2× (in pixels); taller captures are made at 1× to bound memory.
    public static let maxRetinaHeight = 8_192

    /// The error for a capture taller than `maxHeight`.
    public static func tooTall(_ height: Int) -> RPCError {
        RPCError.invalidParams("the page is \(height) CSS pixels tall, over the \(maxHeight) px limit of a snapshot; capture an element (selector) instead")
    }
}

/// One image of a `browser.snapshot` answer.
public struct BrowserSnapshotImage: Equatable, Sendable {
    /// The target's label (`iphone`, `390x844`); nil for the pane as it is.
    public var device: String?
    /// Size of the captured area in CSS pixels.
    public var width: Int
    public var height: Int
    public var png: Data

    public init(device: String?, width: Int, height: Int, png: Data) {
        self.device = device
        self.width = width
        self.height = height
        self.png = png
    }

    public var json: JSONValue {
        .object([
            "device": device.map { .string($0) } ?? .null,
            "width": .number(Double(width)), "height": .number(Double(height)),
            "png_base64": .string(png.base64EncodedString()),
        ])
    }

    /// The answer: `png_base64` (the first image, what older clients read) and `images` (all of them; its presence
    /// tells a client that the app knows the #169 params).
    public static func result(_ images: [BrowserSnapshotImage]) -> JSONValue {
        .object([
            "png_base64": .string(images.first?.png.base64EncodedString() ?? ""),
            "images": .array(images.map(\.json)),
        ])
    }

    /// Reads `result` back; nil when it has no `images` (an app older than #169, which ignored the new params).
    public static func images(from result: JSONValue) -> [BrowserSnapshotImage]? {
        guard let items = result["images"]?.arrayValue else { return nil }
        return items.compactMap { item in
            guard let base64 = item["png_base64"]?.stringValue, let png = Data(base64Encoded: base64) else { return nil }
            return BrowserSnapshotImage(device: item["device"]?.stringValue, width: item["width"]?.intValue ?? 0,
                                        height: item["height"]?.intValue ?? 0, png: png)
        }
    }

    /// What clients say when an older app answers a request with new params without `images`.
    public static let unsupportedMessage = "this cmds app does not support full-page, element or device snapshots (it returned only the visible page); update cmds"
}
