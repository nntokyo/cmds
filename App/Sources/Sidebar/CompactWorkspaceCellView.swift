import AppKit
import CmdsCore

/// Compact sidebar row (the ~52 pt rail): the workspace number (⌘1–⌘9), an attention dot and a thin status bar
/// coloured by the most pressing of: sustained CPU above one core, the agent's context, the agent's account
/// limits (orange from 80 %, red from 95 %); a calm grey while an agent runs otherwise. The tooltip has the full row.
final class CompactWorkspaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompactWorkspaceCell")
    /// Row height and number font follow the sidebar text size (cmds › Settings…).
    static var height: CGFloat { (34 * SidebarTextSize.scale).rounded() }
    private static var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: SidebarTextSize.size(13), weight: .semibold) }
    private var appliedScale = SidebarTextSize.scale

    private let numberLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let statusBar = NSView()
    private var statusKey: String?
    private var tooltipText: String?
    /// The Claude account of the agent's session, as the full row's account button (#296): its colour only (the
    /// name is in the tooltip); a click opens the same menu.
    private let accountButton = NSButton()
    private var accountKey: String?
    private var accountTitle: String?
    private var workspaceID: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        numberLabel.font = Self.numberFont
        numberLabel.alignment = .center
        numberLabel.lineBreakMode = .byClipping
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusBar.wantsLayer = true
        statusBar.layer?.cornerRadius = 1
        accountButton.isBordered = false
        accountButton.imagePosition = .imageOnly
        accountButton.target = self
        accountButton.action = #selector(accountClicked)
        accountButton.isHidden = true
        for view in [numberLabel, dot, statusBar, accountButton] {
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
            // Left of the number (the attention dot is on its right), so the row keeps its height.
            accountButton.trailingAnchor.constraint(equalTo: numberLabel.leadingAnchor, constant: -1),
            accountButton.centerYAnchor.constraint(equalTo: numberLabel.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(with workspace: Workspace, index: Int) {
        workspaceID = workspace.id
        if appliedScale != SidebarTextSize.scale {
            appliedScale = SidebarTextSize.scale
            numberLabel.font = Self.numberFont
            accountKey = nil
        }
        let number = "\(index + 1)"
        if numberLabel.stringValue != number { numberLabel.stringValue = number }
        // Same colours as the full row's dot: orange = attention / needs input, accent (pulsing) = working,
        // green = idle.
        let color = AgentActivityStyle.dotColor(for: workspace)
        dot.isHidden = color == nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color?.cgColor
        }
        let pulsing = AgentActivityStyle.isWorking(workspace)
        if pulsing, dot.layer?.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "pulse")
        } else if !pulsing {
            dot.layer?.removeAnimation(forKey: "pulse")
        }
        numberLabel.textColor = AgentActivityStyle.needsUser(workspace) ? .labelColor : .secondaryLabelColor
        statusKey = nil
        tooltipText = nil
        updateUsage(with: workspace)
    }

    /// Called for every usage sample; touches layers/tooltips only when they change.
    @MainActor
    func updateUsage(with workspace: Workspace) {
        let agent = workspace.primaryAgent?.usage
        var level = UsageLevel.normal
        if workspace.isCPUBusy { level = .warning }
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
        updateAccountButton(ClaudeAccountMenu.pane(of: workspace, controller: AppController.shared))
    }

    /// The account icon in the account's colour (the target's while a switch waits); hidden as in the full row.
    @MainActor
    private func updateAccountButton(_ pane: Pane?) {
        guard let pane else {
            accountKey = nil
            accountTitle = nil
            accountButton.isHidden = true
            return
        }
        let badge = ClaudeAccountMenu.badge(for: pane, controller: AppController.shared)
        let key = "\(badge.title)|\(badge.toolTip)|\(badge.color)"
        accountButton.isHidden = false
        guard key != accountKey else { return }
        accountKey = key
        accountTitle = badge.title
        accountButton.image = ClaudeAccountMenu.image(badge.color, pointSize: SidebarTextSize.size(10))
        // No room for a title: the tooltip names the account, and the target first while a switch waits.
        accountButton.toolTip = badge.switching ? badge.title + "\n" + badge.toolTip : badge.toolTip
        accountButton.setAccessibilityLabel(badge.accessibilityLabel)
    }

    @objc private func accountClicked() {
        guard let id = workspaceID, let workspace = AppController.shared.workspace(id: id),
              let menu = ClaudeAccountMenu.menu(for: workspace, controller: AppController.shared, in: window) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: accountButton.bounds.maxY + 2), in: accountButton)
    }

    #if DEBUG
    /// For `debug.sidebar_account`: the account shown (as the full row's title), nil while hidden.
    var debugAccountTitle: String? { accountButton.isHidden ? nil : accountTitle }
    #endif

    /// Everything the full row shows.
    @MainActor
    private static func tooltip(_ workspace: Workspace, index: Int) -> String {
        var lines = [workspace.displayTitle + (index < 9 ? "  ⌘\(index + 1)" : "")
                     + (AgentActivityStyle.badge(for: workspace).map { "  (\($0.text))" } ?? "")]
        if let topic = workspace.agentTopic { lines.append(topic) }
        if let host = workspace.remoteHost ?? workspace.sshPanes.first?.ssh?.launch.host { lines.append("ssh \(host)") }
        if let branch = workspace.gitBranch { lines.append("⎇ \(branch)") }
        if let cwd = workspace.workingDirectory { lines.append(cwd.abbreviatingHome) }
        if !workspace.ports.isEmpty { lines.append(workspace.portsText) }
        if let agent = workspace.primaryAgent?.usage {
            lines.append(AgentFormat.summary(agent, limits: [], strings: .localized) + (agent.isStale ? String(localized: " (idle)") : ""))
        }
        if WorkspaceCellView.showsUsage(workspace) {
            lines.append(ResourceFormat.usage(cpuPercent: workspace.cpuPercent, memoryBytes: workspace.memoryBytes))
        }
        if let note = workspace.notificationText { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}
