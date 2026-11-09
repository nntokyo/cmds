import AppKit
import Combine
import CmdsCore

/// Sidebar footer row "3 leftover processes · 1.2 GB" (#193): processes started from cmds terminals whose pane or
/// workspace was closed. Hidden when there are none; a click opens `LeftoverProcessesController` in a popover.
@MainActor
enum LeftoverIndicator {
    static func makeButton() -> NSButton {
        let button = NSButton(title: "", target: Opener.shared, action: #selector(Opener.open(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .systemOrange
        applyTextSize(to: button)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.lineBreakMode = .byTruncatingTail
        button.isHidden = true
        button.toolTip = String(localized: "Processes started from cmds terminals that still run after their pane or workspace was closed. Click to see and stop them.")
        return button
    }

    static func applyTextSize(to button: NSButton) {
        button.font = .systemFont(ofSize: SidebarTextSize.size(10), weight: .medium)
        button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SidebarTextSize.size(10), weight: .medium))
    }

    /// `3 leftover processes · 1.2 GB`.
    static func title(_ list: ProcessList) -> String {
        String(localized: "\(list.total) leftover processes · \(ResourceFormat.bytes(list.totalMemoryBytes))",
               comment: "sidebar footer: processes whose pane was closed, and their memory")
    }

    static func apply(_ list: ProcessList, to button: NSButton) {
        if button.isHidden != (list.total == 0) { button.isHidden = list.total == 0 }
        guard list.total > 0 else { return }
        let title = title(list)
        if button.title != title { button.title = title }
    }

    @MainActor final class Opener: NSObject {
        static let shared = Opener()
        private var popover: NSPopover?

        @objc func open(_ sender: Any?) {
            if let popover, popover.isShown {
                popover.performClose(sender)
                return
            }
            guard let button = sender as? NSView else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = LeftoverProcessesController(controller: AppController.shared)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}

/// The leftover processes with a Stop button each (SIGTERM; a second click sends SIGKILL). Follows the scans while open.
@MainActor
final class LeftoverProcessesController: NSViewController {
    private let controller: AppController
    private let stack = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private var subscription: AnyCancellable?
    /// Processes already sent SIGTERM (pid → start): their button sends SIGKILL.
    private var terminated: [Int32: Double] = [:]
    private var shownKey = ""

    init(controller: AppController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Leftover Processes"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString: String(localized: "Started from cmds terminals whose pane or workspace was closed (dev servers, test runners, browser drivers…). They still use memory. Stop sends SIGTERM; if one keeps running, Force Stop sends SIGKILL."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let content = NSStackView(views: [title, note, stack, summary])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.widthAnchor.constraint(equalToConstant: 420).isActive = true
        view = content
        reload()
        subscription = controller.usageChanges.sink { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let list = controller.leftoverProcesses()
        let key = list.processes.map { "\($0.pid)|\($0.memoryBytes)|\(terminated[$0.pid] == $0.started)" }.joined(separator: ",")
        guard key != shownKey else { return }
        shownKey = key
        for view in stack.arrangedSubviews { stack.removeView(view) }
        terminated = terminated.filter { pid, started in list.processes.contains { $0.pid == pid && $0.started == started } }
        for process in list.processes.prefix(30) { stack.addArrangedSubview(row(process)) }
        summary.stringValue = list.total == 0
            ? String(localized: "No leftover processes.")
            : LeftoverIndicator.title(list) + (list.total > 30 ? " · " + String(localized: "see cmds top --leftover") : "")
    }

    private func row(_ process: ProcessEntry) -> NSView {
        let name = NSTextField(labelWithString: process.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let detail = NSTextField(labelWithString: [process.command, "pid \(process.pid) · \(process.pane ?? process.workspace)"]
            .compactMap { $0 }.joined(separator: "\n"))
        detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 2
        detail.toolTip = process.command
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let memory = NSTextField(labelWithString: ResourceFormat.bytes(process.memoryBytes))
        memory.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let force = terminated[process.pid] == process.started
        let stop = NSButton(title: force ? String(localized: "Force Stop") : String(localized: "Stop"),
                            target: self, action: #selector(stop(_:)))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.tag = Int(process.pid)
        stop.identifier = NSUserInterfaceItemIdentifier(String(process.started))
        let row = NSStackView(views: [text, memory, stop])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 388).isActive = true
        return row
    }

    @objc private func stop(_ sender: NSButton) {
        let pid = Int32(sender.tag)
        let started = sender.identifier.flatMap { Double($0.rawValue) }
        let force = started != nil && terminated[pid] == started
        do {
            try controller.killProcess(ProcessKillRequest(pid: pid, force: force, started: started))
            if let started { terminated[pid] = started }
            sender.isEnabled = false
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not stop the process")
            alert.informativeText = (error as? RPCError)?.message ?? "\(error)"
            alert.runModal()
        }
    }
}
