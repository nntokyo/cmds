import Foundation

// Device sizes and color scheme of browser panes (#168; docs/guide/workspaces-and-panes.md "Device sizes").
// Screenshots at several sizes (#169) and the responsive view (#170) use the same presets.

/// A layout size in CSS pixels.
public struct ViewportSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    /// Sizes the app accepts, in CSS pixels (either side).
    public static let range = 100...4096

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var rotated: ViewportSize { ViewportSize(width: height, height: width) }
    public var isLandscape: Bool { width > height }
    /// `390×844`.
    public var description: String { "\(width)×\(height)" }

    /// The scale that fits this size into `width`×`height` points, never above 1 (a larger pane shows it at 100%).
    public func scaleToFit(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return min(1, width / Double(self.width), height / Double(self.height))
    }

    /// `WIDTHxHEIGHT` (`x`, `X` or `×`), each side within `range`; nil when the text is not of that form.
    public static func parse(_ text: String) throws -> ViewportSize? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "x" || $0 == "×" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        let size = ViewportSize(width: width, height: height)
        try size.validate()
        return size
    }

    public func validate() throws {
        guard Self.range.contains(width), Self.range.contains(height) else {
            throw RPCError.invalidParams("width and height must be \(Self.range.lowerBound)–\(Self.range.upperBound) CSS pixels (got \(width)×\(height))")
        }
    }
}

/// A device size offered in the browser pane's Device menu, `cmds browser device` and `browser.set_viewport`.
/// Sizes are the devices' CSS layout sizes, portrait for phones and tablets.
public struct DevicePreset: Equatable, Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable { case phone, tablet, desktop }

    public let id: String
    public let name: String
    public let category: Category
    public let size: ViewportSize
    /// The real device's pixel ratio, for information: WKWebView keeps the Mac's (docs: "What is not emulated").
    public let pixelRatio: Double
    /// Sent with the size; nil keeps WebKit's own (desktop sizes).
    public let userAgent: String?

    public static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    public static let androidUserAgent = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
    /// iPadOS Safari presents itself as Safari on a Mac by default.
    public static let iPadUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public static let all: [DevicePreset] = [
        DevicePreset(id: "iphone-se", name: "iPhone SE", category: .phone, size: .init(width: 375, height: 667),
                     pixelRatio: 2, userAgent: iPhoneUserAgent),
        DevicePreset(id: "iphone", name: "iPhone 16", category: .phone, size: .init(width: 393, height: 852),
                     pixelRatio: 3, userAgent: iPhoneUserAgent),
        DevicePreset(id: "iphone-pro-max", name: "iPhone 16 Pro Max", category: .phone, size: .init(width: 440, height: 956),
                     pixelRatio: 3, userAgent: iPhoneUserAgent),
        DevicePreset(id: "pixel", name: "Pixel 7", category: .phone, size: .init(width: 412, height: 915),
                     pixelRatio: 2.625, userAgent: androidUserAgent),
        DevicePreset(id: "ipad", name: "iPad Air", category: .tablet, size: .init(width: 820, height: 1180),
                     pixelRatio: 2, userAgent: iPadUserAgent),
        DevicePreset(id: "ipad-landscape", name: "iPad Air (landscape)", category: .tablet,
                     size: .init(width: 1180, height: 820), pixelRatio: 2, userAgent: iPadUserAgent),
        DevicePreset(id: "desktop-1280", name: "Laptop 1280", category: .desktop, size: .init(width: 1280, height: 800),
                     pixelRatio: 2, userAgent: nil),
        DevicePreset(id: "desktop-1440", name: "Desktop 1440", category: .desktop, size: .init(width: 1440, height: 900),
                     pixelRatio: 2, userAgent: nil),
        DevicePreset(id: "desktop-1920", name: "Desktop 1920", category: .desktop, size: .init(width: 1920, height: 1080),
                     pixelRatio: 1, userAgent: nil),
    ]

    /// Phone, tablet and desktop: the default set when several sizes are shown or captured at once (#169, #170).
    public static let responsiveSet: [DevicePreset] = ["iphone", "ipad", "desktop-1440"].compactMap(named)

    /// The preset with this id (case-insensitive; `iphone_se` and `iPhone SE` also match).
    public static func named(_ raw: String) -> DevicePreset? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        return all.first { $0.id == key || $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == key }
    }
}

