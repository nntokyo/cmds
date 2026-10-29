import AppKit
import CmdsCore

/// Sidebar row: attention dot + title + ⌘N hint, branch, cwd, ports, CPU/memory, latest notification (≤ 2 lines).
final class WorkspaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let usageFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Memory starts at a fixed tab stop so changing CPU digits never shift it.
    private static let usageTabStop: CGFloat = 60
    private static let horizontalInset: CGFloat = 10
    private static let verticalInset: CGFloat = 6
    private static let spacing: CGFloat = 2
    private static let titleHeight: CGFloat = 17
    private static let detailHeight: CGFloat = 14

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let portsLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
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
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Self.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.font = .systemFont(ofSize: 10)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for label in [branchLabel, directoryLabel, portsLabel] {
            label.font = Self.detailFont
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        portsLabel.font = Self.monoFont
        portsLabel.textColor = .systemGreen
        usageLabel.font = Self.usageFont
        usageLabel.lineBreakMode = .byClipping
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notificationLabel.font = Self.detailFont
        notificationLabel.textColor = .labelColor.withAlphaComponent(0.8)
        notificationLabel.maximumNumberOfLines = 2
        notificationLabel.lineBreakMode = .byWordWrapping
        notificationLabel.cell?.truncatesLastVisibleLine = true
        notificationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notificationLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let titleRow = NSStackView(views: [dot, titleLabel, shortcutLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        stack.setViews([titleRow, branchLabel, directoryLabel, portsLabel, usageLabel, notificationLabel], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notificationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(with workspace: Workspace, index: Int) {
        titleLabel.stringValue = workspace.title
        shortcutLabel.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        dot.isHidden = !workspace.attention

        branchLabel.isHidden = workspace.gitBranch == nil
        branchLabel.attributedStringValue = Self.symbolText("arrow.triangle.branch", workspace.gitBranch ?? "")
        directoryLabel.stringValue = workspace.workingDirectory?.abbreviatingHome ?? ""
        directoryLabel.isHidden = workspace.workingDirectory == nil
        portsLabel.isHidden = workspace.ports.isEmpty
        portsLabel.stringValue = workspace.ports.map { ":\($0)" }.joined(separator: "  ")
        usageLabel.isHidden = !Self.showsUsage(workspace)
        updateUsage(with: workspace)
        notificationLabel.isHidden = workspace.notificationText == nil
        notificationLabel.stringValue = workspace.notificationText ?? ""
        notificationLabel.textColor = workspace.attention ? .labelColor : .secondaryLabelColor
    }

    @MainActor
    static func height(for workspace: Workspace, width: CGFloat) -> CGFloat {
        var lines: [CGFloat] = [titleHeight]
        if workspace.gitBranch != nil { lines.append(detailHeight) }
        if workspace.workingDirectory != nil { lines.append(detailHeight) }
        if !workspace.ports.isEmpty { lines.append(detailHeight) }
        if showsUsage(workspace) { lines.append(detailHeight) }
        if let text = workspace.notificationText {
            let available = max(width - 2 * horizontalInset - 24, 40) // source-list rows are inset
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: detailFont])
            lines.append(bounds.height > detailHeight * 1.5 ? detailHeight * 2 : detailHeight)
        }
        return lines.reduce(0, +) + CGFloat(lines.count - 1) * spacing + 2 * verticalInset
    }

    /// The usage line depends only on structure (a terminal exists), never on sampled values, so new
    /// samples never change row heights.
    @MainActor
    private static func showsUsage(_ workspace: Workspace) -> Bool { workspace.hasTerminal }

    /// `CPU 12%  1.2 GB`. Called for every sample; touches the label only when what it shows changes.
    @MainActor
    func updateUsage(with workspace: Workspace) {
        let cpu = workspace.cpuPercent.map(ResourceFormat.percent) ?? "–"
        let memory = workspace.memoryBytes.map(ResourceFormat.bytes) ?? "–"
        let busy = workspace.busySamples >= 2
        let key = "\(cpu)|\(memory)|\(busy)|\(workspace.processCount)"
        guard key != usageKey else { return }
        usageKey = key
        usageLabel.attributedStringValue = Self.usageText(cpu: cpu, memory: memory, busy: busy)
        if workspace.memoryBytes == nil {
            usageLabel.toolTip = "CPU and memory of the processes in this workspace's terminals (measuring…)"
        } else {
            let count = workspace.processCount
            let precise = workspace.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–"
            usageLabel.toolTip = "CPU \(precise) (100% = one core)\nMemory \(memory) (physical footprint)\n"
                + "\(count) process\(count == 1 ? "" : "es") in this workspace's terminals"
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
