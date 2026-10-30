// Portions adapted from Ghostty's macOS app (macos/Sources/Ghostty/Ghostty.App.swift),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import GhosttyKit
import UniformTypeIdentifiers
import os

let ghosttyLog = Logger(subsystem: "tokyo.n-n.cmds", category: "ghostty")

/// Owns the single process-wide `ghostty_app_t` and routes libghostty runtime callbacks
/// (wakeup, actions, clipboard, close) to the owning `GhosttySurfaceView`.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var observers: [NSObjectProtocol] = []
    /// Addresses of views that currently own a live `ghostty_surface_t`. Used to validate
    /// userdata pointers before dereferencing them (callbacks may be delivered asynchronously).
    private var liveViews = Set<UInt>()

    func register(_ view: GhosttySurfaceView) {
        liveViews.insert(UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
    }

    func unregister(_ view: GhosttySurfaceView) {
        liveViews.remove(UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
    }

    var isReady: Bool { app != nil }

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            ghosttyLog.critical("ghostty_init failed")
            return
        }

        let overrides = AppSettings.shared.ghosttyOverrides
        guard let cfg = Self.makeConfig(overrides: overrides) else {
            ghosttyLog.critical("ghostty_config_new failed")
            return
        }
        config = cfg
        appliedOverrides = overrides

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { app, target, action in GhosttyRuntime.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state,
                                             mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            ghosttyLog.critical("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.applySettings() }
        })
        observers.append(center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
            }
        })
    }

    // MARK: - Config

    /// The `AppSettings.ghosttyOverrides` the current config was built with.
    private var appliedOverrides = ""

    /// Default config + the user's ghostty config files (and their config-file includes), then the overrides from
    /// cmds › Settings… (font family/size) on top. libghostty loads config only from files, so the overrides go
    /// through a temporary file that is removed right after loading.
    private static func makeConfig(overrides: String) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        if !overrides.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmds-ghostty-overrides-\(getpid())-\(UUID().uuidString).conf")
            do {
                try Data(overrides.utf8).write(to: url, options: [.atomic])
                url.path.withCString { ghostty_config_load_file(cfg, $0) }
                try? FileManager.default.removeItem(at: url)
            } catch {
                ghosttyLog.error("ghostty overrides: \(error.localizedDescription, privacy: .public)")
            }
        }
        ghostty_config_finalize(cfg)
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                ghosttyLog.warning("ghostty config: \(String(cString: msg), privacy: .public)")
            }
        }
        return cfg
    }

    /// Rebuilds the config when the terminal settings changed and hands it to libghostty, which updates every
    /// surface. Panes zoomed with ⌘+/⌘− keep their size; ⌘0 then returns to the new size.
    func applySettings() {
        let overrides = AppSettings.shared.ghosttyOverrides
        guard let app, overrides != appliedOverrides, let cfg = Self.makeConfig(overrides: overrides) else { return }
        appliedOverrides = overrides
        ghostty_app_update_config(app, cfg) // libghostty clones what it keeps
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    private var cachedDefaultFontSize: Double?

    /// Font size of the user's Ghostty config without cmds' override (Settings shows it as the default).
    var defaultFontSize: Double {
        if let cachedDefaultFontSize { return cachedDefaultFontSize }
        var size: Float = 0
        if let cfg = Self.makeConfig(overrides: "") {
            let key = "font-size"
            _ = ghostty_config_get(cfg, &size, key, UInt(key.utf8.count))
            ghostty_config_free(cfg)
        }
        let value = size > 0 ? Double(size) : 13
        cachedDefaultFontSize = value
        return value
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Helpers

    /// Runs `body` on the main actor. Callbacks normally arrive on the main thread (during
    /// `ghostty_app_tick` or a surface call); if not, the work is hopped to main and `fallback` is returned.
    nonisolated private static func onMain<T>(_ fallback: T, _ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        DispatchQueue.main.async { _ = body() }
        return fallback
    }

    @MainActor
    static func view(fromUserdata userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata, shared.liveViews.contains(UInt(bitPattern: userdata)) else { return nil }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        return view.surface == nil ? nil : view
    }

    @MainActor
    static func view(fromSurface surface: ghostty_surface_t?) -> GhosttySurfaceView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return view(fromUserdata: ud)
    }

    // MARK: - Runtime callbacks

    nonisolated static func wakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
        }
    }

    nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        // Always deliver asynchronously: the shell will typically call `close()` (which frees the
        // surface) from the delegate, and that must not happen inside a libghostty callback.
        let ptr = userdata.map { UInt(bitPattern: $0) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ud = ptr.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                GhosttyRuntime.view(fromUserdata: ud)?.surfaceRequestedClose()
            }
        }
    }

    nonisolated static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        onMain(false) {
            GhosttyRuntime.handleAction(target: target, action: action)
        }
    }

    @MainActor
    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // App-targeted actions (quit, new window, ...) belong to the app shell: report unhandled.
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let view = view(fromSurface: target.target.surface) else {
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = action.action.set_title.title else { return false }
            view.owner?.handleTitle(String(cString: ptr))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let ptr = action.action.pwd.pwd else { return false }
            view.owner?.handlePwd(String(cString: ptr))
            return true

        case GHOSTTY_ACTION_RING_BELL:
            view.owner?.handleBell()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            view.owner?.handleNotification(title: title, body: body)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            view.setCursorVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let s = action.action.cell_size
            view.cellSizePx = CGSize(width: CGFloat(s.width), height: CGFloat(s.height))
            return true

        case GHOSTTY_ACTION_RENDER:
            view.needsDisplay = true
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let v = action.action.open_url
            guard let ptr = v.url, v.len > 0 else { return false }
            let str = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(v.len)), as: UTF8.self)
            if view.owner?.handleOpenLink(str) == true { return true } // file paths → preview pane
            let url = URL(string: str) ?? URL(fileURLWithPath: str)
            NSWorkspace.shared.open(url)
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            // Treat "close the container" requests as closing this pane; the shell decides.
            view.surfaceRequestedClose()
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Surfaces that wait after their command (SSH panes) show the app's own overlay; others let libghostty
            // print its "process exited" message in the terminal.
            guard view.waitsAfterCommand else { return false }
            view.owner?.handleChildExited()
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_COMMAND_FINISHED:
            // Informational; nothing for the shell to do yet.
            return true

        default:
            // New window/tab/split, goto_*, fullscreen, quit, inspector, etc. are owned by the app
            // shell (its menu sees those key equivalents first, see GhosttySurfaceView). Unhandled.
            return false
        }
    }

    // MARK: - Clipboard

    @MainActor
    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        default: return nil
        }
    }

    @MainActor
    private static func pasteboardString(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        return pb.string(forType: .string)
    }

    /// Backslash-escapes shell metacharacters in a path (pasting/dropping file URLs).
    nonisolated static func shellEscape(_ s: String) -> String {
        let special = Set(" \\()[]{}<>\"'`!#$&;|*?\t")
        var out = ""
        for ch in s {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    @MainActor
    private static func pasteboardData(_ pb: NSPasteboard, mime: String) -> Data? {
        if mime == "text/plain" || mime == "text/plain;charset=utf-8" {
            return pasteboardString(pb).map { Data($0.utf8) }
        }
        guard let type = UTType(mimeType: mime) else { return nil }
        return pb.data(forType: NSPasteboard.PasteboardType(type.identifier))
    }

    @MainActor
    private static func availableMimes(_ pb: NSPasteboard) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for type in pb.types ?? [] {
            var mime: String?
            if type == .string || type == .fileURL {
                mime = "text/plain"
            } else {
                mime = UTType(type.rawValue)?.preferredMIMEType
            }
            if let mime, seen.insert(mime).inserted { result.append(mime) }
        }
        return result
    }

    struct ClipboardItem {
        let mime: String
        let data: Data
    }

    nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard Thread.isMainThread else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        return MainActor.assumeIsolated {
            guard let view = view(fromUserdata: userdata), let surface = view.surface,
                  let pb = pasteboard(location) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            var items: [ClipboardItem] = []
            var seen = Set<String>()
            if let mimes {
                for i in 0..<mimesLen {
                    guard let ptr = mimes[i] else { continue }
                    let mime = String(cString: ptr)
                    guard seen.insert(mime).inserted, let data = pasteboardData(pb, mime: mime) else { continue }
                    items.append(ClipboardItem(mime: mime, data: data))
                }
            }
            let available = list ? availableMimes(pb) : []
            if items.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            completeClipboardRequest(surface, items: items, available: available, state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    nonisolated static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard let view = view(fromUserdata: userdata), let surface = view.surface else { return }
            guard let confirm else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            let c = confirm.pointee
            // Copy borrowed C data: the confirmation completes asynchronously.
            var items: [ClipboardItem] = []
            if let contents = c.contents {
                for i in 0..<c.contents_len {
                    let entry = contents[i]
                    guard let mime = entry.mime else { continue }
                    let data = (entry.len > 0 && entry.data != nil) ? Data(bytes: entry.data, count: entry.len) : Data()
                    items.append(ClipboardItem(mime: String(cString: mime), data: data))
                }
            }
            var available: [String] = []
            if let avail = c.available {
                for i in 0..<c.available_len {
                    if let p = avail[i] { available.append(String(cString: p)) }
                }
            }
            let preview = items.first(where: { $0.mime.hasPrefix("text/plain") })
                .flatMap { String(data: $0.data, encoding: .utf8) }
                ?? items.map { String(localized: "\($0.mime) (\($0.data.count) bytes)") }.joined(separator: "\n")

            let message: String
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                message = String(localized: "The text you are pasting may run commands (it contains newlines or control characters). Paste anyway?")
            default:
                message = String(localized: "A program in this terminal wants to read the clipboard. Allow it?")
            }
            view.presentConfirmation(message: message, detail: preview) { [weak view] ok in
                guard let surface = view?.surface else { return }
                if ok {
                    completeClipboardRequest(surface, items: items, available: available, state: state, confirmed: true)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
        }
    }

    @MainActor
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        items: [ClipboardItem],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for item in items {
            guard let mime = strdup(item.mime) else { continue }
            cStrings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(item.data.count, 1), alignment: 1)
            buffers.append(buf)
            item.data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buf.assumingMemoryBound(to: CChar.self), len: item.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            cStrings.append(s)
            cAvailable.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { contentsBuf in
            cAvailable.withUnsafeBufferPointer { availBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availBuf.baseAddress,
                    available_len: availBuf.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    nonisolated static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        var items: [ClipboardItem] = []
        for i in 0..<len {
            let entry = content[i]
            guard let mime = entry.mime else { continue }
            let data = (entry.len > 0 && entry.data != nil) ? Data(bytes: entry.data, count: entry.len) : Data()
            items.append(ClipboardItem(mime: String(cString: mime), data: data))
        }
        guard !items.isEmpty else { return }
        let ptr = userdata.map { UInt(bitPattern: $0) }
        let work: @MainActor () -> Void = {
            guard let pb = pasteboard(location) else { return }
            let apply = {
                pb.clearContents()
                for item in items {
                    if item.mime.hasPrefix("text/plain") {
                        pb.setString(String(decoding: item.data, as: UTF8.self), forType: .string)
                    } else if let type = UTType(mimeType: item.mime) {
                        pb.setData(item.data, forType: NSPasteboard.PasteboardType(type.identifier))
                    }
                }
            }
            if !confirm {
                apply()
                return
            }
            // OSC 52 write that requires confirmation per the user's config.
            let ud = ptr.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
            guard let view = view(fromUserdata: ud) else { return }
            let preview = items.first(where: { $0.mime.hasPrefix("text/plain") })
                .map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            view.presentConfirmation(
                message: "A program in this terminal wants to write to the clipboard. Allow it?",
                detail: preview
            ) { ok in if ok { apply() } }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }
}
