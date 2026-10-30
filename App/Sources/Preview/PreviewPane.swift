import AppKit
import CmdsCore
import Quartz
import UniformTypeIdentifiers
import WebKit

/// Preview pane: header bar (name, path → Finder, open in default app, reload) above the file's content.
/// Markdown and unified diffs are rendered by cmds (`MarkdownHTML`, `DiffHTML`) in a WKWebView with JavaScript off;
/// everything else goes to Quick Look (`QLPreviewView`). The file is watched and reloaded when it changes, including
/// atomic saves (write to a temporary file + rename over the original).
@MainActor
final class PreviewPane: NSView {
    /// The shown file changed (another path, or it appeared/disappeared).
    var onStateChange: (() -> Void)?

    private(set) var path: String
    /// Rendering forced by the caller (`cmds open --diff`); nil = from the file name.
    private(set) var forcedFormat: PreviewFormat?
    private(set) var fileExists = false

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathButton = NSButton(title: "", target: nil, action: nil)
    private let openButton = PreviewPane.headerButton("arrow.up.forward.app", label: String(localized: "Open in Default App"))
    private let reloadButton = PreviewPane.headerButton("arrow.clockwise", label: String(localized: "Reload"))
    private let contentHost = NSView()
    private var content: NSView?
    private var quickLook: QLPreviewView?
    private var webView: WKWebView?
    private var imageView: NSImageView?
    private var watcher: FileWatcher?
    private var reloadScheduled = false

    var format: PreviewFormat { forcedFormat ?? PreviewFormat.forFile(path) }
    var fileName: String { (path as NSString).lastPathComponent }

