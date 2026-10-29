import AppKit
import GhosttyKit

/// libghostty-backed terminal engine. All surfaces share one `ghostty_app_t` (`GhosttyRuntime`).
@MainActor
final class GhosttyTerminalEngine: TerminalEngine {
    init() {}

    func makeSurface(config: TerminalLaunchConfig) -> TerminalSurface {
        guard let app = GhosttyRuntime.shared.app else {
            return FallbackSurface(config: config, message: "libghostty failed to initialize")
        }
        let surface = GhosttyTerminalSurface(app: app, config: config)
        if (surface.view as? GhosttySurfaceView)?.surface == nil {
            return FallbackSurface(config: config, message: "ghostty_surface_new failed")
        }
        return surface
    }
}

@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    weak var delegate: TerminalSurfaceDelegate?
    private let surfaceView: GhosttySurfaceView
    var view: NSView { surfaceView }
    private(set) var title: String
    private(set) var workingDirectory: String?
    private var closed = false

    init(app: ghostty_app_t, config: TerminalLaunchConfig) {
        surfaceView = GhosttySurfaceView(app: app, config: config)
        workingDirectory = config.workingDirectory
        if let cmd = config.command, let first = cmd.split(separator: " ").first {
            title = (String(first) as NSString).lastPathComponent
        } else {
            title = ((ProcessInfo.processInfo.environment["SHELL"] ?? "shell") as NSString).lastPathComponent
        }
        surfaceView.owner = self
    }

    deinit {
        let v = surfaceView
        if Thread.isMainThread {
            MainActor.assumeIsolated { v.teardown() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { v.teardown() } }
        }
    }

    // MARK: TerminalSurface

    func sendText(_ text: String) {
        guard let surface = surfaceView.surface, !text.isEmpty else { return }
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            let chunk = buffer
            buffer = ""
            chunk.withCString { ghostty_surface_text(surface, $0, UInt(chunk.utf8.count)) }
        }
        // Printable runs go through ghostty_surface_text (bracketed only if the program enabled
        // bracketed paste); newlines and control characters are sent as real key presses so that
        // "\n" executes instead of being pasted.
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = (v == 0x0D)
            switch v {
            case 0x0A, 0x0D:
                flush(); surfaceView.sendKey(keyCode: 0x24, unshifted: 0x0D)  // Return
            case 0x09:
                flush(); surfaceView.sendKey(keyCode: 0x30, unshifted: 0x09)  // Tab
            case 0x1B:
                flush(); surfaceView.sendKey(keyCode: 0x35, unshifted: 0x1B)  // Escape
            case 0x08, 0x7F:
                flush(); surfaceView.sendKey(keyCode: 0x33, unshifted: 0x7F)  // Backspace
            case 0x01...0x1A:
                flush()
                let idx = Int(v - 1)
                surfaceView.sendKey(keyCode: GhosttyInput.letterKeyCodes[idx], mods: GHOSTTY_MODS_CTRL,
                                    unshifted: 0x61 + UInt32(idx))
            default:
                buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
    }

    func focus() {
        guard let window = surfaceView.window else { return }
        window.makeFirstResponder(surfaceView)
    }

    func visibleText() -> String {
        readText(GHOSTTY_POINT_VIEWPORT)
    }

    func scrollbackText(maxLines: Int) -> String {
        let all = readText(GHOSTTY_POINT_SCREEN)
        guard maxLines > 0 else { return "" }
        var lines = all.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            lines.removeLast()
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func close() {
        guard !closed else { return }
        closed = true
        surfaceView.teardown()
        delegate?.terminalSurfaceDidClose(self)
    }

    // MARK: Text

    private func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let surface = surfaceView.surface else { return "" }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return Self.string(from: text)
    }

    nonisolated static func string(from text: ghostty_text_s) -> String {
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    // MARK: Events from GhosttyRuntime / GhosttySurfaceView
    // Delivered asynchronously on main so delegates never re-enter libghostty mid-callback.

    func handleTitle(_ newTitle: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.title != newTitle else { return }
                self.title = newTitle
                self.delegate?.terminalSurface(self, didChangeTitle: newTitle)
            }
        }
    }

    func handlePwd(_ path: String) {
        // OSC 7 may deliver a file:// URL.
        let resolved: String
        if path.hasPrefix("file://"), let url = URL(string: path) {
            resolved = url.path
        } else {
            resolved = path
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.workingDirectory != resolved else { return }
                self.workingDirectory = resolved
                self.delegate?.terminalSurface(self, didChangeWorkingDirectory: resolved)
            }
        }
    }

    func handleBell() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.delegate?.terminalSurfaceDidRingBell(self)
            }
        }
    }

    func handleNotification(title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.delegate?.terminalSurface(self, didPostNotification: title, body: body)
            }
        }
    }

    func handleFocused() {
        guard !closed else { return }
        delegate?.terminalSurfaceDidBecomeFocused(self)
    }

    /// Child exited / libghostty asked to close: free the surface and tell the delegate.
    func handleCloseRequest() {
        close()
    }
}

/// Shown only if libghostty cannot be initialized: a read-only text view with the error.
@MainActor
private final class FallbackSurface: TerminalSurface {
    weak var delegate: TerminalSurfaceDelegate?
    let view: NSView
    private let textView: NSTextView
    var title: String { "error" }
    let workingDirectory: String?

    init(config: TerminalLaunchConfig, message: String) {
        workingDirectory = config.workingDirectory
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = "cmds: \(message)\n"
        view = scroll
    }

    func sendText(_ text: String) {}
    func focus() { view.window?.makeFirstResponder(textView) }
    func visibleText() -> String { textView.string }
    func scrollbackText(maxLines: Int) -> String { textView.string }
    func close() { delegate?.terminalSurfaceDidClose(self) }
}
