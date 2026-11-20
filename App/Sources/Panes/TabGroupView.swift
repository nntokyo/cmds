import AppKit
import CmdsCore

/// One tab of a tab bar: what the bar draws for a pane of the group.
struct TabItem: Equatable {
    var paneID: String
    var title: String
    var kind: PaneKind
    var attention: Bool
}

/// A place of the split tree that stacks several panes as tabs (`SplitNode.tabs`): the tab bar above the shown pane.
/// Rebuilt with the split views whenever the tabs or the shown one change (`SplitNode.structureKey`); titles and
/// attention dots are refreshed in place (`update`).
@MainActor
final class TabGroupView: NSView {
    let bar: TabBarView
    private let content: NSView

    init(shown: NSView, bar: TabBarView) {
        self.bar = bar
        content = shown
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        for view in [bar, shown] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = TabBarView.height
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        content.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}

/// The row of tabs of a tab group: click shows a tab, the × (or a middle click) closes it, + adds one, dragging a tab
/// moves its pane like the pane grip does (onto another pane, a tab bar, a sidebar row or out of the window).
@MainActor
final class TabBarView: NSView, NSDraggingSource {
    static let height: CGFloat = 28
    private static let maxTabWidth: CGFloat = 220
    private static let minTabWidth: CGFloat = 72
    private static let plusWidth: CGFloat = 28
    private static let closeSize: CGFloat = 16
    private static let dragThreshold: CGFloat = 4

    private(set) var tabs: [TabItem] = []
    private(set) var selectedID: String?
    /// The group has the keyboard (the selected tab is drawn brighter).
    private var active = false

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    /// A tab was dragged out of the window and dropped nowhere.
    var onDraggedOutOfWindow: ((String) -> Void)?

