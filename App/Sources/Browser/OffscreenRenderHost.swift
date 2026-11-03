import AppKit

/// Puts a detached view tree (a workspace that is not shown) into a borderless window outside the screen while a
/// snapshot is taken, so WebKit renders it: a WKWebView with no window snapshots to an empty image (#76).
/// `release()` detaches it again unless the app has meanwhile shown the workspace in the main window.
@MainActor
final class OffscreenRenderHost {
    /// Size used when the tree was never laid out (a pane opened while its workspace was hidden).
    static let defaultSize = NSSize(width: 1280, height: 800)
    /// Time WebKit gets to paint at the new size before the snapshot.
    static let paintDelay: Duration = .milliseconds(500)

    private let root: NSView
    private let window: NSWindow

    /// Nil when `view` is already in a window.
    init?(hosting view: NSView) {
        guard view.window == nil else { return nil }
        var root = view
        while let parent = root.superview { root = parent }
        self.root = root
        let size = root.frame.width >= 1 && root.frame.height >= 1 ? root.frame.size : Self.defaultSize
        window = RenderOnlyWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.autorecalculatesKeyViewLoop = false
        root.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(root)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
    }

    func release() {
        if root.window === window { root.removeFromSuperview() }
        window.orderOut(nil)
        window.close()
    }
}

/// Never key and never gives a view the keyboard: a text field or terminal becoming first responder here would report
/// focus, and the app would select the hidden workspace (#76).
private final class RenderOnlyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard responder == nil || responder === self else { return false }
        return super.makeFirstResponder(responder)
    }
}
