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

    /// Tiles of the tiled view by workspace id (empty in the single view).
    private var tileViews: [String: WorkspaceTileView] = [:]

    /// Rebuilds the view tree only when the workspace(s), structure or zoom changed; otherwise updates rings.
    func render() {
        if controller.isTiling {
            renderTiles()
            return
        }
        guard let workspace = controller.selectedWorkspace, let root = workspace.root else {
            if renderedKey != "empty" {
                renderedKey = "empty"
                tileViews = [:]
                install(emptyState)
            }
            return
        }
        let key = "\(workspace.id)|\(workspace.zoomedPaneID ?? "-")|\(root.structureKey)"
        if key != renderedKey {
            renderedKey = key
            tileViews = [:]
            rebuild { self.makeWorkspaceView(workspace, root: root) }
        }
        updateRings(of: workspace, active: true, tiled: false)
    }

    /// Tiled view: one `WorkspaceTileView` per tiled workspace in a `TileGridView`, or the zoomed tile alone.
    /// Pane containers move into the tiles (terminal surfaces keep running; they get the new size on layout).
    private func renderTiles() {
        let tiles = controller.tiledWorkspaces
        let zoomed = controller.tileZoomedWorkspaceID.flatMap(controller.workspace(id:))
        let shown = zoomed.map { [$0] } ?? tiles
        let structure = shown.map { "\($0.id)|\($0.zoomedPaneID ?? "-")|\($0.root?.structureKey ?? "")" }
        let key = "tiles|\(zoomed?.id ?? "-")|\(controller.hiddenTileCount)|" + structure.joined(separator: ";")
        if key != renderedKey {
            renderedKey = key
            rebuild {
                var views: [String: WorkspaceTileView] = [:]
                let tiles = shown.compactMap { workspace -> WorkspaceTileView? in
                    guard let root = workspace.root else { return nil }
                    let tile = WorkspaceTileView(workspaceID: workspace.id, content: self.makeWorkspaceView(workspace, root: root))
                    let id = workspace.id
                    tile.onActivate = { [weak self] in self?.activateTile(id) }
                    tile.onToggleZoom = { [weak self] in
                        self?.activateTile(id)
                        self?.controller.toggleTileZoom()
                    }
                    views[id] = tile
                    return tile
                }
                self.tileViews = views
                if zoomed != nil, let only = tiles.first { return only }
                return TileGridView(tiles: tiles, hidden: self.controller.hiddenTileCount,
                                    loadRatios: { [weak self] ids, shape in self?.controller.tileRatios(for: ids, shape: shape) },
                                    saveRatios: { [weak self] ratios, ids, shape in
                                        self?.controller.setTileRatios(ratios, for: ids, shape: shape)
                                    })
            }
        }
        for workspace in shown {
            let active = workspace.id == controller.selectedWorkspaceID
            tileViews[workspace.id]?.update(with: workspace, active: active, zoomed: zoomed != nil)
            updateRings(of: workspace, active: active, tiled: true)
        }
    }

    /// Clicking a tile's header: its focused pane takes the keyboard.
    private func activateTile(_ workspaceID: String) {
        guard let workspace = controller.workspace(id: workspaceID),
              let pane = workspace.focusedPane ?? workspace.orderedPanes.first else { return }
        try? controller.focusPane(id: pane.id)
    }

    /// Replaces the hosted view; keeps the keyboard in the content area when it was there.
    private func rebuild(_ make: () -> NSView) {
        let isFirstResponderInside = (view.window?.firstResponder as? NSView)?.isDescendant(of: host) ?? false
        install(make())
        if isFirstResponderInside || view.window?.firstResponder === view.window {
            controller.focusedPane?.focus()
        }
    }

    private func makeWorkspaceView(_ workspace: Workspace, root: SplitNode) -> NSView {
        if let zoomed = workspace.zoomedPaneID.flatMap({ workspace.panes[$0] }) { return zoomed.container }
        return makeView(for: root, in: workspace)
    }

    /// Attention rings and the focus outline. In a tile the outline marks the focused pane of the active tile only;
    /// a single-pane tile leaves attention to the tile's own ring.
    private func updateRings(of workspace: Workspace, active: Bool, tiled: Bool) {
        let multiple = workspace.panes.count > 1 && workspace.zoomedPaneID == nil
        for pane in workspace.panes.values {
            pane.container.attention = pane.attention && (!tiled || multiple)
            pane.container.showsFocus = multiple && active && pane.id == workspace.focusedPaneID
        }
    }

    /// Panes on screen: the selected workspace's, or those of every tile.
    private var visiblePanes: [Pane] {
        let shown = controller.isTiling ? controller.tiledWorkspaces : controller.selectedWorkspace.map { [$0] } ?? []
        return shown.flatMap { $0.panes.values }.filter { $0.container.window != nil }
    }

    /// Pane under a point in window coordinates.
    func paneID(atWindowPoint point: NSPoint) -> String? {
        for pane in visiblePanes {
            if pane.container.convert(pane.container.bounds, to: nil).contains(point) { return pane.id }
        }
        return nil
    }

    /// Nearest visible pane in `direction` from the focused pane.
    func neighbor(of paneID: String, direction: FocusDirection) -> String? {
        var frames: [String: NSRect] = [:]
        for pane in visiblePanes {
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
        let title = NSTextField(labelWithString: String(localized: "No workspaces"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let button = NSButton(title: String(localized: "New Workspace  ⌘N"), target: self, action: #selector(create))
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
