import AppKit
import CmdsCore

/// Compact sidebar row (the ~52 pt rail): the workspace number (⌘1–⌘9), an attention dot and a thin status bar
/// coloured by the most pressing of: sustained CPU above one core, the agent's context, the agent's account
/// limits (orange from 80 %, red from 95 %); a calm grey while an agent runs otherwise. The tooltip has the full row.
final class CompactWorkspaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompactWorkspaceCell")
    static let height: CGFloat = 34

    private let numberLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let statusBar = NSView()
    private var statusKey: String?
    private var tooltipText: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        numberLabel.alignment = .center
        numberLabel.lineBreakMode = .byClipping
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusBar.wantsLayer = true
        statusBar.layer?.cornerRadius = 1
        for view in [numberLabel, dot, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            numberLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 1),
            dot.topAnchor.constraint(equalTo: numberLabel.topAnchor, constant: 1),
            statusBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusBar.widthAnchor.constraint(equalToConstant: 16),
            statusBar.heightAnchor.constraint(equalToConstant: 2),
            statusBar.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(with workspace: Workspace, index: Int) {
        let number = "\(index + 1)"
        if numberLabel.stringValue != number { numberLabel.stringValue = number }
        dot.isHidden = !workspace.attention
        numberLabel.textColor = workspace.attention ? .labelColor : .secondaryLabelColor
        statusKey = nil
        updateUsage(with: workspace)
    }

    /// Called for every usage sample; touches layers/tooltips only when they change.
    @MainActor
    func updateUsage(with workspace: Workspace) {
        let agent = workspace.primaryAgent?.usage
        var level = UsageLevel.normal
        if workspace.busySamples >= 2 { level = .warning }
        if let agent {
            level = max(level, UsageLevel(percent: agent.contextUsedPercent))
            if let limits = AppController.shared.agentLimitsByKind[agent.agent]?.active(at: Date()) {
                level = max(level, limits.limits.map { UsageLevel(percent: $0.usedPercent) }.max() ?? .normal)
            }
        }
        let key = "\(level.rawValue)|\(agent != nil)|\(agent?.isStale == true)"
        if key != statusKey {
            statusKey = key
            let color: NSColor?
            switch level {
            case .critical: color = .systemRed
            case .warning: color = .systemOrange
            case .normal: color = agent == nil ? nil : NSColor.secondaryLabelColor.withAlphaComponent(agent?.isStale == true ? 0.3 : 0.6)
            }
            statusBar.isHidden = color == nil
            effectiveAppearance.performAsCurrentDrawingAppearance {
                statusBar.layer?.backgroundColor = color?.cgColor
            }
        }
        let text = Self.tooltip(workspace, index: Int(numberLabel.stringValue).map { $0 - 1 } ?? 0)
        if text != tooltipText {
            tooltipText = text
            toolTip = text
            setAccessibilityLabel(text)
        }
    }

    /// Everything the full row shows.
    @MainActor
    private static func tooltip(_ workspace: Workspace, index: Int) -> String {
        var lines = [workspace.title + (index < 9 ? "  ⌘\(index + 1)" : "")]
        if let branch = workspace.gitBranch { lines.append("⎇ \(branch)") }
        if let cwd = workspace.workingDirectory { lines.append(cwd.abbreviatingHome) }
        if !workspace.ports.isEmpty { lines.append(workspace.ports.map { ":\($0)" }.joined(separator: "  ")) }
        if let agent = workspace.primaryAgent?.usage {
            let limits = AppController.shared.agentLimitsByKind[agent.agent]?.active(at: Date())?.limits
            lines.append(AgentFormat.summary(agent, limits: limits) + (agent.isStale ? " (idle)" : ""))
        }
        if workspace.hasTerminal {
            lines.append(ResourceFormat.usage(cpuPercent: workspace.cpuPercent, memoryBytes: workspace.memoryBytes))
        }
        if let note = workspace.notificationText { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}
