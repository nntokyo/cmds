import AppKit
import CmdsCore

extension NSPasteboard.PasteboardType {
    /// A workspace id: dragged from a sidebar row or a tile header (reorder, tile by drag).
    static let cmdsWorkspace = NSPasteboard.PasteboardType("tokyo.n-n.cmds.workspace")
    /// Also set when the drag started at a tile header (dropping it on the sidebar takes it out of the tiled view).
    static let cmdsTile = NSPasteboard.PasteboardType("tokyo.n-n.cmds.tile")
}

extension NSDraggingInfo {
    /// Workspace ids on the dragging pasteboard, in item order.
    var cmdsWorkspaceIDs: [String] {
        (draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .cmdsWorkspace) }
    }

    var isCmdsTileDrag: Bool { draggingPasteboard.availableType(from: [.cmdsTile]) != nil }

    /// The operation to answer for an accepted cmds drag: move, or copy while ⌥ narrows the source's mask.
    var cmdsDropOperation: NSDragOperation {
        let mask = draggingSourceOperationMask
        if mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .generic : []
    }
}

/// One workspace in the tiled view: a slim header (state dot, title, agent state, task, zoom button) above the
/// workspace's split tree. The ring lights when the workspace needs the user.
@MainActor
final class WorkspaceTileView: NSView, NSDraggingSource {
    static let headerHeight: CGFloat = 24

    let workspaceID: String
    private let header = TileHeaderView()
    private let body = NSView()
    private let ring = AttentionRingView()
    /// Cards of the workspace's subagents under the terminal (collapsed when there are none or they are off).
    private let subagentStrip = SubagentStripView()
    private var subagentStripHeight: NSLayoutConstraint!
    /// Header click: give this tile the keyboard. Double-click / zoom button: show it alone (or back).
    var onActivate: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    /// The header was dragged out of the window with ⌥ held (and dropped nowhere): leave the tiled view.
    var onDraggedOut: (() -> Void)?

    init(workspaceID: String, content: NSView) {
        self.workspaceID = workspaceID
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        for view in [header, body, subagentStrip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        subagentStrip.isHidden = true
        subagentStripHeight = subagentStrip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            subagentStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            subagentStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            subagentStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            subagentStripHeight,
        ])
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: subagentStrip.topAnchor),
        ])
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = body.bounds
        content.autoresizingMask = [.width, .height]
        body.addSubview(content)
        ring.frame = bounds
        ring.autoresizingMask = [.width, .height]
        addSubview(ring)
        header.onClick = { [weak self] in self?.onActivate?() }
        header.onDoubleClick = { [weak self] in self?.onToggleZoom?() }
        header.onBeginDrag = { [weak self] event in self?.beginHeaderDrag(with: event) }
        header.zoomButton.target = self
        header.zoomButton.action = #selector(zoomClicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func zoomClicked() { onToggleZoom?() }

    // MARK: Dragging the header (reorder tiles, drop on the sidebar to remove)

    private func beginHeaderDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(workspaceID, forType: .cmdsWorkspace)
        item.setString(workspaceID, forType: .cmdsTile)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // The header strip as the drag image (terminal surfaces draw with Metal and do not snapshot).
        var frame = header.frame
        frame.size.width = min(frame.width, 360)
        let local = convert(event.locationInWindow, from: nil)
        frame.origin.x = max(header.frame.minX, min(local.x - 40, header.frame.maxX - frame.width))
        let image = NSImage(size: frame.size)
        if let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) {
            header.cacheDisplay(in: header.bounds, to: rep)
            let full = NSImage(size: header.bounds.size)
            full.addRepresentation(rep)
            image.lockFocus()
            full.draw(in: NSRect(origin: .zero, size: frame.size),
                      from: NSRect(x: frame.minX - header.frame.minX, y: 0, width: frame.width, height: frame.height),
                      operation: .copy, fraction: 0.9)
            image.unlockFocus()
        }
        dragItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation.isEmpty, NSEvent.modifierFlags.union(NSApp.currentEvent?.modifierFlags ?? []).contains(.option), let window,
              !window.frame.contains(screenPoint) else { return }
        onDraggedOut?()
    }

    /// Header text and colours, ring state. `active` = the tile with the keyboard.
    func update(with workspace: Workspace, active: Bool, zoomed: Bool) {
        header.update(with: workspace, active: active, zoomed: zoomed)
        let needsUser = workspace.attention || workspace.agentActivity == .needsInput
        ring.state = needsUser ? .attention : .off
    }

    /// Subagent cards (empty list or `shown == false` collapses the strip).
    func updateSubagents(_ agents: [SubagentInfo], shown: Bool) {
        let visible = shown && !agents.isEmpty
        subagentStrip.isHidden = !visible
        subagentStripHeight.constant = visible ? SubagentStripView.height : 0
        subagentStrip.update(visible ? agents : [])
    }
}

