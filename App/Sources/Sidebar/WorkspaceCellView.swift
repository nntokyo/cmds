import AppKit
import CmdsCore

/// Sidebar row: state dot/spinner + title + agent state + ⌘N hint (× on hover), the agent's task (else the cwd), branch,
/// ports, agent figures, CPU/memory, latest notification (≤ 2 lines).
final class WorkspaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11)
    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let usageFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Memory starts at a fixed tab stop so changing CPU digits never shift it.
    private static let usageTabStop: CGFloat = 64
    private static let horizontalInset: CGFloat = 10
    private static let verticalInset: CGFloat = 6
    private static let spacing: CGFloat = 2
    private static let titleHeight: CGFloat = 17
    private static let detailHeight: CGFloat = 14

    /// The row's × was clicked (the sidebar confirms and closes the workspace).
    var onClose: ((String) -> Void)?
    private var workspaceID: String?

    /// Holds the state dot or, while the agent works, a small spinner (the slot keeps its width so the title never moves).
    private let indicator = NSView()
    private let dot = NSView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    /// `Working` / `Needs Input` / `Done` / `Idle` / `Stopped`.
    private let stateLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    /// The agent's task (its terminal title); replaces the cwd line, which moves to the tooltip.
    private let topicLabel = NSTextField(labelWithString: "")
    private let statusRow = NSStackView()
    /// `ssh home` (hosts of the workspace's SSH panes; "disconnected" while one is down).
    private let hostLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let directoryLabel = PathLabel(labelWithString: "")
    private let portsLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    /// The workspace's agent pane: `Claude Opus 4.5` over `ctx 53% · $117.99` (account limits are in the footer).
    private let agentNameLabel = NSTextField(labelWithString: "")
    private let agentLabel = NSTextField(labelWithString: "")
    private var agentKey: String?
    private var agentTooltip: String?
    private let notificationLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    /// What `usageLabel` currently shows; samples that change nothing visible skip the update.
    private var usageKey: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        for view in [dot, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            indicator.addSubview(view)
        }
        indicator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Self.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = Self.badgeFont
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        shortcutLabel.font = .systemFont(ofSize: 10)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Workspace"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = String(localized: "Close Workspace")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        topicLabel.font = Self.detailFont
        topicLabel.textColor = .labelColor.withAlphaComponent(0.85)
        topicLabel.lineBreakMode = .byTruncatingMiddle
        topicLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [hostLabel, branchLabel, directoryLabel, portsLabel] {
            label.font = Self.detailFont
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        directoryLabel.lineBreakMode = .byTruncatingHead
        portsLabel.font = Self.monoFont
        portsLabel.textColor = .systemGreen
        usageLabel.font = Self.usageFont
        usageLabel.lineBreakMode = .byClipping
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [agentNameLabel, agentLabel] {
            label.font = Self.usageFont
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        notificationLabel.font = Self.detailFont
        notificationLabel.textColor = .labelColor.withAlphaComponent(0.8)
        notificationLabel.maximumNumberOfLines = 2
        notificationLabel.lineBreakMode = .byWordWrapping
        notificationLabel.cell?.truncatesLastVisibleLine = true
        notificationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notificationLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let titleRow = NSStackView(views: [indicator, titleLabel, shortcutLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        // Second line: `Working  <task>` (the task replaces the cwd line).
        statusRow.setViews([stateLabel, topicLabel, directoryLabel], in: .leading)
        for label in [topicLabel, directoryLabel] {
            label.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .firstBaseline
        statusRow.detachesHiddenViews = true
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 10),
            indicator.heightAnchor.constraint(equalToConstant: 10),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 10),
            spinner.heightAnchor.constraint(equalToConstant: 10),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])

        stack.setViews([titleRow, statusRow, hostLabel, branchLabel, portsLabel, agentNameLabel, agentLabel, usageLabel, notificationLabel], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The × sits over the ⌘N hint (shown instead of it while hovering), so nothing moves.
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notificationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            agentNameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            closeButton.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 2),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Attributed strings are built when the cell may not be in the window yet (other appearance); rebuild them
    /// on the next sample once it is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        agentKey = nil
        usageKey = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        agentKey = nil
        usageKey = nil
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != self.hovering else { return }
        self.hovering = hovering
        closeButton.isHidden = !hovering
        shortcutLabel.alphaValue = hovering ? 0 : 1
    }

    @objc private func closeClicked() {
        guard let workspaceID else { return }
        onClose?(workspaceID)
    }

    // MARK: Content

    @MainActor
    func configure(with workspace: Workspace, index: Int) {
        workspaceID = workspace.id
        titleLabel.stringValue = workspace.displayTitle
        shortcutLabel.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        applyState(workspace)

        let directory = (workspace.isRemote ? workspace.workingDirectory : workspace.workingDirectory?.abbreviatingHome)
        let topic = workspace.agentTopic
        topicLabel.isHidden = topic == nil
        topicLabel.stringValue = topic ?? ""
        topicLabel.toolTip = [topic, directory].compactMap { $0 }.joined(separator: "\n")
        hostLabel.isHidden = workspace.sshPanes.isEmpty
        hostLabel.attributedStringValue = Self.hostText(workspace)
        branchLabel.isHidden = workspace.gitBranch == nil
        branchLabel.attributedStringValue = Self.symbolText("arrow.triangle.branch", workspace.gitBranch ?? "")
        // A remote path is shown as is (`~` abbreviation is for this Mac's home). The agent's task takes its place
        // (the cwd is then in the task's tooltip).
        directoryLabel.path = directory ?? ""
        directoryLabel.toolTip = directory
        directoryLabel.isHidden = directory == nil || topic != nil
        statusRow.isHidden = !Self.showsStatusRow(workspace)
        portsLabel.isHidden = workspace.ports.isEmpty
        portsLabel.stringValue = workspace.ports.map { ":\($0)" }.joined(separator: "  ")
        usageLabel.isHidden = !Self.showsUsage(workspace)
        agentLabel.isHidden = !Self.showsAgent(workspace)
        agentNameLabel.isHidden = agentLabel.isHidden
        agentKey = nil // reloads (selection changes) redraw the coloured runs for the row's new background
        updateUsage(with: workspace)
        notificationLabel.isHidden = workspace.notificationText == nil
        notificationLabel.stringValue = workspace.notificationText ?? ""
        notificationLabel.textColor = workspace.attention ? .labelColor : .secondaryLabelColor
    }

    /// Dot / spinner and the state text. The spinner runs only while the agent works.
    @MainActor
    private func applyState(_ workspace: Workspace) {
        let busy = workspace.agentActivity == .busy && !workspace.attention
        if busy {
            dot.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            let color = AgentActivityStyle.dotColor(for: workspace)
            dot.isHidden = color == nil
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.layer?.backgroundColor = color?.cgColor
            }
        }
        let badge = AgentActivityStyle.badge(for: workspace)
        self.badge = badge
        stateLabel.isHidden = badge == nil
        if let badge {
            if stateLabel.stringValue != badge.text { stateLabel.stringValue = badge.text }
            applyBadgeColor()
        }
        indicator.setAccessibilityElement(badge != nil || workspace.attention)
        indicator.setAccessibilityLabel(badge?.text)
    }

    private var badge: AgentActivityStyle.Badge?

    /// On an emphasized (accent) selection the state colours would vanish: use the label colour there.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyBadgeColor() }
    }

    private func applyBadgeColor() {
        guard let badge else { return }
        stateLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : badge.color
    }

    @MainActor
    static func height(for workspace: Workspace, width: CGFloat) -> CGFloat {
        var lines: [CGFloat] = [titleHeight]
        if showsStatusRow(workspace) { lines.append(detailHeight) }
        if !workspace.sshPanes.isEmpty { lines.append(detailHeight) }
        if workspace.gitBranch != nil { lines.append(detailHeight) }
        if !workspace.ports.isEmpty { lines.append(detailHeight) }
        if showsUsage(workspace) { lines.append(detailHeight) }
        if showsAgent(workspace) { lines += [detailHeight, detailHeight] }
        if let text = workspace.notificationText {
            let available = max(width - 2 * horizontalInset - 24, 40) // source-list rows are inset
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: detailFont])
            lines.append(bounds.height > detailHeight * 1.5 ? detailHeight * 2 : detailHeight)
        }
        return lines.reduce(0, +) + CGFloat(lines.count - 1) * spacing + 2 * verticalInset
    }

    /// Second line: agent state + task, else the cwd.
    @MainActor
    private static func showsStatusRow(_ workspace: Workspace) -> Bool {
        AgentActivityStyle.badge(for: workspace) != nil || workspace.agentTopic != nil || workspace.workingDirectory != nil
    }

    /// The usage line depends only on structure (a terminal exists), never on sampled values, so new
    /// samples never change row heights.
    @MainActor
    private static func showsUsage(_ workspace: Workspace) -> Bool { workspace.hasTerminal }

    /// The agent line appears/disappears only with structural changes (an agent pane appears or goes away).
    @MainActor
    private static func showsAgent(_ workspace: Workspace) -> Bool { !workspace.agentPanes.isEmpty }

    /// Agent line: the focused (else latest) agent pane's model, context and cost; account limits (tooltip only)
    /// come from the newest report of that agent kind. Touches the label only when its text or colours change.
    @MainActor
    private func updateAgent(with workspace: Workspace) {
        guard let primary = workspace.primaryAgent else {
            agentKey = nil
            return
        }
        let usage = primary.usage
        // Session figures only: the account limits (5h/7d) are the same for every row and shown in the footer.
        let parts = AgentFormat.summaryParts(usage, limits: [], strings: .localized)
        let others = workspace.agentPanes.count - 1
        let key = parts.map { "\($0.text)\($0.level.rawValue)" }.joined() + "|\(usage.isStale)|\(others)"
        if key != agentKey {
            agentKey = key
            let name = parts.prefix { $0.style == .name }
            var figures = Array(parts.drop { $0.style == .name })
            if figures.first?.style == .separator { figures.removeFirst() }
            if figures.isEmpty { figures = [AgentFormat.Part("–", .label)] }
            agentNameLabel.attributedStringValue = Self.agentText(Array(name), stale: usage.isStale, others: others)
            agentLabel.attributedStringValue = Self.agentText(figures, stale: usage.isStale, others: 0)
        }
        let now = Date()
        var blocks = workspace.agentPanes.compactMap { pane -> String? in
            guard let usage = pane.agentUsage else { return nil }
            return (AgentFormat.detailLines(usage, now: now, strings: .localized) + [pane.id == primary.pane.id ? String(localized: "Pane \(pane.id) (shown)") : String(localized: "Pane \(pane.id)")])
                .joined(separator: "\n")
        }
        if let limits = AppController.shared.agentLimitsByKind[usage.agent]?.active(at: now) {
            blocks.append(([String(localized: "\(usage.agent.displayName) account")] + AgentFormat.limitLines(limits.limits, now: now, strings: .localized))
                          .joined(separator: "\n"))
        }
        let tooltip = blocks.joined(separator: "\n\n")
        if tooltip != agentTooltip {
            agentTooltip = tooltip
            agentLabel.toolTip = tooltip
            agentNameLabel.toolTip = tooltip
        }
    }

    private static func agentText(_ parts: [AgentFormat.Part], stale: Bool, others: Int) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString()
        for part in parts {
            var color: NSColor
            var font = usageFont
            switch part.style {
            case .name:
                color = .labelColor.withAlphaComponent(0.85)
                font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            case .label, .separator: color = .tertiaryLabelColor
            case .value: color = .secondaryLabelColor
            }
            switch part.level {
            case .warning: color = .systemOrange
            case .critical: color = .systemRed
            case .normal: break
            }
            if stale { color = part.style == .name ? .secondaryLabelColor : .tertiaryLabelColor }
            result.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color,
                                                                              .paragraphStyle: paragraph]))
        }
        if others > 0 {
            result.append(NSAttributedString(string: "  +\(others)", attributes: [
                .font: usageFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph]))
        }
        return result
    }

    /// `CPU 12%  1.2 GB` and the agent line. Called for every sample; touches labels only when what they show changes.
    @MainActor
    func updateUsage(with workspace: Workspace) {
        updateAgent(with: workspace)
        let cpu = workspace.cpuPercent.map(ResourceFormat.percent) ?? "–"
        let memory = workspace.memoryBytes.map(ResourceFormat.bytes) ?? "–"
        let busy = workspace.busySamples >= 2
        let key = "\(cpu)|\(memory)|\(busy)|\(workspace.processCount)"
        guard key != usageKey else { return }
        usageKey = key
        usageLabel.attributedStringValue = Self.usageText(cpu: cpu, memory: memory, busy: busy)
        if workspace.memoryBytes == nil {
            usageLabel.toolTip = String(localized: "CPU and memory of the processes in this workspace's terminals (measuring…)")
        } else {
            let count = workspace.processCount
            let precise = workspace.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–"
            usageLabel.toolTip = String(localized: "CPU \(precise) (100% = one core)") + "\n"
                + String(localized: "Memory \(memory) (physical footprint)") + "\n"
                + String(localized: "\(count) processes in this workspace's terminals")
                + (workspace.sshPanes.isEmpty ? "" : "\n" + String(localized: "SSH panes count only the local ssh client, not the server"))
        }
    }

    private static func usageText(cpu: String, memory: String, busy: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: usageTabStop)]
        paragraph.lineBreakMode = .byClipping
        let label: [NSAttributedString.Key: Any] = [.font: usageFont, .paragraphStyle: paragraph,
                                                     .foregroundColor: NSColor.tertiaryLabelColor]
        var value = label
        value[.foregroundColor] = NSColor.secondaryLabelColor
        var cpuValue = value
        if busy { cpuValue[.foregroundColor] = NSColor.systemOrange }
        let result = NSMutableAttributedString(string: "CPU ", attributes: label)
        result.append(NSAttributedString(string: cpu, attributes: cpuValue))
        result.append(NSAttributedString(string: "\t", attributes: label))
        result.append(NSAttributedString(string: memory, attributes: value))
        return result
    }

    /// `⌁ ssh home` for the focused SSH pane (else the first), `+N` for more hosts, orange "disconnected" while down.
    @MainActor
    private static func hostText(_ workspace: Workspace) -> NSAttributedString {
        let panes = workspace.sshPanes
        guard let shown = panes.first(where: { $0.id == workspace.focusedPaneID }) ?? panes.first,
              let ssh = shown.ssh else { return NSAttributedString() }
        let otherHosts = Set(panes.compactMap { $0.ssh?.launch.host }).subtracting([ssh.launch.host]).count
        let text = symbolText("network", ssh.launch.label + (otherHosts > 0 ? "  +\(otherHosts)" : "")).mutableCopy() as! NSMutableAttributedString
        if !ssh.connected {
            text.append(NSAttributedString(string: String(localized: " · disconnected"), attributes: [
                .font: detailFont, .foregroundColor: NSColor.systemOrange]))
        }
        return text
    }

    private static func symbolText(_ symbol: String, _ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttributes([.font: detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        return result
    }
}
