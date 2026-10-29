import AppKit

enum FocusDirection {
    case left, right, up, down
}

/// Right-hand side of the window: the selected workspace's split tree, or an empty state.
@MainActor
final class WorkspaceContentViewController: NSViewController {
    private let controller: AppController
    private let host = NSView()
    private lazy var emptyState = EmptyStateView { [weak self] in self?.controller.createWorkspace() }
    private var renderedKey: String?

    init(controller: AppController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    /// Rebuilds the view tree only when the workspace, structure or zoom changed; otherwise updates rings.
    func render() {
        guard let workspace = controller.selectedWorkspace, let root = workspace.root else {
            if renderedKey != "empty" {
                renderedKey = "empty"
                install(emptyState)
            }
            return
        }
        let key = "\(workspace.id)|\(workspace.zoomedPaneID ?? "-")|\(root.structureKey)"
        if key != renderedKey {
            renderedKey = key
            let isFirstResponderInside = (view.window?.firstResponder as? NSView)?.isDescendant(of: host) ?? false
            if let zoomed = workspace.zoomedPaneID.flatMap({ workspace.panes[$0] }) {
                install(zoomed.container)
            } else {
                install(makeView(for: root, in: workspace))
            }
            if isFirstResponderInside || view.window?.firstResponder === view.window {
                workspace.focusedPane?.focus()
            }
        }
        let multiple = workspace.panes.count > 1 && workspace.zoomedPaneID == nil
        for pane in workspace.panes.values {
            pane.container.attention = pane.attention
            pane.container.showsFocus = multiple && pane.id == workspace.focusedPaneID
        }
    }

    /// Pane under a point in window coordinates.
    func paneID(atWindowPoint point: NSPoint) -> String? {
        guard let workspace = controller.selectedWorkspace else { return nil }
        for pane in workspace.panes.values where pane.container.window != nil {
            if pane.container.convert(pane.container.bounds, to: nil).contains(point) { return pane.id }
        }
        return nil
    }

    /// Nearest visible pane in `direction` from the focused pane.
    func neighbor(of paneID: String, direction: FocusDirection) -> String? {
        guard let workspace = controller.selectedWorkspace else { return nil }
        var frames: [String: NSRect] = [:]
        for pane in workspace.panes.values where pane.container.window != nil {
            frames[pane.id] = pane.container.convert(pane.container.bounds, to: nil)
        }
        guard let current = frames[paneID] else { return nil }
        let tolerance: CGFloat = 4
        // Window coordinates are not flipped: "up" means larger y.
        let candidates = frames.compactMap { id, frame -> (id: String, distance: CGFloat, offset: CGFloat)? in
            guard id != paneID else { return nil }
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= current.minX + tolerance else { return nil }
                distance = current.minX - frame.maxX
                overlap = min(frame.maxY, current.maxY) - max(frame.minY, current.minY)
            case .right:
                guard frame.minX >= current.maxX - tolerance else { return nil }
                distance = frame.minX - current.maxX
                overlap = min(frame.maxY, current.maxY) - max(frame.minY, current.minY)
            case .up:
                guard frame.minY >= current.maxY - tolerance else { return nil }
                distance = frame.minY - current.maxY
                overlap = min(frame.maxX, current.maxX) - max(frame.minX, current.minX)
            case .down:
                guard frame.maxY <= current.minY + tolerance else { return nil }
                distance = current.minY - frame.maxY
                overlap = min(frame.maxX, current.maxX) - max(frame.minX, current.minX)
            }
            guard overlap > 0 else { return nil }
            let offset = direction == .left || direction == .right
                ? abs(frame.midY - current.midY) : abs(frame.midX - current.midX)
            return (id, distance, offset)
        }
        return candidates.min { ($0.distance, $0.offset) < ($1.distance, $1.offset) }?.id
    }

    private func install(_ content: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = host.bounds
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
    }

    private func makeView(for node: SplitNode, in workspace: Workspace) -> NSView {
        switch node.content {
        case .leaf(let id):
            return workspace.panes[id]?.container ?? NSView()
        case .split(let axis, let first, let second):
            let view = SplitContainerView(node: node, axis: axis,
                                          first: makeView(for: first, in: workspace),
                                          second: makeView(for: second, in: workspace))
            let workspaceID = workspace.id
            view.onRatioCommitted = { [weak self] in self?.controller.layoutDidChange(workspaceID: workspaceID) }
            return view
        }
    }
}

private final class EmptyStateView: NSView {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "No workspaces")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let button = NSButton(title: "New Workspace  ⌘N", target: self, action: #selector(create))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [title, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func create() { action() }
}