/// Header strip of a tile. Clicking anywhere on it (except the button) activates the tile.
@MainActor
private final class TileHeaderView: NSView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let topicLabel = NSTextField(labelWithString: "")
    let zoomButton = NSButton()
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// The mouse moved a few points with the button down: start dragging the tile.
    var onBeginDrag: ((NSEvent) -> Void)?
    private var mouseDownPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 10, weight: .medium)
        stateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        topicLabel.font = .systemFont(ofSize: 11)
        topicLabel.textColor = .secondaryLabelColor
        topicLabel.lineBreakMode = .byTruncatingTail
        topicLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        topicLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        zoomButton.isBordered = false
        zoomButton.imagePosition = .imageOnly
        zoomButton.contentTintColor = .tertiaryLabelColor
        zoomButton.setButtonType(.momentaryChange)
        for view in [dot, titleLabel, stateLabel, topicLabel, zoomButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            stateLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            topicLabel.leadingAnchor.constraint(equalTo: stateLabel.trailingAnchor, constant: 8),
            topicLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            topicLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomButton.leadingAnchor, constant: -6),
            zoomButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 18),
            zoomButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(with workspace: Workspace, active: Bool, zoomed: Bool) {
        let title = workspace.displayTitle
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
        let color = AgentActivityStyle.dotColor(for: workspace)
        dot.isHidden = color == nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color?.cgColor
            layer?.backgroundColor = (active ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                                             : NSColor(calibratedWhite: 0.14, alpha: 1)).cgColor
        }
        let badge = AgentActivityStyle.badge(for: workspace)
        stateLabel.isHidden = badge == nil
        stateLabel.stringValue = badge?.text ?? ""
        stateLabel.textColor = badge?.color
        let topic = workspace.agentTopic ?? workspace.notificationText
        topicLabel.stringValue = topic ?? ""
        topicLabel.isHidden = topic == nil
        topicLabel.toolTip = topic
        let symbol = zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let tip = zoomed ? String(localized: "Show All Tiles (⇧⌘↩)") : String(localized: "Zoom Tile (⇧⌘↩)")
        if zoomButton.toolTip != tip {
            zoomButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            zoomButton.toolTip = tip
        }
        toolTip = [title, workspace.workingDirectory?.abbreviatingHome].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, badge?.text].compactMap { $0 }.joined(separator: ", "))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.clickCount == 1 ? event.locationInWindow : nil
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        onBeginDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
}

/// The translucent area shown while dragging a workspace over the content area: where the tile will go
/// (like window snapping). Never takes clicks.
@MainActor
final class TileDropHighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the highlight at `rect` (slides from the previous one), or hides it for nil.
    func show(_ rect: NSRect?) {
        guard let rect else {
            isHidden = true
            return
        }
        let target = rect.insetBy(dx: 3, dy: 3)
        if isHidden {
            frame = target
            isHidden = false
        } else if frame != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().frame = target
            }
        }
    }
}

/// Lays out tiles in rows (`TileLayout.shape` for its aspect) with draggable dividers between rows and between the
/// tiles of a row. Divider positions come from and go to the controller, per tiling set and shape.
@MainActor
final class TileGridView: NSView {
    static let gap: CGFloat = 2

    private let tiles: [WorkspaceTileView]
    private let ids: [String]
    private let note: NSTextField?
    private var dividers: [TileDividerView] = []
    private(set) var shape: [Int] = []
    private var ratios = TileRatios(rows: [], columns: [])
    private let loadRatios: ([String], [Int]) -> TileRatios?
    private let saveRatios: (TileRatios, [String], [Int]) -> Void
    /// Rows of a dragged arrangement; nil = `TileLayout.shape` for the area's aspect.
    private let fixedShape: [Int]?

