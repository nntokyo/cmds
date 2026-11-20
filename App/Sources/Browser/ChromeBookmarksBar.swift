import AppKit
import CmdsCore

/// Google Chrome's bookmarks for the bookmarks bar of browser panes (Settings › General): read from Chrome's profile
/// folder (`ChromeBookmarks`) off the main thread, again when cmds becomes active or the setting changes, and only when
/// the file changed. Read only.
@MainActor
final class ChromeBookmarkStore {
    static let shared = ChromeBookmarkStore()
    static let didChange = Notification.Name("ChromeBookmarksDidChange")

    /// The bookmarks shown; nil when off, when Chrome or its bookmarks are missing, or before the first read.
    private(set) var tree: ChromeBookmarks.Tree?

    /// Chrome's folder; `CMDS_CHROME_FOLDER` replaces it for tests (docs/internals/testing.md).
    nonisolated static var chromeFolder: URL {
        if let override = ProcessInfo.processInfo.environment["CMDS_CHROME_FOLDER"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ChromeBookmarks.defaultChromeFolder()
    }

    /// Why there are no bookmarks to show (Settings tells the user).
    enum Problem: Equatable {
        /// No `Bookmarks` file for the profile (Chrome not installed, or no bookmarks yet).
        case notFound
        /// macOS refused to read Chrome's folder: cmds needs Full Disk Access (Privacy & Security).
        case noAccess
        /// The file is not Chrome's bookmarks format (or too large).
        case unreadable
        /// Chrome keeps this profile's bookmarks only encrypted (`EncryptedAccountBookmarks2` and the like), which other
        /// apps cannot read.
        case encrypted
    }

    /// The last read's problem; nil when it worked, while off or before the first read.
    private(set) var problem: Problem?
    private var loadedFile: URL?
    /// The bookmark files read and their dates (`AccountBookmarks@…,Bookmarks@…`).
    private var loadedSignature: String?
    private var reading = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ChromeBookmarkStore.shared.refresh() }
            },
            NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ChromeBookmarkStore.shared.refresh() }
            },
        ]
        refresh()
    }

    /// Reads the bookmarks again when the setting, the profile or a bookmark file (or its date) changed.
    func refresh() {
        guard AppSettings.shared.chromeBookmarks else {
            if tree != nil || loadedFile != nil || problem != nil {
                tree = nil
                problem = nil
                loadedFile = nil
                loadedSignature = nil
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
            return
        }
        guard !reading else { return }
        reading = true
        let profile = AppSettings.shared.chromeProfile
        let previousFile = loadedFile
        let previousSignature = loadedSignature
        Task.detached(priority: .utility) {
            // Every bookmark file of the profile (AccountBookmarks, Bookmarks); the dates of those found tell a change.
            let folder = ChromeBookmarks.profileFolder(profile: profile, chromeFolder: Self.chromeFolder)
            let files = ChromeBookmarks.fileNames.map { folder.appendingPathComponent($0) }
            var problem: Problem?
            var found: [(url: URL, date: Date?, size: Int)] = []
            for url in files {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    found.append((url, attributes[.modificationDate] as? Date, (attributes[.size] as? NSNumber)?.intValue ?? 0))
                } catch {
                    let kind = Self.problem(error)
                    if kind != .notFound { problem = kind }
                }
            }
            if found.isEmpty, problem == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                problem = names.contains { $0.hasPrefix("Encrypted") && $0.contains("Bookmarks") } ? .encrypted : .notFound
            }
            let file = folder
            let signature = found.map { "\($0.url.lastPathComponent)@\($0.date?.timeIntervalSince1970 ?? 0)" }.joined(separator: ",")
            let unchanged = problem == nil && file == previousFile && signature == previousSignature
            var read: ChromeBookmarks.Tree?
            if !unchanged, problem == nil {
                var trees: [ChromeBookmarks.Tree] = []
                for entry in found {
                    guard entry.size <= ChromeBookmarks.maxFileSize else { continue }
                    do {
                        if let tree = ChromeBookmarks.parse(try Data(contentsOf: entry.url)) { trees.append(tree) }
                    } catch {
                        let kind = Self.problem(error)
                        if kind == .noAccess { problem = .noAccess }
                    }
                }
                if problem == nil {
                    if trees.isEmpty { problem = .unreadable } else { read = ChromeBookmarks.merged(trees) }
                }
            }
            // macOS's protection of other apps' data reports the files inside as missing; listing the folder itself
            // is refused (EPERM).
            if problem == .notFound {
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: Self.chromeFolder.path)
                } catch {
                    if Self.problem(error) == .noAccess { problem = .noAccess }
                }
            }
            let tree: ChromeBookmarks.Tree?? = unchanged ? .none : .some(read)
            await MainActor.run {
                let store = ChromeBookmarkStore.shared
                store.reading = false
                // Turned off while reading.
                guard AppSettings.shared.chromeBookmarks, AppSettings.shared.chromeProfile == profile else {
                    store.refresh()
                    return
                }
                guard case .some(let read) = tree else { return }
                // A file that could not be read is tried again next time.
                store.loadedFile = problem == nil ? file : nil
                store.loadedSignature = problem == nil ? signature : nil
                if read != store.tree || problem != store.problem {
                    store.tree = read
                    store.problem = problem
                    NotificationCenter.default.post(name: Self.didChange, object: store)
                }
            }
        }
    }

    /// Not found, or refused by macOS (privacy protection of other apps' data: EPERM / EACCES).
    nonisolated private static func problem(_ error: Error) -> Problem {
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if posix == Int(EPERM) || posix == Int(EACCES) || nsError.code == NSFileReadNoPermissionError { return .noAccess }
        if posix == Int(ENOENT) || nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return .notFound
        }
        return .unreadable
    }

    /// Chrome's profiles for Settings (empty without Chrome) and the one it used last.
    nonisolated static func profiles() -> (profiles: [ChromeBookmarks.Profile], lastUsed: String?) {
        let localState = chromeFolder.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState) else { return ([], nil) }
        return ChromeBookmarks.profiles(localState: data)
    }
}

