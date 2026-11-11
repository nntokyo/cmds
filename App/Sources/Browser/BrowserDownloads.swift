import AppKit
import WebKit
import CmdsCore

/// Downloads of browser panes (#235): into ~/Downloads under a name not taken yet (`BrowserDownloadName`), reported in
/// the pane's banner. WebKit quarantines the file itself (`com.apple.quarantine`, so Gatekeeper checks what is opened
/// from it). Kept here, not in the pane, so a download goes on when its pane closes.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()

    private final class Item {
        let download: WKDownload
        weak var pane: BrowserPane?
        var destination: URL?
        var name = ""

        init(download: WKDownload, pane: BrowserPane?) {
            self.download = download
            self.pane = pane
        }
    }

    private var items: [ObjectIdentifier: Item] = [:]

    func start(_ download: WKDownload, for pane: BrowserPane?) {
        download.delegate = self
        items[ObjectIdentifier(download)] = Item(download: download, pane: pane)
    }

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let item = items[ObjectIdentifier(download)] else { return completionHandler(nil) }
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = BrowserDownloadName.unique(BrowserDownloadName.sanitized(suggestedFilename), in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        item.destination = destination
        item.name = destination.lastPathComponent
        item.pane?.showDownload(.downloading(name: item.name)) { [weak self, weak download] in
            guard let download else { return }
            download.cancel { _ in }
            self?.items[ObjectIdentifier(download)] = nil
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)), let destination = item.destination else {
            return
        }
        // Bounces the Downloads stack in the Dock, as Safari's downloads do.
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"),
                                                     object: destination.path)
        item.pane?.showDownload(.finished(name: item.name, file: destination))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return item.pane?.showDownload(nil) ?? () }
        let name = item.name.isEmpty ? (download.originalRequest?.url?.lastPathComponent ?? "") : item.name
        item.pane?.showDownload(.failed(name: name, reason: error.localizedDescription))
    }
}

/// The download notice at the bottom of a browser pane (same look as the agent banners; never takes the keyboard).
final class BrowserDownloadBannerView: NSVisualEffectView {
    enum State {
        case downloading(name: String)
        case finished(name: String, file: URL)
        case failed(name: String, reason: String)
    }

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?
    let notice: State

    init(state: State) {
        self.notice = state
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityIdentifier("cmds.browserDownloadBanner")

        let symbol: String
        let tint: NSColor
        let text: String
        var buttons: [NSButton] = []
        switch state {
        case .downloading(let name):
            symbol = "arrow.down.circle"
            tint = .controlAccentColor
            text = String(localized: "Downloading “\(name)”…")
            buttons.append(button(String(localized: "Cancel"), #selector(cancelClicked)))
        case .finished(let name, _):
            symbol = "checkmark.circle"
            tint = .systemGreen
            text = String(localized: "Downloaded “\(name)” to Downloads")
            buttons.append(button(String(localized: "Show in Finder"), #selector(showClicked), primary: true))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .failed(let name, let reason):
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
            text = name.isEmpty ? String(localized: "Download failed: \(reason)")
                : String(localized: "Download of “\(name)” failed: \(reason)")
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = text

        let stack = NSStackView(views: [icon, label] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.refusesFirstResponder = true
        if primary { button.bezelColor = .controlAccentColor }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func dismissClicked() { onDismiss?() }

    @objc private func showClicked() {
        if case .finished(_, let file) = notice { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        onDismiss?()
    }
}
