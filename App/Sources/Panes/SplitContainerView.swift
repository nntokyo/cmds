import AppKit
import CmdsCore

/// Lays out two children according to a `SplitNode`'s axis and ratio, with a draggable divider.
final class SplitContainerView: NSView {
    static let gap: CGFloat = 1

    let node: SplitNode
    private let axis: SplitAxis
    private let first: NSView
    private let second: NSView
    private let divider: DividerView
    /// Called once a divider drag ends (the ratio is already written to `node`).
    var onRatioCommitted: (() -> Void)?

    init(node: SplitNode, axis: SplitAxis, first: NSView, second: NSView) {
        self.node = node
        self.axis = axis
        self.first = first
        self.second = second
        divider = DividerView(axis: axis)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for view in [first, second, divider] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
        }
        divider.onDrag = { [weak self] point in self?.dragDivider(to: point) }
        divider.onDragEnded = { [weak self] in self?.onRatioCommitted?() }
        divider.onDoubleClick = { [weak self] in
            self?.node.ratio = 0.5
            self?.needsLayout = true
            self?.onRatioCommitted?()
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
        let gap = Self.gap
        let grab: CGFloat = 6
        let ratio = CGFloat(node.ratio)
        switch axis {
        case .horizontal:
            let available = max(bounds.width - gap, 0)
            let firstWidth = (available * ratio).rounded()
            first.frame = NSRect(x: 0, y: 0, width: firstWidth, height: bounds.height)
            second.frame = NSRect(x: firstWidth + gap, y: 0, width: available - firstWidth, height: bounds.height)
            divider.frame = NSRect(x: firstWidth + gap / 2 - grab / 2, y: 0, width: grab, height: bounds.height)
        case .vertical:
            let available = max(bounds.height - gap, 0)
            let firstHeight = (available * ratio).rounded()
            first.frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstHeight)
            second.frame = NSRect(x: 0, y: firstHeight + gap, width: bounds.width, height: available - firstHeight)
            divider.frame = NSRect(x: 0, y: firstHeight + gap / 2 - grab / 2, width: bounds.width, height: grab)
        }
    }

    private func dragDivider(to windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let length = axis == .horizontal ? bounds.width : bounds.height
        guard length > 0 else { return }
        let position = axis == .horizontal ? point.x : point.y
        let minRatio = max(SplitNode.minRatio, 60 / length)
        node.ratio = Double(min(max(position / length, minRatio), 1 - minRatio))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

/// Invisible grab area centered on the gap between two panes.
private final class DividerView: NSView {
    let axis: SplitAxis
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(axis: SplitAxis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
