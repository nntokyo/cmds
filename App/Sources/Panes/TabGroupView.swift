import AppKit
import CmdsCore

/// The commands of a tab's context menu.
enum TabCommand {
    case close, closeOthers, closeToTheRight, duplicate, reload, moveToNewWorkspace
}

/// A menu item's command and the tab it is for.
private final class TabCommandChoice: NSObject {
    let command: TabCommand
    let paneID: String

    init(command: TabCommand, paneID: String) {
        self.command = command
        self.paneID = paneID
    }
}

/// One tab of a tab bar: what the bar draws for a pane of the group.
struct TabItem: Equatable {
    var paneID: String
    var title: String
    var kind: PaneKind
    var attention: Bool
    /// A browser page's icon (nil: the kind's symbol).
    var icon: NSImage? = nil
    /// The second line of the tooltip: a browser's address, a file's or folder's path, a terminal's directory.
    var detail: String? = nil

    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.paneID == rhs.paneID && lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.attention == rhs.attention
            && lhs.icon === rhs.icon && lhs.detail == rhs.detail
    }
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
    /// Narrower tabs show only their icon (and the × when hovered or shown).
    private static let titleMinWidth: CGFloat = 64
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
    /// A command of a tab's context menu.
    var onTabCommand: ((TabCommand, String) -> Void)?
    /// A tab was dragged out of the window and dropped nowhere.
    var onDraggedOutOfWindow: ((String) -> Void)?

    private var hoveredIndex: Int?
    private var hoveringClose = false
    /// The tab pressed (by pane id: an agent may add or close tabs before the mouse goes up).
    private var pressed: (index: Int, paneID: String, point: NSPoint, onClose: Bool)?
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
        updateVisibleRange()
        needsDisplay = true
        toolTip = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibleRange()
    }

    // MARK: Geometry

    /// Narrowest a tab gets (icon and ×); more tabs than fit go into the overflow menu (⌄).
    private static let minTabWidth: CGFloat = 40
    private static let overflowWidth: CGFloat = 26

    /// The tabs drawn: all, or a window around the shown one when they do not fit (the rest in the overflow menu).
    private(set) var visible: Range<Int> = 0..<0

    private var overflowing: Bool { visible.count < tabs.count }

    private func updateVisibleRange() {
        let room = max(bounds.width - Self.plusWidth, 0)
        guard CGFloat(tabs.count) * Self.minTabWidth > room, tabs.count > 1 else {
            visible = 0..<tabs.count
            return
        }
        let capacity = max(1, min(tabs.count, Int((room - Self.overflowWidth) / Self.minTabWidth)))
        var first = min(visible.lowerBound, tabs.count - capacity)
        if let selected = tabs.firstIndex(where: { $0.paneID == selectedID }) {
            if selected < first { first = selected }
            if selected >= first + capacity { first = selected - capacity + 1 }
        }
        first = max(0, min(first, tabs.count - capacity))
        visible = first..<(first + capacity)
    }

    /// The visible tabs share the bar before the + (and ⌄): wide tabs shrink evenly down to `minTabWidth`.
    private var tabWidth: CGFloat {
        guard !visible.isEmpty else { return Self.maxTabWidth }
        let available = max(bounds.width - Self.plusWidth - (overflowing ? Self.overflowWidth : 0), 0)
        return max(min(Self.maxTabWidth, (available / CGFloat(visible.count)).rounded(.down)), 1)
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index - visible.lowerBound) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
    }

    #if DEBUG
    /// A tab's frame and its ×'s (`debug.tab_bar`).
    func debugRects(_ index: Int) -> (tab: NSRect, close: NSRect)? {
        visible.contains(index) ? (tabRect(index), closeRect(index)) : nil
    }
    #endif

    /// The overflow menu's button, after the visible tabs (when they do not all fit).
    private var overflowRect: NSRect? {
        guard overflowing else { return nil }
        return NSRect(x: CGFloat(visible.count) * tabWidth, y: 0, width: Self.overflowWidth, height: bounds.height)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(x: tab.maxX - Self.closeSize - 6, y: (tab.height - Self.closeSize) / 2,
                      width: Self.closeSize, height: Self.closeSize)
    }

    private var plusRect: NSRect {
        NSRect(x: CGFloat(visible.count) * tabWidth + (overflowing ? Self.overflowWidth : 0), y: 0,
               width: Self.plusWidth, height: bounds.height)
    }

    private func index(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.y <= bounds.height, !plusRect.contains(point),
              overflowRect?.contains(point) != true else { return nil }
        let index = Int(point.x / tabWidth) + visible.lowerBound
        return visible.contains(index) && tabRect(index).contains(point) ? index : nil
    }

    /// Where a pane dropped at `point` (this view's coordinates) goes: its index among the tabs (0 = first).
    func insertionIndex(at point: NSPoint) -> Int {
        let slot = Int(((point.x / tabWidth) + 0.5).rounded(.down)) + visible.lowerBound
        return min(max(slot, visible.lowerBound), visible.upperBound)
    }

    /// Shows (or hides, nil) the insertion mark of a pane dragged over the bar.
    func showDropMark(at point: NSPoint?) {
        dropIndex = point.map(insertionIndex(at:))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        for index in visible where tabs.indices.contains(index) { drawTab(tabs[index], at: index) }
        if let overflow = overflowRect {
            let color = hoveredIndex == -2 ? NSColor.labelColor : NSColor.secondaryLabelColor
            drawSymbol("chevron.down", in: NSRect(x: overflow.midX - 5, y: overflow.midY - 5, width: 10, height: 10), color: color)
        }
        // +
        let plus = plusRect
        let plusColor = hoveredIndex == -1 ? NSColor.labelColor : NSColor.secondaryLabelColor
        drawSymbol("plus", in: NSRect(x: plus.midX - 6, y: plus.midY - 6, width: 12, height: 12), color: plusColor)
        // Bottom line under the inactive tabs.
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if let dropIndex {
            NSColor.controlAccentColor.setFill()
            NSRect(x: min(CGFloat(dropIndex - visible.lowerBound) * tabWidth, bounds.width - 2) - 1, y: 3, width: 3,
                   height: bounds.height - 6).fill()
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

        let narrow = rect.width < Self.titleMinWidth
        var x = narrow ? rect.midX - 7 : rect.minX + 9
        let closeShown = showsClose(index)
        if narrow, closeShown { x = rect.minX + 4 }
        let iconRect = NSRect(x: x, y: rect.midY - 7, width: 14, height: 14)
        if let icon = tab.icon {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.85,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if tab.attention {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconRect.maxX - 4, y: iconRect.minY - 2, width: 6, height: 6)).fill()
            }
        } else {
            drawSymbol(Self.symbol(for: tab.kind), in: iconRect,
                       color: tab.attention ? .systemOrange : (selected ? .labelColor : .secondaryLabelColor))
        }
        x = iconRect.maxX + 6
        let textRight = (closeShown ? closeRect(index).minX : rect.maxX - 6) - 4
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: tab.title.isEmpty ? Self.defaultTitle(tab.kind) : tab.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .medium : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let textHeight: CGFloat = 15
        if !narrow { title.draw(with: NSRect(x: x, y: rect.midY - textHeight / 2, width: max(textRight - x, 0), height: textHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
        if closeShown {
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

    /// The × of the tab at `index` is drawn there (selected or hovered, and the tab wide enough).
    private func showsClose(_ index: Int) -> Bool {
        tabs.indices.contains(index) && (tabs[index].paneID == selectedID || hoveredIndex == index)
            && tabWidth >= Self.closeSize + 20
    }

    private func updateHover(_ event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        var index = point.flatMap(index(at:))
        if index == nil, let point, plusRect.contains(point) { index = -1 }
        if index == nil, let point, overflowRect?.contains(point) == true { index = -2 }
        let close = index.map { $0 >= 0 && tabWidth >= Self.closeSize + 20 && point.map(closeRect($0).contains) == true } ?? false
        if index != hoveredIndex || close != hoveringClose {
            hoveredIndex = index
            hoveringClose = close
            needsDisplay = true
            toolTip = index.flatMap { index -> String? in
                if index == -2 { return String(localized: "All Tabs", comment: "Tab bar: the overflow menu's button") }
                guard tabs.indices.contains(index) else { return nil }
                return [tabs[index].title, tabs[index].detail].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A tab is shown on mouse up, not down: showing it rebuilds the views (this bar included), which would end a drag
    // before it starts. So any tab can be dragged, shown or not.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let overflow = overflowRect, overflow.contains(point) {
            pressed = nil
            showOverflowMenu(below: overflow)
        } else if plusRect.contains(point) {
            pressed = nil
            onNewTab?()
        } else if let index = index(at: point) {
            pressed = (index, tabs[index].paneID, event.locationInWindow, showsClose(index) && closeRect(index).contains(point))
        } else if event.clickCount == 2 {
            pressed = nil
            onNewTab?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !pressed.onClose, let tab = tabs.first(where: { $0.paneID == pressed.paneID }),
              hypot(event.locationInWindow.x - pressed.point.x, event.locationInWindow.y - pressed.point.y) >= Self.dragThreshold
        else { return }
        self.pressed = nil
        beginDrag(tab, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, let index = tabs.firstIndex(where: { $0.paneID == pressed.paneID }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let id = pressed.paneID
        if pressed.onClose {
            if closeRect(index).contains(point) { onClose?(id) }
        } else {
            onSelect?(id)
        }
    }

    // Right-click: the tab's commands.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let tab = tabs[index]
        let menu = NSMenu()
        func add(_ title: String, _ command: TabCommand, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(tabCommandChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TabCommandChoice(command: command, paneID: tab.paneID)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        add(String(localized: "Close Tab"), .close)
        add(String(localized: "Close Other Tabs"), .closeOthers, enabled: tabs.count > 1)
        add(String(localized: "Close Tabs to the Right"), .closeToTheRight, enabled: index < tabs.count - 1)
        menu.addItem(.separator())
        add(String(localized: "Duplicate Tab"), .duplicate)
        if tab.kind == .browser { add(String(localized: "Reload Page"), .reload) }
        add(String(localized: "Move to New Workspace"), .moveToNewWorkspace)
        return menu
    }

    /// Every tab, the shown one checked; choosing one shows it.
    private func showOverflowMenu(below rect: NSRect) {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self)
    }

    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for tab in tabs {
            let item = NSMenuItem(title: tab.title.isEmpty ? Self.defaultTitle(tab.kind) : tab.title,
                                  action: #selector(overflowTabChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.paneID
            item.state = tab.paneID == selectedID ? .on : .off
            item.toolTip = tab.detail
            if let icon = tab.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                item.image = icon
            } else {
                item.image = NSImage(systemSymbolName: Self.symbol(for: tab.kind), accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func overflowTabChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect?(id)
    }

    @objc private func tabCommandChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TabCommandChoice else { return }
        onTabCommand?(choice.command, choice.paneID)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes the tab.
        guard event.buttonNumber == 2 else { return }
        middleClicked(at: convert(event.locationInWindow, from: nil))
    }

    /// A middle click at `point` closes the tab there.
    func middleClicked(at point: NSPoint) {
        guard let index = index(at: point) else { return }
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
