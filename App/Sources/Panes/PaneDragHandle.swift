import AppKit
import CmdsCore

extension NSPasteboard.PasteboardType {
    /// A pane id, dragged by the grip at the top of a pane (#218): onto another pane (split there or swap), a sidebar
    /// row (move into that workspace) or out of the window (into a new workspace).
    static let cmdsPane = NSPasteboard.PasteboardType("tokyo.n-n.cmds.pane")
}

extension NSDraggingInfo {
    /// The dragged pane's id, if this is a pane drag.
    var cmdsPaneID: String? {
        draggingPasteboard.pasteboardItems?.lazy.compactMap { $0.string(forType: .cmdsPane) }.first
    }
}

/// The grip at the top centre of a pane (#218). Shown only while the mouse is near the pane's top edge
/// (`PaneContainerView`), small enough not to take clicks or selections from what is below. Dragging it moves the pane;
/// a drag that ends outside the window (not cancelled with Esc) moves the pane into a new workspace.
@MainActor
final class PaneDragHandleView: NSView, NSDraggingSource {
    static let size = NSSize(width: 44, height: 12)
    /// The bar drawn in the grip: inset from its sides and top, and its thickness.
    private static let barInset: CGFloat = 6
    private static let barTop: CGFloat = 3
    private static let barThickness: CGFloat = 4
    /// How far the mouse moves with the button down before the drag starts (a click does nothing).
    private static let dragThreshold: CGFloat = 3
    /// The drag image: a label at most this wide, this tall, held this far from its left end.
    private static let dragImageMaxWidth: CGFloat = 280
    private static let dragImageHeight: CGFloat = 24
    private static let dragImageGrabOffset: CGFloat = 20

    let paneID: String
    /// The title shown in the drag image.
    var title: (() -> String)?
    /// The drag ended outside the window without being dropped anywhere.
    var onDraggedOutOfWindow: (() -> Void)?
    /// A drag is under way (the grip stays visible).
    private(set) var isDragging = false
    private var mouseDownPoint: NSPoint?
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = String(localized: "Drag to move the pane", comment: "Tooltip of the grip at the top of a pane (#218)")
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(String(localized: "Move Pane", comment: "Accessibility label of the pane's drag grip (#218)"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: Self.barInset, y: Self.barTop, width: bounds.width - 2 * Self.barInset,
                         height: Self.barThickness)
        NSColor.labelColor.withAlphaComponent(hovered || isDragging ? 0.75 : 0.4).setFill()
        NSBezierPath(roundedRect: bar, xRadius: Self.barThickness / 2, yRadius: Self.barThickness / 2).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= Self.dragThreshold
        else { return }
        mouseDownPoint = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(paneID, forType: .cmdsPane)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // Terminal surfaces draw with Metal and do not snapshot: a label with the pane's title instead.
        let image = Self.dragImage(title: title?() ?? "")
        let local = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: local.x - Self.dragImageGrabOffset, y: local.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        isDragging = true
        needsDisplay = true
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// A rounded label: grip glyph and the title, at most `dragImageMaxWidth` wide.
    private static func dragImage(title: String) -> NSImage {
        let text = NSAttributedString(string: "⠿  " + (title.isEmpty ? String(localized: "Pane") : title), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = NSSize(width: min(text.size().width + 20, dragImageMaxWidth), height: dragImageHeight)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(with: NSRect(x: 10, y: 6, width: rect.width - 20, height: 14),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        hovered = false
        isHidden = true  // the container shows it again when the mouse comes back to the top edge
        window?.invalidateCursorRects(for: self)
        // Esc ends the session with a key event; a drop the window refused ends inside its frame.
        guard operation.isEmpty, NSApp.currentEvent?.type != .keyDown, let window, !window.frame.contains(screenPoint)
        else { return }
        let move = onDraggedOutOfWindow
        DispatchQueue.main.async { move?() }
    }
}
