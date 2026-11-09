import AppKit

/// Puts a detached view tree (a workspace that is not shown) into a borderless window outside the screen while a
/// snapshot is taken, so WebKit renders it: a WKWebView with no window snapshots to an empty image (#76).
/// `release()` detaches it again unless the app has meanwhile shown the workspace in the main window. Snapshots of
/// panes in the same hidden workspace taken at the same time share one window, detached after the last release.
@MainActor
final class OffscreenRenderHost {
    /// Size used when the tree was never laid out (a pane opened while its workspace was hidden).
    static let defaultSize = NSSize(width: 1280, height: 800)
    /// Time WebKit gets to paint at the new size before the snapshot.
    static let paintDelay: Duration = .milliseconds(500)

    private let root: NSView
    private let window: RenderOnlyWindow

    /// Nil when `view` is in a regular window.
    init?(hosting view: NSView) {
        if let shared = view.window as? RenderOnlyWindow {  // another snapshot of this workspace is under way
            root = Self.root(of: view, below: shared.contentView)
            window = shared
            shared.hosts += 1
            return
        }
        guard view.window == nil else { return nil }
        let root = Self.root(of: view, below: nil)
        self.root = root
        let size = root.frame.width >= 1 && root.frame.height >= 1 ? root.frame.size : Self.defaultSize
        window = RenderOnlyWindow(offscreenAt: NSPoint(x: -20_000, y: -20_000), size: size)
        window.autorecalculatesKeyViewLoop = false
        window.hosts = 1
        root.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(root)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
    }

    /// Runs `body` while `view` renders: when it is in no window, in an off-screen one meanwhile (after `paintDelay`).
    static func rendering<T>(_ view: NSView, _ body: () async throws -> T) async throws -> T {
        let offscreen = OffscreenRenderHost(hosting: view)
        defer { offscreen?.release() }
        if offscreen != nil { try await Task.sleep(for: paintDelay) }
        return try await body()
    }

    /// The topmost ancestor of `view` below `container` (nil: the topmost ancestor).
    private static func root(of view: NSView, below container: NSView?) -> NSView {
        var root = view
        while let parent = root.superview, parent !== container { root = parent }
        return root
    }

    func release() {
        window.hosts -= 1
        guard window.hosts == 0 else { return }
        if root.window === window { root.removeFromSuperview() }
        window.orderOut(nil)
        window.close()
    }
}

/// Never key and never gives a view the keyboard: a text field or terminal becoming first responder here would report
/// focus, and the app would select the hidden workspace (#76).
final class RenderOnlyWindow: NSWindow {
    /// Live `OffscreenRenderHost`s using this window.
    var hosts = 0

    /// A borderless window at `origin` (outside the screen) that ignores the mouse and stays out of window cycling.
    convenience init(offscreenAt origin: NSPoint, size: NSSize) {
        self.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard responder == nil || responder === self else { return false }
        return super.makeFirstResponder(responder)
    }
}