    init(path: String, format: PreviewFormat? = nil) {
        self.path = path
        forcedFormat = format
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        buildLayout()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Public API

    /// Shows another file in this pane.
    func open(path newPath: String, format: PreviewFormat? = nil) {
        path = newPath
        forcedFormat = format
        load()
        onStateChange?()
    }

    func reload() { load(keepScroll: true) }

    func focus() {
        if let content, content === quickLook || content === webView {
            window?.makeFirstResponder(content)
        } else {
            window?.makeFirstResponder(self) // image / placeholder: take the keyboard away from the previous pane
        }
    }

    #if DEBUG
    /// PNG of the pane as drawn, also while the window is hidden or on another Space (tests; web content via
    /// WKWebView's snapshot, which renders off screen).
    func debugSnapshot() async throws -> Data {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { throw RPCError(code: 500, message: "no bitmap") }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        if let webView, content === webView {
            let web: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) } else {
                        continuation.resume(throwing: error ?? RPCError(code: 500, message: "snapshot failed"))
                    }
                }
            }
            let frame = webView.convert(webView.bounds, to: self)
            image.lockFocusFlipped(isFlipped)
            web.draw(in: frame)
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RPCError(code: 500, message: "PNG encoding failed")
        }
        return png
    }
    #endif

    func tearDown() {
        watcher?.cancel()
        watcher = nil
        quickLook?.close()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
    }

    // MARK: - Loading

    private func load(keepScroll: Bool = false) {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let existed = fileExists
        fileExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        updateHeader()
        watch()
        guard fileExists else {
            show(placeholder: isDirectory.boolValue ? String(localized: "\(fileName) is a folder") : String(localized: "File not found"),
                 detail: path.abbreviatingHome)
            if existed { onStateChange?() }
            return
        }
        if !existed { onStateChange?() }
        switch renderMode {
        case .markdown, .diff, .text:
            renderHTML(keepScroll: keepScroll)
        case .image:
            // In-process (unlike Quick Look's remote view): animated GIFs play, and snapshots/tests can see it.
            guard let image = NSImage(contentsOfFile: path), image.isValid else { return showQuickLook(url) }
            let view = imageView ?? makeImageView()
            if content !== view { setContent(view) }
            // High-DPI files report a small point size; show them at one point per pixel (scaled down to fit).
            if let rep = image.representations.first, rep.pixelsWide > Int(image.size.width) {
                image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            view.image = image
        case .quickLook:
            showQuickLook(url)
        }
    }

    private func showQuickLook(_ url: URL) {
        let view = quickLook ?? makeQuickLook()
        if content !== view { setContent(view) }
        // Assigning the same URL again does not refresh; go through nil.
        view.previewItem = nil
        view.previewItem = url as NSURL
    }

    private enum RenderMode { case markdown, diff, text, image, quickLook }

    private var renderMode: RenderMode {
        switch format {
        case .markdown: return .markdown
        case .diff: return .diff
        case .quickLook:
            // Quick Look shows only an icon for text without a known type (no extension, `.env`, `Makefile`…).
            let ext = (path as NSString).pathExtension
            if let type = UTType(filenameExtension: ext), !ext.isEmpty, type.isDeclared {
                return type.conforms(to: .image) && !type.conforms(to: .pdf) ? .image : .quickLook
            }
            return Self.looksLikeText(path) ? .text : .quickLook
        }
    }

    private func renderHTML(keepScroll: Bool) {
        let mode = renderMode
        let view = webView ?? makeWebView()
        if content !== view { setContent(view) }
        let title = fileName
        let source = Self.readText(path)
        let html: String
        switch mode {
        case .markdown: html = MarkdownHTML.page(source.text, title: title)
        case .diff: html = DiffHTML.page(source.text, title: title)
        default:
            html = PreviewHTML.page(title: title, bodyClass: "markdown",
                                    body: "<pre><code>" + PreviewHTML.escape(source.text) + "</code></pre>")
        }
        let notice = source.truncated
            ? "<p style=\"padding:8px 16px;color:var(--muted)\">\(String(localized: "Showing the first \(PreviewFormat.maxRenderedBytes / 1024 / 1024) MB."))</p>"
            : ""
        let page = notice.isEmpty ? html : html.replacingOccurrences(of: "</body>", with: notice + "</body>")
        let base = PreviewSchemeHandler.baseURL(forDocumentAt: path)
        guard keepScroll else {
            view.loadHTMLString(page, baseURL: base)
            return
        }
        view.evaluateJavaScript("window.scrollY") { [weak self, weak view] value, _ in
            MainActor.assumeIsolated {
                guard let self, let view, view === self.webView else { return }
                self.pendingScroll = value as? Double
                view.loadHTMLString(page, baseURL: base)
            }
        }
    }

    fileprivate var pendingScroll: Double?

    fileprivate func restoreScroll() {
        guard let y = pendingScroll, y > 0 else { return }
        pendingScroll = nil
        webView?.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    private static func readText(_ path: String) -> (text: String, truncated: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: PreviewFormat.maxRenderedBytes + 1)) ?? Data()
        let truncated = data.count > PreviewFormat.maxRenderedBytes
        let bytes = truncated ? data.prefix(PreviewFormat.maxRenderedBytes) : data
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }

    private static func looksLikeText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return false }
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        // A multi-byte character may be cut at the end of the sample.
        for cut in 0...3 where data.count > cut {
            if String(data: data.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    // MARK: - Content views

    private func makeQuickLook() -> QLPreviewView {
        let view = QLPreviewView(frame: bounds, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = true
        quickLook = view
        return view
    }

    private func makeImageView() -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.isEditable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView = view
        return view
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        let view = WKWebView(frame: bounds, configuration: configuration)
        view.allowsMagnification = true
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func show(placeholder title: String, detail: String) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        let symbol = NSImageView(image: NSImage(systemSymbolName: "doc.questionmark", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 32, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        [symbol, label, detailLabel].forEach(stack.addArrangedSubview)
        let holder = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, constant: -24),
        ])
        setContent(holder)
    }

    private func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    // MARK: - Watching

    private func watch() {
        if watcher?.path == path { watcher?.rearm(); return }
        watcher?.cancel()
        watcher = FileWatcher(path: path) { [weak self] in self?.scheduleReload() }
    }

    /// Coalesces bursts of writes (editors, `>` redirections) into one reload.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.load(keepScroll: true)
            }
        }
    }

    // MARK: - Header

    private static func headerButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func buildLayout() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        pathButton.isBordered = false
        pathButton.font = .systemFont(ofSize: 11)
        pathButton.contentTintColor = .secondaryLabelColor
        pathButton.lineBreakMode = .byTruncatingHead
        pathButton.alignment = .left
        pathButton.toolTip = String(localized: "Reveal in Finder")
        pathButton.target = self
        pathButton.action = #selector(revealInFinder)
        pathButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openButton.target = self
        openButton.action = #selector(openInDefaultApp)
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)

        let header = NSStackView(views: [iconView, nameLabel, pathButton, openButton, reloadButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        header.setCustomSpacing(10, after: nameLabel)
        header.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(separator)
        addSubview(contentHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateHeader() {
        nameLabel.stringValue = fileName
        let directory = (path as NSString).deletingLastPathComponent.abbreviatingHome
        pathButton.title = directory
        pathButton.toolTip = String(localized: "Reveal in Finder — \(path)")
        iconView.image = NSWorkspace.shared.icon(forFile: path)
        openButton.isEnabled = fileExists
        pathButton.isEnabled = true
    }

    @objc private func revealInFinder() {
        if fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            // The folder may still exist.
            let directory = (path as NSString).deletingLastPathComponent
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
        }
    }

    @objc private func openInDefaultApp() {
        guard fileExists else { return NSSound.beep() }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func reloadClicked() { reload() }
}

// MARK: - Links

extension PreviewPane: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case PreviewSchemeHandler.scheme, "file":
            let target = url.scheme == "file" ? url.path : PreviewSchemeHandler.filePath(for: url)
            guard let target else { return }
            // `#anchor` resolves against the base URL, which is the document's folder.
            var withoutFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)
            withoutFragment?.fragment = nil
            let sameDocument = target == path
                || withoutFragment?.url?.absoluteString == PreviewSchemeHandler.baseURL(forDocumentAt: path)?.absoluteString
            if let fragment = url.fragment, sameDocument {
                webView.evaluateJavaScript("document.getElementById(\(Self.jsString(fragment)))?.scrollIntoView()")
                return
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else { return NSSound.beep() }
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            } else {
                open(path: target)
            }
        default:
            NSSound.beep()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restoreScroll()
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Local images in Markdown

/// Serves files next to a rendered Markdown document (`![](img/a.png)`) under `cmds-preview://doc/<dir>/…`.
/// Only images and media inside the document's folder (after resolving `..` and symlinks) are served.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmds-preview"

    static func baseURL(forDocumentAt path: String) -> URL? {
        let directory = (path as NSString).deletingLastPathComponent
        var components = URLComponents()
        components.scheme = scheme
        components.host = "doc"
        components.path = directory.hasSuffix("/") ? directory : directory + "/"
        return components.url
    }

    static func filePath(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == "doc" else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        return (path as NSString).standardizingPath
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let path = Self.filePath(for: url),
              let documentURL = webView.url, let documentPath = Self.filePath(for: documentURL) else {
            return task.didFailWithError(URLError(.badURL))
        }
        // The page's base URL is the document's folder; serve only what is inside it.
        let root = URL(fileURLWithPath: documentPath).resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let type = UTType(filenameExtension: (file as NSString).pathExtension)
        guard file.hasPrefix(rootPrefix), let type, type.conforms(to: .image) || type.conforms(to: .audiovisualContent),
              let data = FileManager.default.contents(atPath: file), data.count <= 50 * 1024 * 1024 else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let response = URLResponse(url: url, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - File watching

/// Watches one path with a vnode DispatchSource. Writes call `onChange`; when the file is deleted or renamed
/// (atomic save) the watch moves to whatever is at the path again, polling once a second while nothing is there.
@MainActor
final class FileWatcher {
    let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var cancelled = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        start()
    }

    /// Re-attaches if the watched inode went away (e.g. after a manual reload).
    func rearm() {
        if source == nil { start() }
    }

    func cancel() {
        cancelled = true
        retry?.cancel()
        source?.cancel()
        source = nil
    }

    private func start() {
        guard !cancelled else { return }
        retry?.cancel()
        retry = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry(after: 1)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handle() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func handle() {
        guard let source else { return }
        let events = source.data
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // Atomic save: the old inode is gone or moved away; the new file usually exists already.
            source.cancel()
            self.source = nil
            onChange()
            scheduleRetry(after: 0.05)
            return
        }
        onChange()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard !cancelled else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled, self.source == nil else { return }
                let existed = FileManager.default.fileExists(atPath: self.path)
                self.start()
                if existed, delay >= 1 { self.onChange() } // the file (re)appeared while polling
            }
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