    private var hoveredIndex: Int?
    private var hoveringClose = false
    private var pressed: (index: Int, point: NSPoint, onClose: Bool)?
    private var draggingID: String?
    /// While a pane is dragged over the bar: where it would go (index between tabs).
    private var dropIndex: Int? {
        didSet { if dropIndex != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(String(localized: "Tabs", comment: "Accessibility label of a pane's tab bar"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(tabs: [TabItem], selected: String?, active: Bool) {
        guard tabs != self.tabs || selected != selectedID || active != self.active else { return }
        self.tabs = tabs
        selectedID = selected
        self.active = active
        needsDisplay = true
        toolTip = nil
    }

    // MARK: Geometry

    private var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return Self.maxTabWidth }
        let available = max(bounds.width - Self.plusWidth, 0)
        return min(Self.maxTabWidth, max(Self.minTabWidth, (available / CGFloat(tabs.count)).rounded(.down)))
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(x: tab.maxX - Self.closeSize - 6, y: (tab.height - Self.closeSize) / 2,
                      width: Self.closeSize, height: Self.closeSize)
    }

    private var plusRect: NSRect {
        let x = min(CGFloat(tabs.count) * tabWidth, max(bounds.width - Self.plusWidth, 0))
        return NSRect(x: x, y: 0, width: Self.plusWidth, height: bounds.height)
    }

    private func index(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.y <= bounds.height else { return nil }
        let index = Int(point.x / tabWidth)
        return tabs.indices.contains(index) && tabRect(index).contains(point) ? index : nil
    }

    /// Where a pane dropped at `point` (this view's coordinates) goes: its index among the tabs (0 = first).
    func insertionIndex(at point: NSPoint) -> Int {
        let slot = Int(((point.x / tabWidth) + 0.5).rounded(.down))
        return min(max(slot, 0), tabs.count)
    }

    /// Shows (or hides, nil) the insertion mark of a pane dragged over the bar.
    func showDropMark(at point: NSPoint?) {
        dropIndex = point.map(insertionIndex(at:))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        for (index, tab) in tabs.enumerated() { drawTab(tab, at: index) }
        // +
        let plus = plusRect
        let plusColor = hoveredIndex == -1 ? NSColor.labelColor : NSColor.secondaryLabelColor
        drawSymbol("plus", in: NSRect(x: plus.midX - 6, y: plus.midY - 6, width: 12, height: 12), color: plusColor)
        // Bottom line under the inactive tabs.
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if let dropIndex {
            NSColor.controlAccentColor.setFill()
            NSRect(x: min(CGFloat(dropIndex) * tabWidth, bounds.width - 2) - 1, y: 3, width: 3, height: bounds.height - 6).fill()
        }
    }

    private func drawTab(_ tab: TabItem, at index: Int) {
        let rect = tabRect(index)
        let selected = tab.paneID == selectedID
        if selected {
            NSColor(calibratedWhite: active ? 0.2 : 0.17, alpha: 1).setFill()
            rect.fill()
            if active {
                NSColor.controlAccentColor.setFill()
                NSRect(x: rect.minX, y: 0, width: rect.width, height: 2).fill()
            }
        } else if hoveredIndex == index {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            rect.fill()
        }
        // Separator.
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        NSRect(x: rect.maxX - 1, y: 6, width: 1, height: rect.height - 12).fill()

        var x = rect.minX + 9
        let iconRect = NSRect(x: x, y: rect.midY - 7, width: 14, height: 14)
        drawSymbol(Self.symbol(for: tab.kind), in: iconRect,
                   color: tab.attention ? .systemOrange : (selected ? .labelColor : .secondaryLabelColor))
        x = iconRect.maxX + 6
        let showsClose = selected || hoveredIndex == index
        let textRight = (showsClose ? closeRect(index).minX : rect.maxX - 6) - 4
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: tab.title.isEmpty ? Self.defaultTitle(tab.kind) : tab.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .medium : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let textHeight: CGFloat = 15
        title.draw(with: NSRect(x: x, y: rect.midY - textHeight / 2, width: max(textRight - x, 0), height: textHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if showsClose {
            let close = closeRect(index)
            if hoveringClose, hoveredIndex == index {
                NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
                NSBezierPath(roundedRect: close, xRadius: 4, yRadius: 4).fill()
            }
            drawSymbol("xmark", in: close.insetBy(dx: 4, dy: 4), color: .secondaryLabelColor)
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configured = image.withSymbolConfiguration(.init(pointSize: rect.height, weight: .medium)
            .applying(.init(paletteColors: [color]))) ?? image
        let size = configured.size
        let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1), 1)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        configured.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func symbol(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .preview: return "doc.text"
        case .files: return "folder"
        }
    }

    static func defaultTitle(_ kind: PaneKind) -> String {
        switch kind {
        case .terminal: return String(localized: "Terminal", comment: "default pane title")
        case .browser: return String(localized: "New Tab")
        case .preview: return String(localized: "Preview")
        case .files: return String(localized: "Files")
        }
    }

    // MARK: Mouse

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    private func updateHover(_ event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        var index = point.flatMap(index(at:))
        if index == nil, let point, plusRect.contains(point) { index = -1 }
        let close = index.map { $0 >= 0 && point.map(closeRect($0).contains) == true } ?? false
        if index != hoveredIndex || close != hoveringClose {
            hoveredIndex = index
            hoveringClose = close
            needsDisplay = true
            toolTip = index.flatMap { tabs.indices.contains($0) ? tabs[$0].title : nil }
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = index(at: point) {
            pressed = (index, event.locationInWindow, closeRect(index).contains(point) && (tabs[index].paneID == selectedID || hoveredIndex == index))
            if pressed?.onClose == false { onSelect?(tabs[index].paneID) }
        } else if plusRect.contains(point) || event.clickCount == 2 {
            pressed = nil
            onNewTab?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !pressed.onClose, tabs.indices.contains(pressed.index),
              hypot(event.locationInWindow.x - pressed.point.x, event.locationInWindow.y - pressed.point.y) >= Self.dragThreshold
        else { return }
        self.pressed = nil
        beginDrag(tabs[pressed.index], event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, pressed.onClose, tabs.indices.contains(pressed.index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if closeRect(pressed.index).contains(point) { onClose?(tabs[pressed.index].paneID) }
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes the tab.
        guard event.buttonNumber == 2, let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onClose?(tabs[index].paneID)
    }

    // MARK: Dragging a tab

    private func beginDrag(_ tab: TabItem, event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(tab.paneID, forType: .cmdsPane)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = PaneDragHandleView.dragImage(title: tab.title)
        let local = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: local.x - PaneDragHandleView.dragImageGrabOffset, y: local.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        draggingID = tab.paneID
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let id = draggingID
        draggingID = nil
        updateHover(nil)
        guard let id, operation.isEmpty, NSApp.currentEvent?.type != .keyDown, let window, !window.frame.contains(screenPoint)
        else { return }
        let moved = onDraggedOutOfWindow
        DispatchQueue.main.async { moved?(id) }
    }
}