/// How a browser pane shows pages: `system` follows the Mac's light / dark setting (System Settings › Appearance).
public enum BrowserColorScheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// A browser pane's device size, user agent and color scheme, kept per pane in session.json and export bundles
/// (optional keys; older cmds ignore them). The default (all nil) fills the pane with WebKit's user agent.
public struct BrowserEmulation: Codable, Equatable, Sendable {
    /// Preset the size came from (also after rotating it); nil for a custom size.
    public var device: String?
    /// Fixed layout size in CSS pixels; nil fills the pane.
    public var size: ViewportSize?
    /// nil = WebKit's own.
    public var userAgent: String?
    /// nil = follow the Mac.
    public var colorScheme: BrowserColorScheme?

    /// Longest user agent accepted.
    public static let maxUserAgentLength = 512

    public init(device: String? = nil, size: ViewportSize? = nil, userAgent: String? = nil,
                colorScheme: BrowserColorScheme? = nil) {
        self.device = device
        self.size = size
        self.userAgent = userAgent
        self.colorScheme = colorScheme
    }

    public var isDefault: Bool { self == BrowserEmulation() }
    public var preset: DevicePreset? { device.flatMap(DevicePreset.named) }
    /// The scheme to apply (nil reads as `system`).
    public var scheme: BrowserColorScheme { colorScheme ?? .system }

    /// The settings with every value checked (sizes in range, known preset and scheme, a user agent without control
    /// characters); `system` is stored as nil. Session restore and bundle import use it.
    public func validated() throws -> BrowserEmulation {
        var result = self
        try result.size?.validate()
        if let device, DevicePreset.named(device) == nil {
            throw RPCError.invalidParams("unknown device \"\(device.prefix(40))\"")
        }
        result.device = preset?.id
        if result.size == nil { result.device = nil }
        result.userAgent = try Self.checkedUserAgent(userAgent)
        if result.colorScheme == .system { result.colorScheme = nil }
        return result
    }

    /// nil for nil or empty (WebKit's own); refuses control characters and overlong text.
    public static func checkedUserAgent(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxUserAgentLength else { throw RPCError.invalidParams("userAgent is too long") }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw RPCError.invalidParams("userAgent contains control characters")
        }
        return trimmed
    }

    /// The `browser.set_viewport` result (also `--json`): every key present, `null` when not set.
    public var json: JSONValue {
        .object([
            "device": device.map { .string($0) } ?? .null,
            "width": size.map { .number(Double($0.width)) } ?? .null,
            "height": size.map { .number(Double($0.height)) } ?? .null,
            "userAgent": userAgent.map { .string($0) } ?? .null,
            "colorScheme": .string(scheme.rawValue),
        ])
    }

    /// Reads `json` back (the CLI and MCP summarize the app's answer); unknown values read as unset.
    public init(json: JSONValue) {
        let size: ViewportSize? = {
            guard let width = json["width"]?.intValue, let height = json["height"]?.intValue else { return nil }
            return ViewportSize(width: width, height: height)
        }()
        let scheme = json["colorScheme"]?.stringValue.flatMap(BrowserColorScheme.init(rawValue:))
        self.init(device: json["device"]?.stringValue, size: size, userAgent: json["userAgent"]?.stringValue,
                  colorScheme: scheme == .system ? nil : scheme)
    }

    /// `iPhone Safari`, `Android Chrome`, `Mac Safari` for the presets' user agents, else `custom`.
    public static func userAgentName(_ userAgent: String) -> String {
        switch userAgent {
        case DevicePreset.iPhoneUserAgent: "iPhone Safari"
        case DevicePreset.androidUserAgent: "Android Chrome"
        case DevicePreset.iPadUserAgent: "Mac Safari"
        default: "custom"
        }
    }

    /// One line for the CLI and MCP: `iPhone SE 375×667, iPhone user agent, color scheme dark`.
    public var summary: String {
        var parts: [String] = []
        if let size {
            parts.append([preset?.name, size.description].compactMap { $0 }.joined(separator: " ")
                + (preset.map { $0.size != size ? " (rotated)" : "" } ?? ""))
        } else {
            parts.append("fills the pane")
        }
        if let userAgent { parts.append("user agent \(Self.userAgentName(userAgent))") }
        parts.append("color scheme \(scheme.rawValue)")
        return parts.joined(separator: ", ")
    }
}

/// One `browser.set_viewport` request: only what it names changes.
public struct BrowserViewportChange: Equatable, Sendable {
    public enum Size: Equatable, Sendable {
        /// Fill the pane again (`off`).
        case fill
        case preset(DevicePreset)
        case custom(ViewportSize)
    }

