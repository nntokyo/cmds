import AppKit
import CmdsCore
import CryptoKit

/// Sidebar text size (cmds › Settings… › Sidebar): scales the sidebar row fonts and heights, the footer and the rail.
enum SidebarTextSize: String, CaseIterable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .medium: return 1
        case .large: return 1.18
        }
    }

    var title: String {
        switch self {
        case .small: return String(localized: "Small", comment: "sidebar text size")
        case .medium: return String(localized: "Medium", comment: "sidebar text size")
        case .large: return String(localized: "Large", comment: "sidebar text size")
        }
    }
}

/// User settings (cmds › Settings…). Stored in `UserDefaults.standard`; an isolated instance (`CMDS_SUPPORT_DIR`)
/// uses its own suite (`isolatedSuiteName`), so tests never change the user's settings. Changes made by another
/// process (`defaults write <suite> TerminalFontSize -float 18`) are picked up live as well.
/// Every change posts `didChange` (coalesced, main thread); consumers compare with what they applied.
@MainActor
final class AppSettings: NSObject {
    static let shared = AppSettings()
    static let didChange = Notification.Name("AppSettingsDidChange")

    static let terminalFontFamilyKey = "TerminalFontFamily"
    static let terminalFontSizeKey = "TerminalFontSize"
    static let sidebarTextSizeKey = "SidebarTextSize"
    static let browserZoomKey = "BrowserPageZoom"
    static let previewZoomKey = "PreviewPageZoom"
    private static let keys = [terminalFontFamilyKey, terminalFontSizeKey, sidebarTextSizeKey, browserZoomKey, previewZoomKey]

    static let fontSizeRange: ClosedRange<Double> = 6...72
    static let zoomRange: ClosedRange<Double> = 0.5...3

    let defaults: UserDefaults
    /// Suite name of an isolated instance, nil for the user's own settings.
    let suiteName: String?
    private var changePending = false

    override init() {
        if let dir = CmdsEnv.supportDirectoryOverride() {
            let name = Self.isolatedSuiteName(supportDirectory: dir)
            suiteName = name
            defaults = UserDefaults(suiteName: name) ?? .standard
        } else {
            suiteName = nil
            defaults = .standard
        }
        super.init()
        for key in Self.keys { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    /// `tokyo.n-n.cmds.isolated.<first 16 hex digits of SHA-256 of the support directory path>`.
    nonisolated static func isolatedSuiteName(supportDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(supportDirectory.utf8))
        return "tokyo.n-n.cmds.isolated." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // KVO fires on the thread that wrote the value (any thread for other processes): coalesce onto main.
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppSettings.shared.scheduleChange() }
        }
    }

    private func scheduleChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [self] in
            changePending = false
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    // MARK: - Values

    /// Font family for terminals; nil = the Ghostty config's (or Ghostty's default) font.
    var terminalFontFamily: String? {
        get { defaults.string(forKey: Self.terminalFontFamilyKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { set(newValue, forKey: Self.terminalFontFamilyKey) }
    }

    /// Font size in points for terminals; nil = the Ghostty config's size.
    var terminalFontSize: Double? {
        get {
            guard let value = (defaults.object(forKey: Self.terminalFontSizeKey) as? NSNumber)?.doubleValue,
                  value > 0, value.isFinite else { return nil }
            return min(max(value, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        }
        set { set(newValue, forKey: Self.terminalFontSizeKey) }
    }

    var sidebarTextSize: SidebarTextSize {
        get { defaults.string(forKey: Self.sidebarTextSizeKey).flatMap(SidebarTextSize.init(rawValue:)) ?? .medium }
        set { set(newValue == .medium ? nil : newValue.rawValue, forKey: Self.sidebarTextSizeKey) }
    }

    /// Default page zoom of browser panes (1 = 100 %).
    var browserZoom: Double {
        get { zoom(forKey: Self.browserZoomKey) }
        set { set(newValue == 1 ? nil : newValue, forKey: Self.browserZoomKey) }
    }

    /// Default zoom of rendered previews (Markdown, diffs, text).
    var previewZoom: Double {
        get { zoom(forKey: Self.previewZoomKey) }
        set { set(newValue == 1 ? nil : newValue, forKey: Self.previewZoomKey) }
    }

    private func zoom(forKey key: String) -> Double {
        guard let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue, value > 0, value.isFinite else { return 1 }
        return min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func set(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: - Ghostty overrides

    /// Lines layered over the user's Ghostty config (empty when nothing is overridden). Values are written without
    /// quotes or newlines a config line could not hold.
    var ghosttyOverrides: String {
        var lines: [String] = []
        if let family = terminalFontFamily?.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces), !family.isEmpty {
            // An empty value clears the font-family list (the user's config may have several), then ours.
            lines += ["font-family = \"\"", "font-family = \"\(family)\""]
        }
        if let size = terminalFontSize {
            lines.append("font-size = \(Self.format(size))")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }
}

extension SidebarTextSize {
    /// Current scale (main thread: sidebar layout).
    @MainActor static var scale: CGFloat { AppSettings.shared.sidebarTextSize.scale }

    /// `points` scaled for the current sidebar text size, rounded to half points.
    @MainActor static func size(_ points: CGFloat) -> CGFloat { (points * scale * 2).rounded() / 2 }
}

/// View › Bigger / Smaller / Actual Size (⌘+ / ⌘− / ⌘0) go to the first responder: a terminal changes its font size
/// (libghostty's `increase_font_size` / `decrease_font_size` / `reset_font_size`), browser and preview panes their
/// page zoom. The items are disabled when nothing in the responder chain handles them, so the keys then still reach
/// libghostty's own bindings.
@MainActor @objc protocol TextSizeActions {
    func cmdsTextBigger(_ sender: Any?)
    func cmdsTextSmaller(_ sender: Any?)
    func cmdsTextActualSize(_ sender: Any?)
}

/// Page zoom steps for ⌘+ / ⌘− in browser and preview panes (Safari's).
enum PageZoomSteps {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func bigger(_ zoom: Double) -> Double { steps.first { $0 > zoom + 0.001 } ?? steps.last! }
    static func smaller(_ zoom: Double) -> Double { steps.last { $0 < zoom - 0.001 } ?? steps.first! }
}