/// The row of Chrome bookmarks under a browser pane's toolbar: links load in the pane (⌘-click: a new tab), folders
/// open a menu; what does not fit goes into the » menu at the end, Other and Mobile bookmarks into the menu at the
/// right. Hidden when the setting is off or there is nothing to show.
@MainActor
final class ChromeBookmarksBarView: NSView {
    static let height: CGFloat = 24

    /// Load `url` in the pane, or in a new tab when `newTab`.
    var onOpen: ((URL, _ newTab: Bool) -> Void)?
    /// The bar appeared or disappeared (the pane lays out again).
    var onVisibilityChange: (() -> Void)?

    private var buttons: [NSButton] = []
    private var items: [ChromeBookmarks.Item] = []
    private let overflowButton = BrowserPane.toolbarButton("chevron.right.2", label: String(localized: "More Bookmarks"))
    private let otherButton = NSButton(title: "", target: nil, action: nil)
    private var otherItems: [ChromeBookmarks.Item] = []
    /// Removed in deinit (the bar of every closed browser pane would stay registered otherwise).
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    nonisolated(unsafe) private var iconObserver: NSObjectProtocol?
    /// The bookmarks changed while the pane was off screen (a hidden tab or workspace): reloaded when it comes back.
    private var reloadPending = false
    /// Buttons are made for this many bar items at most; the rest are only in the » menu.
    private static let maxButtons = 60
    /// Open All in Tabs asks first above this many links.
    private static let openAllConfirmCount = 20
    /// How many bar items fit (the rest are in the » menu).
    private var shownCount = 0