    public var size: Size?
    /// Swap width and height (after `size`, if both are given).
    public var rotate: Bool
    /// nil leaves it; "" = WebKit's own. Without it a new `size` brings the preset's user agent (custom sizes and
    /// `fill`: WebKit's own).
    public var userAgent: String?
    public var colorScheme: BrowserColorScheme?

    public init(size: Size? = nil, rotate: Bool = false, userAgent: String? = nil, colorScheme: BrowserColorScheme? = nil) {
        self.size = size
        self.rotate = rotate
        self.userAgent = userAgent
        self.colorScheme = colorScheme
    }

    public var isEmpty: Bool { size == nil && !rotate && userAgent == nil && colorScheme == nil }

    /// A preset id, `WIDTHxHEIGHT`, or `off` / `fill` / `none`.
    public static func parseSize(_ raw: String) throws -> Size {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if ["off", "fill", "none", "responsive"].contains(text.lowercased()) { return .fill }
        if let preset = DevicePreset.named(text) { return .preset(preset) }
        if let size = try ViewportSize.parse(text) { return .custom(size) }
        throw RPCError.invalidParams("unknown device \"\(text.prefix(40))\": use a preset (\(DevicePreset.all.map(\.id).joined(separator: ", "))), WIDTHxHEIGHT or off")
    }

    public static func parseColorScheme(_ raw: String) throws -> BrowserColorScheme {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "auto" || text == "follow" { return .system }
        guard let scheme = BrowserColorScheme(rawValue: text) else {
            throw RPCError.invalidParams("colorScheme must be \"light\", \"dark\" or \"system\"")
        }
        return scheme
    }

    /// From `browser.set_viewport` params: `device?` (preset id, `WIDTHxHEIGHT` or `off`), or `width?` + `height?`;
    /// `rotate?`, `userAgent?`, `colorScheme?` (`light` / `dark` / `system`). `pane` / `workspace` are ignored here.
    public init(params: JSONValue?) throws {
        func string(_ key: String) throws -> String? {
            switch params?[key] {
            case nil, .null?: return nil
            case .string(let value)?: return value
            default: throw RPCError.invalidParams("\(key) must be a string")
            }
        }
        func integer(_ key: String) throws -> Int? {
            switch params?[key] {
            case nil, .null?: return nil
            case .number(let value)? where value.rounded() == value && abs(value) < 1e6: return Int(value)
            default: throw RPCError.invalidParams("\(key) must be a whole number of CSS pixels")
            }
        }
        self.init()
        let width = try integer("width"), height = try integer("height")
        if let device = try string("device") {
            guard width == nil, height == nil else { throw RPCError.invalidParams("give either device or width and height") }
            size = try Self.parseSize(device)
        } else if width != nil || height != nil {
            guard let width, let height else { throw RPCError.invalidParams("width and height go together") }
            let custom = ViewportSize(width: width, height: height)
            try custom.validate()
            size = .custom(custom)
        }
        switch params?["rotate"] {
        case nil, .null?: break
        case .bool(let value)?: rotate = value
        default: throw RPCError.invalidParams("rotate must be a boolean")
        }
        if let agent = try string("userAgent") {
            userAgent = try BrowserEmulation.checkedUserAgent(agent) ?? ""
        }
        colorScheme = try string("colorScheme").map(Self.parseColorScheme)
    }

    /// The params `init(params:)` reads back (CLI and MCP).
    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        switch size {
        case nil: break
        case .fill?: result["device"] = "off"
        case .preset(let preset)?: result["device"] = .string(preset.id)
        case .custom(let custom)?:
            result["width"] = .number(Double(custom.width))
            result["height"] = .number(Double(custom.height))
        }
        if rotate { result["rotate"] = .bool(true) }
        if let userAgent { result["userAgent"] = .string(userAgent) }
        if let colorScheme { result["colorScheme"] = .string(colorScheme.rawValue) }
        return result
    }

    /// `current` with this change applied. Rotating needs a size (a preset or custom one).
    public func applied(to current: BrowserEmulation) throws -> BrowserEmulation {
        var result = current
        switch size {
        case nil: break
        case .fill?:
            result.device = nil
            result.size = nil
            result.userAgent = nil
        case .preset(let preset)?:
            result.device = preset.id
            result.size = preset.size
            result.userAgent = preset.userAgent
        case .custom(let custom)?:
            result.device = nil
            result.size = custom
            result.userAgent = nil
        }
        if rotate {
            guard let size = result.size else {
                throw RPCError.invalidParams("nothing to rotate: the pane has no device size (choose one first)")
            }
            result.size = size.rotated
        }
        if let userAgent { result.userAgent = userAgent.isEmpty ? nil : userAgent }
        if let colorScheme { result.colorScheme = colorScheme == .system ? nil : colorScheme }
        return result
    }
}

