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

/// A switch in Settings that stays on until the user turns it off; its raw value is the defaults key (#108).
protocol OnByDefaultOption: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    /// The checkbox title in Settings.
    var title: String { get }
}

/// Parts of the menu bar item (#95) the user can turn off in Settings › Menu Bar (#105). The orange badge for the
/// workspaces that need the user is the item's purpose and always shows. Raw values are the defaults keys.
enum MenuBarOption: String, OnByDefaultOption {
    /// Icon: the blue badge with how many agents work.
    case workingBadge = "MenuBarWorkingBadge"
    /// Icon: the red dot for a limit at 95 % or critical memory pressure.
    case warningDot = "MenuBarWarningDot"
    /// Icon: the arc around the working badge turns.
    case animation = "AnimateMenuBar"
    /// Menu: CPU and memory rings.
    case systemRings = "MenuBarSystemRings"
    /// Menu: Claude Code / Codex limit rings.
    case limitRings = "MenuBarLimitRings"
    /// Menu: the context window of each agent (ctx).
    case contextRings = "MenuBarContextRings"
    /// Menu: the workspaces with an agent.
    case workspaces = "MenuBarWorkspaces"
    /// Menu: choosing a workspace opens the reply panel instead of bringing cmds forward (#213).
    case replyPanel = "MenuBarReplyPanel"

    var title: String {
        switch self {
        case .workingBadge: return String(localized: "Number of agents working", comment: "Settings › Menu Bar › Icon")
        case .warningDot: return String(localized: "Red dot when a limit or memory runs short", comment: "Settings › Menu Bar › Icon")
        case .animation: return String(localized: "Animate while agents work")
        case .systemRings: return String(localized: "CPU and memory", comment: "Settings › Menu Bar › Menu")
        case .limitRings: return String(localized: "AI limits (Claude Code, Codex)", comment: "Settings › Menu Bar › Menu")
        case .contextRings: return String(localized: "Context of each agent (ctx)", comment: "Settings › Menu Bar › Menu")
        case .workspaces: return String(localized: "Workspaces with agents", comment: "Settings › Menu Bar › Menu")
        case .replyPanel: return String(localized: "Reply from the menu bar", comment: "Settings › Menu Bar › Menu")
        }
    }
}

/// What the sidebar shows, chosen in Settings › Sidebar (#107); all on by default. Raw values are the defaults keys.
/// The workspace title, its state badge and the agent's task always show.
enum SidebarItem: String, OnByDefaultOption {
    case branch = "SidebarShowsBranch"
    case directory = "SidebarShowsDirectory"
    case ports = "SidebarShowsPorts"
    /// The agent's model, context and cost lines.
    case agentUsage = "SidebarShowsAgentUsage"
    case notification = "SidebarShowsNotification"
    /// Footer: the Claude Code / Codex limit meters.
    case footerLimits = "SidebarFooterLimits"
    /// Footer: CPU and memory.
    case footerSystem = "SidebarFooterSystem"

    static let rowItems: [SidebarItem] = [.branch, .directory, .ports, .agentUsage, .notification]
    static let footerItems: [SidebarItem] = [.footerLimits, .footerSystem]

    var title: String {
        switch self {
        case .branch: return String(localized: "Git branch", comment: "Settings › Sidebar › Show in each workspace")
        case .directory: return String(localized: "Directory", comment: "Settings › Sidebar › Show in each workspace")
        case .ports: return String(localized: "Listening ports", comment: "Settings › Sidebar › Show in each workspace")
        case .agentUsage: return String(localized: "Agent model, context and cost", comment: "Settings › Sidebar › Show in each workspace")
        case .notification: return String(localized: "Latest notification", comment: "Settings › Sidebar › Show in each workspace")
        case .footerLimits: return String(localized: "AI limits (Claude Code, Codex)", comment: "Settings › Menu Bar › Menu")
        case .footerSystem: return String(localized: "CPU and memory", comment: "Settings › Menu Bar › Menu")
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
    static let showSubagentsKey = "ShowSubagents"
    static let showInMenuBarKey = "ShowInMenuBar"
    static let browserInspectableKey = "BrowserInspectable"
    static let memoryWarningKey = "MemoryWarning"
    private static let keys = [terminalFontFamilyKey, terminalFontSizeKey, sidebarTextSizeKey, browserZoomKey, previewZoomKey,
                               showSubagentsKey, showInMenuBarKey, browserInspectableKey, memoryWarningKey] + MenuBarOption.allCases.map(\.rawValue)
        + SidebarItem.allCases.map(\.rawValue)

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

    /// Where Claude Code subagents are shown as cards (Settings › Agents, View › Show Subagents).
    var showSubagents: SubagentDisplay {
        get { defaults.string(forKey: Self.showSubagentsKey).flatMap(SubagentDisplay.init(rawValue:)) ?? .tiled }
        set { set(newValue == .tiled ? nil : newValue.rawValue, forKey: Self.showSubagentsKey) }
    }

    /// The menu bar item with the workspaces waiting for the user (Settings › Agents, #95). On by default, except in
    /// an isolated instance, whose item would sit next to the user's own.
    var showInMenuBar: Bool {
        get { defaults.object(forKey: Self.showInMenuBarKey) as? Bool ?? (suiteName == nil) }
        set { set(newValue == (suiteName == nil) ? nil : newValue, forKey: Self.showInMenuBarKey) }
    }

    /// Browser panes can be inspected with Safari's Web Inspector (Safari › Develop › this Mac; `isInspectable`, #167).
    /// Off by default.
    var browserInspectable: Bool {
        get { defaults.bool(forKey: Self.browserInspectableKey) }
        set { set(newValue ? true : nil, forKey: Self.browserInspectableKey) }
    }

    /// A notification when memory pressure stays at warning or worse for a minute (Settings › General, #193).
    /// On by default; only "off" is stored.
    var memoryWarning: Bool {
        get { defaults.object(forKey: Self.memoryWarningKey) as? Bool ?? true }
        set { set(newValue ? nil : false, forKey: Self.memoryWarningKey) }
    }

    /// An on-by-default switch (Settings › Sidebar, Settings › Menu Bar); only "off" is stored.
    func isOn<Option: OnByDefaultOption>(_ option: Option) -> Bool {
        defaults.object(forKey: option.rawValue) as? Bool ?? true
    }

    func set<Option: OnByDefaultOption>(_ option: Option, on: Bool) {
        set(on ? nil : false, forKey: option.rawValue)
    }

    /// One part of the sidebar the user can turn off (Settings › Sidebar, #107).
    func sidebar(_ item: SidebarItem) -> Bool { isOn(item) }

    /// One part of the menu bar item the user can turn off (Settings › Menu Bar, #105).
    func menuBar(_ option: MenuBarOption) -> Bool { isOn(option) }

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