    /// `hidden` > 0 shows a note that more workspaces were left out.
    init(tiles: [WorkspaceTileView], hidden: Int, fixedShape: [Int]? = nil,
         loadRatios: @escaping ([String], [Int]) -> TileRatios?,
         saveRatios: @escaping (TileRatios, [String], [Int]) -> Void) {
        self.tiles = tiles
        ids = tiles.map(\.workspaceID)
        self.loadRatios = loadRatios
        self.saveRatios = saveRatios
        self.fixedShape = fixedShape.flatMap { $0.reduce(0, +) == tiles.count ? $0 : nil }
        if hidden > 0 {
            let label = NSTextField(labelWithString: String(localized: "Showing \(tiles.count) of \(tiles.count + hidden) workspaces"))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            note = label
        } else {
            note = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for tile in tiles {
            tile.translatesAutoresizingMaskIntoConstraints = true
            tile.autoresizingMask = []
            addSubview(tile)
        }
        if let note { addSubview(note) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private var gridHeight: CGFloat { max(bounds.height - (note == nil ? 0 : 20), 0) }

    override func layout() {
        super.layout()
        guard bounds.width > 0, gridHeight > 0 else { return }
        let newShape = fixedShape ?? TileLayout.shape(count: tiles.count, aspect: Double(bounds.width / gridHeight))
        if newShape != shape {
            shape = newShape
            ratios = loadRatios(ids, shape) ?? TileRatios.even(shape: shape)
            rebuildDividers()
        }
        let frames = TileLayout.frames(shape: shape, ratios: ratios, width: Double(bounds.width),
                                       height: Double(gridHeight), gap: Double(Self.gap))
        for (tile, frame) in zip(tiles, frames) {
            tile.frame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        if let note { note.frame = NSRect(x: 0, y: gridHeight + 2, width: bounds.width, height: 16) }
        placeDividers(frames)
    }

    private func rebuildDividers() {
        dividers.forEach { $0.removeFromSuperview() }
        dividers = []
        for row in 0..<shape.count {
            if row < shape.count - 1 { dividers.append(TileDividerView(kind: .row(after: row))) }
            for column in 0..<max(shape[row] - 1, 0) { dividers.append(TileDividerView(kind: .column(row: row, after: column))) }
        }
        for divider in dividers {
            divider.onDrag = { [weak self, weak divider] point in
                guard let self, let divider else { return }
                self.drag(divider.kind, to: self.convert(point, from: nil))
            }
            divider.onDragEnded = { [weak self] in self?.commit() }
            divider.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.ratios = TileRatios.even(shape: self.shape)
                self.needsLayout = true
                self.commit()
            }
            addSubview(divider)
        }
    }

    private func placeDividers(_ frames: [(x: Double, y: Double, width: Double, height: Double)]) {
        let grab: CGFloat = 6
        var firstOfRow: [Int] = []
        var index = 0
        for count in shape { firstOfRow.append(index); index += count }
        for divider in dividers {
            switch divider.kind {
            case .row(let row):
                guard let frame = frames[safe: firstOfRow[row]] else { continue }
                let y = CGFloat(frame.y + frame.height) + Self.gap / 2
                divider.frame = NSRect(x: 0, y: y - grab / 2, width: bounds.width, height: grab)
            case .column(let row, let column):
                guard let frame = frames[safe: firstOfRow[row] + column] else { continue }
                let x = CGFloat(frame.x + frame.width) + Self.gap / 2
                divider.frame = NSRect(x: x - grab / 2, y: CGFloat(frame.y), width: grab, height: CGFloat(frame.height))
            }
        }
    }

    private func drag(_ kind: TileDividerView.Kind, to point: NSPoint) {
        switch kind {
        case .row(let row):
            guard gridHeight > 0 else { return }
            ratios.moveRowDivider(after: row, to: Double(point.y / gridHeight))
        case .column(let row, let column):
            guard bounds.width > 0 else { return }
            ratios.moveColumnDivider(row: row, after: column, to: Double(point.x / bounds.width))
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func commit() {
        saveRatios(ratios, ids, shape)
    }
}

/// Invisible grab area on the gap between two rows or two tiles of a row.
@MainActor
private final class TileDividerView: NSView {
    enum Kind {
        case row(after: Int)
        case column(row: Int, after: Int)
    }

    let kind: Kind
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var cursor: NSCursor {
        if case .row = kind { return .resizeUpDown }
        return .resizeLeftRight
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) { onDragEnded?() }
}