    var hasContent: Bool { !items.isEmpty || !otherItems.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked(_:))
        configure(otherButton, title: String(localized: "Other Bookmarks", comment: "Chrome bookmarks bar: the menu of Other and Mobile bookmarks"),
                  symbol: "folder")
        otherButton.action = #selector(otherClicked(_:))
        addSubview(overflowButton)
        addSubview(otherButton)
        observer = NotificationCenter.default.addObserver(forName: ChromeBookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window == nil { self.reloadPending = true } else { self.reload() }
            }
        }
        iconObserver = NotificationCenter.default.addObserver(forName: FaviconCache.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window != nil { self?.updateIcons() } }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) }
    }

    /// The icon of a site visited in a browser pane (`FaviconCache`), 12 pt.
    static func icon(for url: URL) -> NSImage? {
        guard let host = url.host, let image = FaviconCache.shared.image(forHost: host)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 12, height: 12)
        return image
    }

    /// Icons learned since the buttons were made.
    private func updateIcons() {
        for (index, button) in buttons.enumerated() {
            guard case .link(_, let url) = items[index], let icon = Self.icon(for: url) else { continue }
            button.image = icon
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, reloadPending { reload() }
    }

    override var isFlipped: Bool { true }

    func reload() {
        reloadPending = false
        let wasShown = hasContent
        let tree = ChromeBookmarkStore.shared.tree
        items = tree?.bar ?? []
        var other = tree?.other ?? []
        if let mobile = tree?.mobile, !mobile.isEmpty {
            other.append(.folder(title: String(localized: "Mobile Bookmarks", comment: "Chrome's Mobile bookmarks folder"), items: mobile))
        }
        otherItems = other
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.prefix(Self.maxButtons).enumerated().map { index, item in
            let button = NSButton(title: "", target: self, action: #selector(itemClicked(_:)))
            switch item {
            case .link(let title, let url):
                configure(button, title: title, symbol: "globe")
                button.toolTip = "\(title)\n\(url.absoluteString)"
                if let icon = Self.icon(for: url) { button.image = icon }
            case .folder(let title, _):
                configure(button, title: title, symbol: "folder")
            }
            button.tag = index
            addSubview(button)
            return button
        }
        otherButton.isHidden = otherItems.isEmpty
        needsLayout = true
        if wasShown != hasContent { onVisibilityChange?() }
    }

    private func configure(_ button: NSButton, title: String, symbol: String) {
        button.title = title.count > 40 ? String(title.prefix(39)) + "…" : title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.lineBreakMode = .byTruncatingTail
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let spacing: CGFloat = 2
        let height = bounds.height
        var right = bounds.width - inset
        if !otherButton.isHidden {
            let width = min(otherButton.intrinsicContentSize.width, 160)
            otherButton.frame = NSRect(x: right - width, y: (height - 20) / 2, width: width, height: 20)
            right -= width + spacing * 4
        }
        let overflowWidth: CGFloat = 22
        var x = inset
        shownCount = 0
        for (index, button) in buttons.enumerated() {
            let width = min(button.intrinsicContentSize.width, 180)
            let remainingAfter = index < items.count - 1 ? overflowWidth + spacing : 0
            if x + width + remainingAfter > right {
                break
            }
            button.frame = NSRect(x: x, y: (height - 20) / 2, width: width, height: 20)
            button.isHidden = false
            x += width + spacing
            shownCount += 1
        }
        for button in buttons[shownCount...] { button.isHidden = true }
        overflowButton.isHidden = shownCount >= items.count
        overflowButton.frame = NSRect(x: x, y: (height - 20) / 2, width: overflowWidth, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Actions

    private var opensInNewTab: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

    @objc private func itemClicked(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        switch items[sender.tag] {
        case .link(_, let url):
            onOpen?(url, opensInNewTab)
        case .folder(let title, let children):
            popUp(menu(title: title, items: children), below: sender)
        }
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        popUp(menu(title: "", items: Array(items[min(shownCount, items.count)...])), below: sender)
    }

    @objc private func otherClicked(_ sender: NSButton) {
        popUp(menu(title: "", items: otherItems), below: sender)
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpen?(url, opensInNewTab)
    }

    @objc private func openAllInTabs(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        if urls.count > Self.openAllConfirmCount {
            let alert = NSAlert()
            alert.messageText = String(localized: "Open \(urls.count) tabs?", comment: "Chrome bookmarks: Open All in Tabs of a large folder")
            alert.addButton(withTitle: String(localized: "Open", comment: "Chrome bookmarks: Open All in Tabs of a large folder"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Each new tab goes right after the pane's own: opened last to first, they end up in the folder's order.
        for url in urls.reversed() { onOpen?(url, true) }
    }

    private func popUp(_ menu: NSMenu, below button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    /// A folder's menu: links (⌘ opens a new tab), sub-folders as submenus, and Open All in Tabs.
    private func menu(title: String, items: [ChromeBookmarks.Item]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .link(let title, let url):
                let entry = NSMenuItem(title: title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                entry.toolTip = url.absoluteString
                if let icon = Self.icon(for: url) { entry.image = icon }
                entry.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                menu.addItem(entry)
            case .folder(let title, let children):
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                entry.submenu = self.menu(title: title, items: children)
                entry.isEnabled = !children.isEmpty
                menu.addItem(entry)
            }
        }
        let links = items.compactMap { item -> URL? in
            if case .link(_, let url) = item { return url }
            return nil
        }
        if links.count > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem(title: String(localized: "Open All in Tabs", comment: "Chrome bookmarks folder menu"),
                                 action: #selector(openAllInTabs(_:)), keyEquivalent: "")
            all.target = self
            all.representedObject = links
            menu.addItem(all)
        }
        if items.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Empty", comment: "An empty Chrome bookmarks folder"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }
}
