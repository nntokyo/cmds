import Foundation

// The responsive view of a browser pane (#170; docs/guide/workspaces-and-panes.md "Responsive view"): the pane's page
// in 2–4 frames of different sizes side by side, navigation and scrolling kept in step.

/// A browser pane's responsive view, kept per pane in session.json and export bundles (optional keys; older cmds
/// ignore them and show the page once).
public struct BrowserResponsive: Codable, Equatable, Sendable {
    /// Frame sizes, left to right: preset ids or `WIDTHxHEIGHT`.
    public var devices: [String]
    /// Scrolling one frame scrolls the others to the same proportion of their page. nil = on.
    public var syncScroll: Bool?

    public static let frameCount = 2...4
    /// Phone, tablet, desktop.
    public static let defaultDevices = DevicePreset.responsiveSet.map(\.id)

    public init(devices: [String] = BrowserResponsive.defaultDevices, syncScroll: Bool? = nil) {
        self.devices = devices
        self.syncScroll = syncScroll
    }

    public var scrollSynced: Bool { syncScroll ?? true }

    /// The frames' sizes (a preset's or the given one).
    public func targets() throws -> [BrowserSnapshotRequest.Target] {
        try devices.map(BrowserSnapshotRequest.parseTarget)
    }

    /// Checked: 2–4 known presets or sizes in range; normalized preset ids, `syncScroll` true stored as nil.
    public func validated() throws -> BrowserResponsive {
        guard Self.frameCount.contains(devices.count) else {
            throw RPCError.invalidParams("a responsive view has \(Self.frameCount.lowerBound)–\(Self.frameCount.upperBound) devices (got \(devices.count))")
        }
        return BrowserResponsive(devices: try targets().map(\.label), syncScroll: scrollSynced ? nil : false)
    }

    public var json: JSONValue {
        .object(["on": true, "devices": .array(devices.map { .string($0) }), "syncScroll": .bool(scrollSynced)])
    }

    public static let offJSON: JSONValue = .object(["on": false, "devices": .array([]), "syncScroll": .bool(true)])

    /// One line for the CLI and MCP.
    public static func summary(_ json: JSONValue) -> String {
        guard json["on"]?.boolValue == true else { return "responsive view off" }
        let devices = json["devices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return "responsive view: \(devices.joined(separator: ", "))"
            + (json["syncScroll"]?.boolValue == false ? " (scrolling not synced)" : "")
    }
}

/// One `browser.set_responsive` request.
public struct BrowserResponsiveChange: Equatable, Sendable {
    /// nil leaves it; false turns the view off.
    public var on: Bool?
    public var devices: [String]?
    public var syncScroll: Bool?

    public init(on: Bool? = nil, devices: [String]? = nil, syncScroll: Bool? = nil) {
        self.on = on
        self.devices = devices
        self.syncScroll = syncScroll
    }

    /// `on?`, `devices?` (a list or `"a,b,c"`; giving them turns the view on), `syncScroll?`. `pane`/`workspace` are
    /// ignored here.
    public init(params: JSONValue?) throws {
        self.init()
        switch params?["on"] {
        case nil, .null?: break
        case .bool(let flag)?: on = flag
        default: throw RPCError.invalidParams("on must be a boolean")
        }
        switch params?["devices"] {
        case nil, .null?: break
        case .array(let items)?:
            devices = try items.map {
                guard case .string(let text) = $0 else { throw RPCError.invalidParams("devices must be strings") }
                return text
            }
        case .string(let text)?: devices = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: throw RPCError.invalidParams("devices must be a list of presets or WIDTHxHEIGHT")
        }
        switch params?["syncScroll"] {
        case nil, .null?: break
        case .bool(let flag)?: syncScroll = flag
        default: throw RPCError.invalidParams("syncScroll must be a boolean")
        }
        if on == false, devices != nil { throw RPCError.invalidParams("devices with on: false") }
        if let devices { _ = try BrowserResponsive(devices: devices).validated() }
    }

    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        if let on { result["on"] = .bool(on) }
        if let devices { result["devices"] = .array(devices.map { .string($0) }) }
        if let syncScroll { result["syncScroll"] = .bool(syncScroll) }
        return result
    }

    /// The settings after this change; nil = off. Devices or `syncScroll` alone turn the view on.
    public func applied(to current: BrowserResponsive?) throws -> BrowserResponsive? {
        if on == false { return nil }
        guard on == true || devices != nil || syncScroll != nil || current != nil else { return nil }
        var result = current ?? BrowserResponsive()
        if let devices { result.devices = devices }
        if let syncScroll { result.syncScroll = syncScroll }
        return try result.validated()
    }
}

/// Proportional scroll sync: pages of different widths have different heights, so a frame is scrolled to the same
/// fraction of its scrollable height (0 = top, 1 = bottom) as the frame the user scrolled.
public enum ResponsiveScroll {
    public static func fraction(scrollY: Double, documentHeight: Double, viewportHeight: Double) -> Double {
        let range = documentHeight - viewportHeight
        guard range > 0 else { return 0 }
        return min(max(scrollY / range, 0), 1)
    }

    public static func scrollY(fraction: Double, documentHeight: Double, viewportHeight: Double) -> Double {
        max(documentHeight - viewportHeight, 0) * min(max(fraction, 0), 1)
    }

    /// Script for cmds' content world in every frame: reports `{fraction}` to the `cmdsResponsiveScroll` handler
    /// when the user scrolls (once per frame), and defines `__cmdsScrollTo(fraction)`, whose own scroll is not
    /// reported back.
    public static let frameScript = """
        (() => {
          if (window.__cmdsScrollTo) return;
          let ignoreUntil = 0, pending = false;
          const range = () => Math.max(document.documentElement.scrollHeight - window.innerHeight, 0);
          window.__cmdsScrollTo = (fraction) => {
            ignoreUntil = Date.now() + 150;
            window.scrollTo(window.scrollX, range() * fraction);
          };
          window.addEventListener('scroll', () => {
            if (Date.now() < ignoreUntil || pending) return;
            pending = true;
            // A timer, not requestAnimationFrame: WebKit stops animation frames while the window is covered.
            setTimeout(() => {
              pending = false;
              const r = range();
              const handler = window.webkit && window.webkit.messageHandlers.cmdsResponsiveScroll;
              if (handler) handler.postMessage({ fraction: r > 0 ? window.scrollY / r : 0 });
            }, 50);
          }, { passive: true });
        })();
        """
}
