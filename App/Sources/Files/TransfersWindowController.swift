import AppKit
import CmdsCore

/// Window › Transfers (docs/guide/files.md "Transfers"): every job of the transfer queue with its progress, Pause /
/// Resume, Cancel, Retry and its log; Clear Finished removes the finished ones.
@MainActor
final class TransfersWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = TransfersWindowController()

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No transfers. Copies and moves to and from SSH hosts appear here."))
    private let clearButton = NSButton(title: String(localized: "Clear Finished"), target: nil, action: nil)
    private var jobs: [TransferJob.Snapshot] = []
    private var observer: NSObjectProtocol?
    private lazy var bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = String(localized: "Transfers")
        window.setFrameAutosaveName(CmdsEnv.supportDirectoryOverride() == nil ? "Transfers" : "")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 200)
        super.init(window: window)
        build()
        observer = NotificationCenter.default.addObserver(forName: .transfersDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(showLogOfClickedRow)
        tableView.setAccessibilityIdentifier("transfers.table")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, emptyLabel, clearButton] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),
            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }

    private func reload() {
        let new = TransferCenter.shared.queue.snapshots.reversed().map { $0 }
        let sameJobs = new.map(\.id) == jobs.map(\.id)
        jobs = new
        if sameJobs {
            // Update the rows in place (keeps buttons under the mouse).
            for row in jobs.indices {
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TransferRowView)?.show(jobs[row], bytes: bytes)
            }
        } else {
            tableView.reloadData()
        }
        emptyLabel.isHidden = !jobs.isEmpty
        clearButton.isEnabled = jobs.contains { $0.state.isFinished }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: TransferRowView.identifier, owner: self) as? TransferRowView
            ?? TransferRowView()
        view.onAction = { [weak self] action, id in self?.perform(action, id: id) }
        view.show(jobs[row], bytes: bytes)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    private func perform(_ action: TransferRowView.Action, id: Int) {
        let center = TransferCenter.shared
        switch action {
        case .pause: try? center.pause(id: id)
        case .resume: try? center.resume(id: id)
        case .cancel: try? center.cancel(id: id)
        case .retry: try? center.retry(id: id)
        case .log: showLog(id: id)
        }
    }

    @objc private func clearFinished() { TransferCenter.shared.clearFinished() }

    @objc private func showLogOfClickedRow() {
        guard let job = jobs[safe: tableView.clickedRow] else { return }
        showLog(id: job.id)
    }

    private func showLog(id: Int) {
        guard let job = jobs.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert()
        alert.messageText = job.localizedTitle
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        var lines = job.log.map { "\(formatter.string(from: $0.date))  \($0.path): \($0.outcome.localizedText)" }
        if let error = job.error { lines.append(String(localized: "Stopped: \(error)")) }
        if lines.isEmpty { lines = [job.localizedStatus(bytes: bytes)] }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = lines.joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { _ in }
    }
}

/// One job in the Transfers window: title, progress bar, status line and its buttons.
@MainActor
private final class TransferRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("transfers.row")

    enum Action { case pause, resume, cancel, retry, log }

    var onAction: ((Action, Int) -> Void)?
    private var jobID = 0
    private var pauseIsResume = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let pauseButton = TransferRowView.button("pause.fill", String(localized: "Pause"))
    private let cancelButton = TransferRowView.button("xmark.circle.fill", String(localized: "Cancel"))
    private let retryButton = TransferRowView.button("arrow.clockwise", String(localized: "Retry"))
    private let logButton = TransferRowView.button("list.bullet", String(localized: "Show Log"))

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        for (button, action) in [(pauseButton, #selector(pauseClicked)), (cancelButton, #selector(cancelClicked)),
                                 (retryButton, #selector(retryClicked)), (logButton, #selector(logClicked))] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [pauseButton, cancelButton, retryButton, logButton])
        buttons.spacing = 4
        let text = NSStackView(views: [titleLabel, progress, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [text, buttons])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ job: TransferJob.Snapshot, bytes: ByteCountFormatter) {
        jobID = job.id
        titleLabel.stringValue = job.localizedTitle
        statusLabel.stringValue = job.localizedStatus(bytes: bytes)
        statusLabel.textColor = job.state == .failed ? .systemRed : .secondaryLabelColor
        let total = job.progress.bytesTotal
        progress.isIndeterminate = job.progress.counting
        if job.progress.counting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.doubleValue = job.state == .done ? 1
            : total > 0 ? Double(job.progress.bytesDone) / Double(total)
            : job.progress.itemsTotal > 0 ? Double(job.progress.itemsDone) / Double(job.progress.itemsTotal) : 0
        progress.isHidden = job.state.isFinished
        let active = !job.state.isFinished
        pauseIsResume = job.state == .paused
        pauseButton.isHidden = !active || job.state == .waiting
        pauseButton.image = NSImage(systemSymbolName: pauseIsResume ? "play.fill" : "pause.fill",
                                    accessibilityDescription: pauseIsResume ? String(localized: "Resume") : String(localized: "Pause"))
        pauseButton.toolTip = pauseIsResume ? String(localized: "Resume") : String(localized: "Pause")
        cancelButton.isHidden = !active
        retryButton.isHidden = !(job.state == .failed || job.state == .cancelled)
        logButton.isHidden = job.log.isEmpty && job.error == nil
    }

    @objc private func pauseClicked() { onAction?(pauseIsResume ? .resume : .pause, jobID) }
    @objc private func cancelClicked() { onAction?(.cancel, jobID) }
    @objc private func retryClicked() { onAction?(.retry, jobID) }
    @objc private func logClicked() { onAction?(.log, jobID) }
}