/// Width breakpoints of a page's media queries, for the browser toolbar's indicator.
public enum Breakpoints {
    /// Page script (any content world) returning `{"width": innerWidth, "queries": [media query text…]}` from every
    /// readable style sheet (cross-origin sheets without CORS cannot be read and are skipped).
    public static let pageScript = """
        const queries = [];
        const visit = (rules) => {
          for (const rule of rules) {
            try {
              if (rule.media && rule.media.mediaText) queries.push(rule.media.mediaText);
              if (rule.styleSheet) visit(rule.styleSheet.cssRules);
              if (rule.cssRules) visit(rule.cssRules);
            } catch (e) {}
          }
        };
        for (const sheet of document.styleSheets) {
          try {
            if (sheet.media && sheet.media.mediaText) queries.push(sheet.media.mediaText);
            visit(sheet.cssRules);
          } catch (e) {}
        }
        return { width: window.innerWidth, queries: [...new Set(queries)].slice(0, 2000) };
        """

    /// Pixels per `em` / `rem` in media queries (the initial font size, not the page's).
    static let pixelsPerEm = 16.0

    /// Width conditions of media queries (Level 3 `min-`/`max-width` and Level 4 ranges) and their threshold.
    private static let widthPatterns: [(NSRegularExpression, @Sendable (Double) -> Int)] = {
        let number = #"(-?\d+(?:\.\d+)?)\s*(px|em|rem)?"#
        let from: @Sendable (Double) -> Int = { Int($0.rounded(.up)) }  // the value is the first width of the upper side
        let after: @Sendable (Double) -> Int = { Int($0.rounded(.down)) + 1 }  // the value is the last width below
        let patterns: [(String, @Sendable (Double) -> Int)] = [
            (#"min-width\s*:\s*"# + number, from), (#"max-width\s*:\s*"# + number, after),
            (#"\bwidth\s*>=\s*"# + number, from), (#"\bwidth\s*>\s*"# + number, after),
            (#"\bwidth\s*<=\s*"# + number, after), (#"\bwidth\s*<\s*"# + number, from),
            (number + #"\s*<=\s*width\b"#, from), (number + #"\s*<\s*width\b"#, after),
            (number + #"\s*>=\s*width\b"#, after), (number + #"\s*>\s*width\b"#, from),
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    /// The widths at which a layout switches (the CSS width from which the larger side applies), sorted and unique:
    /// `min-width: 768px` → 768, `max-width: 767px` → 768, `width < 768px` → 768, `width <= 767.98px` → 768.
    public static func thresholds(fromMediaQueries queries: [String]) -> [Int] {
        var found = Set<Int>()
        for query in Set(queries) {
            let text = query.lowercased()
            guard text.contains("width") else { continue }
            for (regex, threshold) in widthPatterns {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    // `device-width` (`min-device-width` never matches) is the screen, not the viewport.
                    if let whole = Range(match.range, in: text), text[..<whole.lowerBound].hasSuffix("device-") { continue }
                    guard let valueRange = Range(match.range(at: 1), in: text), var value = Double(text[valueRange]) else { continue }
                    if let unitRange = Range(match.range(at: 2), in: text), text[unitRange] != "px" { value *= pixelsPerEm }
                    let width = threshold(value)
                    if width > 0 { found.insert(width) }
                }
            }
        }
        return found.sorted()
    }

    /// The breakpoint range `width` falls in: the largest threshold at or below it and the next one above.
    public static func range(width: Int, thresholds: [Int]) -> (lower: Int?, upper: Int?) {
        (thresholds.last { $0 <= width }, thresholds.first { $0 > width })
    }

    /// `768–1023`, `≥1280`, `<640`; nil when the page has no width breakpoints.
    public static func label(width: Int, thresholds: [Int]) -> String? {
        switch range(width: width, thresholds: thresholds) {
        case (nil, nil): return nil
        case (let lower?, nil): return "≥\(lower)"
        case (nil, let upper?): return "<\(upper)"
        case (let lower?, let upper?): return "\(lower)–\(upper - 1)"
        }
    }
}
