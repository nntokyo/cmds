import AppKit
import WebKit
import CmdsCore

// Web development tools of browser panes (docs/guide/workspaces-and-panes.md "Developer tools"): the page source in a
// preview tab, the console drawer, and the SEO report. Scripts and checks in CmdsCore (WebDevTools.swift).
extension BrowserPane {
    /// `browser.source`: the HTML the server sent (or with `rendered` the DOM now), capped at `PageSource.maxBytes`.
    func pageSource(rendered: Bool, fetchAgain: Bool = false) async throws
        -> (url: String, source: String, rendered: Bool, truncated: Bool, status: Int?, notCached: Bool) {
        // A local page: the file itself (WebKit's fetch cannot read file: URLs).
        if !rendered, let url = webView.url, url.isFileURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let handle = FileHandle(forReadingAtPath: url.path) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: PageSource.maxBytes + 1)) ?? Data()
            let text = String(decoding: data.prefix(PageSource.maxBytes), as: UTF8.self)
            return (url.absoluteString, text, false, data.count > PageSource.maxBytes, nil, false)
        }
        let result = try await runPageScript(PageSource.script, ["rendered": rendered, "fetchAgain": fetchAgain,
                                                                 "maxBytes": PageSource.maxBytes])
        guard case .object(let object) = result, let source = object["source"]?.stringValue else {
            throw RPCError(code: 500, message: "the page gave no source")
        }
        let capped = PageSource.capped(source)
        return (object["url"]?.stringValue ?? currentURL?.absoluteString ?? "", capped.source,
                object["rendered"]?.boolValue ?? rendered, capped.truncated, object["status"]?.intValue,
                object["notCached"]?.boolValue ?? false)
    }

    /// `browser.seo`.
    func seoReport() async throws -> SEOReport {
        let result = try await runPageScript(SEOAudit.script, [:])
        guard let facts = try? result.decode(PageFacts.self) else { throw RPCError(code: 500, message: "the page gave no facts") }
        return SEOReport(facts: facts)
    }

    // MARK: - Console drawer

    var isConsoleOpen: Bool { consoleDrawer != nil }

    /// Shows or hides the console drawer at the bottom of the pane (View › Developer › Console, ⌥⌘C). With `focus`
    /// (the user asked) its JavaScript line takes the keyboard; the API never moves the keyboard (an agent showing the
    /// console must not turn what the user types into page scripts).
    func toggleConsole(focus: Bool = true) {
        if let drawer = consoleDrawer {
            let hadKeyboard = (window?.firstResponder as? NSView)?.isDescendant(of: drawer) == true
            drawer.removeFromSuperview()
            consoleDrawer = nil
            consoleDrawerHeight?.constant = 0
            if hadKeyboard { window?.makeFirstResponder(webView) }
        } else {
            let drawer = BrowserConsoleView(pane: self)
            consoleDrawer = drawer
            consoleHost.addSubview(drawer)
            drawer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                drawer.leadingAnchor.constraint(equalTo: consoleHost.leadingAnchor),
                drawer.trailingAnchor.constraint(equalTo: consoleHost.trailingAnchor),
                drawer.topAnchor.constraint(equalTo: consoleHost.topAnchor),
                drawer.bottomAnchor.constraint(equalTo: consoleHost.bottomAnchor),
            ])
            consoleDrawerHeight?.constant = BrowserConsoleView.clampedHeight(BrowserConsoleView.lastHeight, in: bounds.height)
            drawer.refresh()
            if focus { drawer.focusInput() }
        }
        updateDeveloperButton()
    }

    func updateDeveloperButton() {
        developerButton.contentTintColor = isConsoleOpen ? .controlAccentColor : nil
    }

    /// The toolbar's developer menu.
    @objc func developerButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            (String(localized: "View Page Source"), #selector(viewSourceChosen)),
            (isConsoleOpen ? String(localized: "Hide Console") : String(localized: "Show Console"), #selector(consoleChosen)),
            (String(localized: "SEO Report"), #selector(seoChosen)),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        popUpToolbarMenu(menu, below: sender)
    }

    @objc private func viewSourceChosen() { onDeveloperAction?(.source) }
    @objc private func consoleChosen() { toggleConsole() }

    @objc private func seoChosen() { onDeveloperAction?(.seo) }
}

/// What the developer menu asks the pane's owner to open beside the pane.
enum BrowserDeveloperAction {
    case source, seo
}

/// The console drawer of a browser pane: the page's console messages, uncaught errors and unhandled rejections
/// (the pane's `ConsoleBuffer`, the same as `cmds browser console`), a level filter, Clear, and a line that runs
/// JavaScript in the page (like `cmds browser eval`) and prints the result.
@MainActor
final class BrowserConsoleView: NSView, NSTextFieldDelegate {
    static let preferredHeight: CGFloat = 220
    /// The height the user dragged the drawer to (shared by every pane; this run only).
    static var lastHeight: CGFloat = preferredHeight
    static let minimumHeight: CGFloat = 90

    /// `height` within what the pane leaves for the page (at least 150 pt of page).
    static func clampedHeight(_ height: CGFloat, in paneHeight: CGFloat) -> CGFloat {
        max(minimumHeight, min(height, paneHeight - 150))
    }

    private weak var pane: BrowserPane?
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let input = NSTextField()
    private let levelPopup = NSPopUpButton()
    /// Lines of evaluated input and their results, by the console sequence number they follow.
    private var evaluations: [(afterSeq: Int, input: String, result: String, failed: Bool)] = []
    /// Counts every evaluation (the list is capped, so its count alone cannot tell a new one).
    private var evaluationCount = 0
    private var history: [String] = []
    private var historyIndex: Int?
    private var shownSignature = ""

    init(pane: BrowserPane) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor

        let title = NSTextField(labelWithString: String(localized: "Console"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        levelPopup.controlSize = .small
        levelPopup.font = .systemFont(ofSize: 11)
        for (name, level) in [(String(localized: "All Levels"), nil), (String(localized: "Warnings and Errors"), ConsoleEntry.Level.warn),
                              (String(localized: "Errors"), ConsoleEntry.Level.error)] as [(String, ConsoleEntry.Level?)] {
            levelPopup.addItem(withTitle: name)
            levelPopup.lastItem?.representedObject = level?.rawValue
        }
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)
        let clear = BrowserPane.toolbarButton("trash", label: String(localized: "Clear Console"))
        clear.target = self
        clear.action = #selector(clearClicked)
        let close = BrowserPane.toolbarButton("xmark", label: String(localized: "Hide Console"))
        close.target = self
        close.action = #selector(closeClicked)
        let header = NSStackView(views: [title, levelPopup, NSView(), clear, close])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let prompt = NSTextField(labelWithString: "›")
        prompt.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        prompt.textColor = .controlAccentColor
        input.placeholderString = String(localized: "JavaScript (Return runs it in the page)")
        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(run)
        let inputRow = NSStackView(views: [prompt, input])
        inputRow.orientation = .horizontal
        inputRow.spacing = 4
        inputRow.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

        let separator = ConsoleResizeHandle()
        separator.onDrag = { [weak self] delta in self?.resize(by: delta) }
        let stack = NSStackView(views: [separator, header, scrollView, inputRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [separator, header, scrollView, inputRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        setAccessibilityLabel(String(localized: "Console"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Dragging the top edge: up makes the drawer taller.
    private func resize(by delta: CGFloat) {
        guard let pane, let constraint = pane.consoleDrawerHeight else { return }
        let height = Self.clampedHeight(constraint.constant + delta, in: pane.bounds.height)
        constraint.constant = height
        Self.lastHeight = height
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    private var minimumLevel: ConsoleEntry.Level? {
        (levelPopup.selectedItem?.representedObject as? String).flatMap(ConsoleEntry.Level.init(rawValue:))
    }

    private var refreshScheduled = false

    /// Redraws soon (at most four times a second while a page logs constantly).
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Redraws when the buffer, the filter or the evaluations changed.
    func refresh() {
        guard let pane else { return }
        let entries = pane.consoleBuffer.entries(level: minimumLevel)
        let signature = "\(entries.last?.seq ?? 0)|\(entries.count)|\(evaluationCount)|\(pane.consoleBuffer.dropped)|\(minimumLevel?.rawValue ?? "")"
        guard signature != shownSignature else { return }
        shownSignature = signature
        let atBottom = scrollView.verticalScroller.map { $0.floatValue > 0.98 } ?? true
            || textView.bounds.height <= scrollView.contentSize.height
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func add(_ line: String, _ color: NSColor) {
            text.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        var pending = evaluations[...]
        func flushEvaluations(upTo seq: Int) {
            while let next = pending.first, next.afterSeq <= seq {
                add("› " + next.input, .secondaryLabelColor)
                add("← " + next.result, next.failed ? .systemRed : .labelColor)
                pending = pending.dropFirst()
            }
        }
        if pane.consoleBuffer.dropped > 0 {
            add(String(localized: "(\(pane.consoleBuffer.dropped) older messages dropped)"), .tertiaryLabelColor)
        }
        for entry in entries {
            flushEvaluations(upTo: entry.seq - 1)
            add(entry.line(), Self.color(entry.level))
        }
        flushEvaluations(upTo: .max)
        if text.length == 0 { add(String(localized: "No console messages."), .tertiaryLabelColor) }
        textView.textStorage?.setAttributedString(text)
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    private static func color(_ level: ConsoleEntry.Level) -> NSColor {
        switch level {
        case .error: .systemRed
        case .warn: .systemYellow
        case .debug: .tertiaryLabelColor
        case .log, .info: .labelColor
        }
    }

    @objc private func levelChanged() { refresh() }

    @objc private func clearClicked() {
        pane?.consoleBuffer.clear()
        evaluations.removeAll()
        shownSignature = ""
        refresh()
    }

    @objc private func closeClicked() { pane?.toggleConsole() }

    @objc private func run() {
        let script = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, let pane else { return }
        input.stringValue = ""
        if history.last != script { history.append(script) }
        historyIndex = nil
        let after = pane.consoleBuffer.entries().last?.seq ?? 0
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            let line: (String, Bool)
            do {
                let value = try await pane.evaluateJavaScript(script)
                line = (Self.describe(value), false)
            } catch {
                line = ((error as? RPCError)?.message ?? error.localizedDescription, true)
            }
            guard let self else { return }
            self.evaluations.append((after, script, line.0, line.1))
            self.evaluationCount += 1
            if self.evaluations.count > 200 { self.evaluations.removeFirst(self.evaluations.count - 200) }
            self.refresh()
            self.textView.scrollToEndOfDocument(nil)
        }
    }

    /// A result as JSON text (strings quoted, like a console), at most 4000 characters.
    private static func describe(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return text.count > 4000 ? String(text.prefix(4000)) + "…" : text
    }

    // ↑ / ↓ go through the lines run before.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !history.isEmpty else { return false }
        if selector == #selector(NSResponder.moveUp(_:)) {
            let index = max(0, (historyIndex ?? history.count) - 1)
            historyIndex = index
            input.stringValue = history[index]
            return true
        }
        if selector == #selector(NSResponder.moveDown(_:)), let current = historyIndex {
            let index = current + 1
            historyIndex = index < history.count ? index : nil
            input.stringValue = index < history.count ? history[index] : ""
            return true
        }
        return false
    }
}

/// The top edge of the console drawer: a line that resizes the drawer when dragged.
@MainActor
private final class ConsoleResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastY: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDown(with event: NSEvent) { lastY = event.locationInWindow.y }

    override func mouseDragged(with event: NSEvent) {
        guard let lastY else { return }
        // Window coordinates grow upwards: moving up makes the drawer taller.
        onDrag?(event.locationInWindow.y - lastY)
        self.lastY = event.locationInWindow.y
    }

    override func mouseUp(with event: NSEvent) { lastY = nil }
}
