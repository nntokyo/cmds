import AppKit
import CmdsCore

/// A row of cards, one per Claude Code subagent of a workspace (running ones with a spinner, finished ones dimmed until
/// they go). Shown under a tile of the tiled view and, with Settings › Agents › Everywhere, under the single workspace.
@MainActor
final class SubagentStripView: NSView {
    static let height: CGFloat = 44
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 6
    private static let minCardWidth: CGFloat = 150
    private static let maxCardWidth: CGFloat = 260

    private var cards: [String: SubagentCardView] = [:]
    private var order: [String] = []
    private let moreLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        moreLabel.font = .systemFont(ofSize: 11, weight: .medium)
        moreLabel.textColor = .secondaryLabelColor
        addSubview(moreLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Subagents"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Cards for `agents` (in order); cards of agents no longer listed are removed.
    func update(_ agents: [SubagentInfo], now: Date = Date()) {
        let ids = agents.map(\.id)
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for agent in agents {
            let card = cards[agent.id] ?? {
                let card = SubagentCardView()
                addSubview(card)
                cards[agent.id] = card
                return card
            }()
            card.update(agent, now: now)
        }
        if ids != order {
            order = ids
            needsLayout = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let available = bounds.width - 2 * Self.inset
        let count = order.count
        guard count > 0, available > 0 else {
            moreLabel.isHidden = true
            return
        }
        let height = bounds.height - 2 * Self.inset
        let moreWidth: CGFloat = 36
        // As many cards as fit at their minimum width (leaving room for "+N" when some are left out).
        var fitting = max(1, Int((available + Self.gap) / (Self.minCardWidth + Self.gap)))
        if fitting < count {
            fitting = max(1, Int((available - moreWidth + Self.gap) / (Self.minCardWidth + Self.gap)))
        }
        let shown = min(fitting, count)
        let room = available - (shown < count ? moreWidth : 0)
        let width = min(Self.maxCardWidth, (room - CGFloat(shown - 1) * Self.gap) / CGFloat(shown))
        for (index, id) in order.enumerated() {
            guard let card = cards[id] else { continue }
            card.isHidden = index >= shown
            card.frame = NSRect(x: Self.inset + CGFloat(index) * (width + Self.gap), y: Self.inset,
                                width: max(width, 0), height: height)
        }
        moreLabel.isHidden = shown >= count
        moreLabel.stringValue = "+\(count - shown)"
        moreLabel.sizeToFit()
        moreLabel.frame.origin = NSPoint(x: Self.inset + CGFloat(shown) * (width + Self.gap),
                                         y: (bounds.height - moreLabel.frame.height) / 2)
    }
}

/// One subagent: `type · description` over `action · elapsed · tokens`.
@MainActor
private final class SubagentCardView: NSView {
    private let spinner = NSProgressIndicator()
    private let doneIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        doneIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: String(localized: "Done"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        doneIcon.contentTintColor = .systemGreen
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [spinner, doneIcon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            doneIcon.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
            doneIcon.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ agent: SubagentInfo, now: Date) {
        let running = agent.state == .running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        doneIcon.isHidden = running
        let title = agent.title.isEmpty ? String(localized: "Subagent") : agent.title
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        var parts: [String] = []
        if running {
            parts.append(agent.action ?? String(localized: "Working…", comment: "subagent without a current tool call"))
        } else {
            parts.append(String(localized: "Done", comment: "subagent finished"))
        }
        parts.append(AgentFormat.duration(milliseconds: agent.elapsedSeconds * 1000, strings: .localized))
        if let tokens = agent.tokens { parts.append(String(localized: "\(AgentFormat.tokens(tokens)) tokens")) }
        let detail = parts.joined(separator: " · ")
        if detailLabel.stringValue != detail { detailLabel.stringValue = detail }
        // Finished: dimmed, fading out over the last seconds before it goes.
        var alpha: CGFloat = 1
        if !running {
            let left = AppController.subagentDoneLinger - now.timeIntervalSince(agent.endedAt ?? now)
            alpha = 0.6 * CGFloat(min(max(left / 5, 0.15), 1))
        }
        alphaValue = alpha
        toolTip = [title, agent.action].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel([title, detail].joined(separator: ", "))
    }
}
