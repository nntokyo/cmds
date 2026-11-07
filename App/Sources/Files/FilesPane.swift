import AppKit
import CmdsCore

/// Files pane (docs/guide/files.md): a folder on this Mac or on an SSH host (`host`, FilesPane+Remote.swift) as a list (name, Git state, size, date modified, kind) under a
/// bar with back / forward / up, the path, and the hidden-files, follow-terminal and terminal-here toggles. Two of them
/// side by side (an ordinary split) copy and move between each other. Listing and Git state are read off the main
/// thread; the folder is watched and listed again when it changes, and the repository's git directory is watched for
/// the Git column. Table, drag and drop: FilesPane+Table.swift; file
/// operations and commands: FilesPane+Actions.swift.
@MainActor
final class FilesPane: NSView {
    /// Folder, title or a setting that is saved changed.
    var onStateChange: (() -> Void)?
    /// The list took the keyboard.
    var onFocus: (() -> Void)?
    /// Follow terminal was switched on (the pane then goes to the workspace's directory).
    var onFollowEnabled: (() -> Void)?
    /// The other files pane of the workspace: where Copy / Move to Other Pane go.
    var otherPane: (() -> FilesPane?)?
    /// Show a file in the workspace's preview pane.
    var onPreview: ((String) -> Void)?
    /// Open a terminal pane in a folder.
    var onOpenTerminal: ((String) -> Void)?
    /// Open an SSH terminal pane in a folder of `host` (remote panes).
    var onOpenSSHTerminal: ((_ host: String, _ folder: String) -> Void)?

    /// nil: a folder on this Mac. Else the SSH host (as for `cmds new --ssh`) whose folder this pane lists over SFTP.
    let host: String?
    /// Absolute. A remote pane may start with `~/…`, a path relative to the home folder or "" (home) until the server
    /// has resolved it.
    private(set) var folder: String
    private(set) var showHidden = false
    private(set) var followsTerminal = false
    var sortKey: FileSortKey = .name
    var ascending = true

    var backStack: [String] = []
    var forwardStack: [String] = []
    /// Everything in the folder (hidden included) and the rows shown, sorted.
    var allEntries: [FileEntry] = []
    var rows: [FileEntry] = []
    /// Git state per name; nil outside a repository (the Git column is then hidden).
    var gitStates: [String: GitFileState]?
    /// The folder could not be read (shown in the status line).
    var loadError: String?
    /// Names to select once the next listing arrives, and one of them to rename (New Folder).
    var pendingSelection: [String]?
    var pendingRename: String?
    /// The copy or move this pane started (progress in its footer).
    var operation: FileOperation?
    /// Remote panes restored from the session wait for Connect (⌘R) instead of connecting at launch.
    var waitingForConnect = false
    /// Remote: the last listing failed because the connection could not be made (the footer offers Connect).
    var connectionError: String?
    /// Remote: a download for Open / Preview, a rename… is running (status line).
    var remoteActivity: String?
    /// Transfer jobs this pane started (the footer shows the one running).
    var startedTransfers = Set<Int>()
    var transferObservers: [NSObjectProtocol] = []
    #if DEBUG
    /// Tests: the answer to name conflicts instead of asking (`debug.files`).
    var debugConflictAnswer: FileOperation.Resolution?
    #endif

    private var watcher: FileWatcher?
    /// The repository's git directory while the folder is in one (`watchGitDirectory`).
    private var gitWatcher: FileWatcher?
    private var keyObserver: NSObjectProtocol?
    private var generation = 0
    private var gitGeneration = 0
    private var reloadScheduled = false
    private var gitReloadScheduled = false

    // Header
    let backButton = FilesPane.barButton("chevron.left", label: String(localized: "Back"))
    let forwardButton = FilesPane.barButton("chevron.right", label: String(localized: "Forward"))
    let upButton = FilesPane.barButton("chevron.up", label: String(localized: "Enclosing Folder"))
    let pathControl = NSPathControl()
    let hiddenButton = FilesPane.barButton("eye", label: String(localized: "Show Hidden Files"))
    let followButton = FilesPane.barButton("link", label: String(localized: "Follow Terminal"))
    let terminalButton = FilesPane.barButton("terminal", label: String(localized: "Open Terminal Here"))
    /// Remote panes show `host:/path` here instead of the path control.
    let remotePathLabel = NSTextField(labelWithString: "")
    // List
    let tableView = FilesTableView()
    let scrollView = NSScrollView()
    // Footer
    let statusLabel = NSTextField(labelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    let connectButton = NSButton(title: String(localized: "Connect"), target: nil, action: nil)
    /// Over the empty list of a remote pane: why it could not be listed, in full (the status line is one line).
    let messageLabel = NSTextField(wrappingLabelWithString: "")

    lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// `host` nil: `folder` on this Mac. Else a folder on that host; `connect` false waits for Connect (⌘R).
    init(folder: String, host: String? = nil, connect: Bool = true) {
        self.host = host
        self.folder = host == nil ? (folder as NSString).standardizingPath : Self.remoteFolder(folder)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        buildLayout()
        configureTable()
        updateHeader()
        startWatching()
        observeTransfers()
        if host != nil, !connect {
            waitingForConnect = true
            updateStatus()
        } else {
            load()
        }
    }

    var isRemote: Bool { host != nil }

    /// Where the shown folder is (this Mac or `host:folder`).
    var location: FileLocation { host.map { .remote(host: $0, path: folder) } ?? .local(folder) }

    func location(of entry: FileEntry) -> FileLocation { location.appending(entry.name) }

    nonisolated static func remoteFolder(_ path: String) -> String {
        path.hasPrefix("/") ? RemotePath.normalized(path) : path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The pane's title: the folder's name (`/` for the root); `host:name` for remote panes.
    var title: String {
        if let host { return folder.isEmpty ? host : "\(host):\(RemotePath.name(folder))" }
        return folder == "/" ? "/" : FileManager.default.displayName(atPath: folder)
    }

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }

    func url(of entry: FileEntry) -> URL {
        folderURL.appendingPathComponent(entry.name, isDirectory: entry.isFolder)
    }

    func focus() {
        window?.makeFirstResponder(tableView)
    }

    func tearDown() {
        watcher?.cancel()
        watcher = nil
        gitWatcher?.cancel()
        gitWatcher = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        transferObservers.forEach(NotificationCenter.default.removeObserver)
        transferObservers = []
        operation?.cancel()
        RemoteEdits.shared.paneClosed(self)
        generation += 1
        gitGeneration += 1
    }

    // MARK: - Navigation

    /// Shows another folder. A path that is not a folder is refused (false). `record` adds the current folder to Back.
    @discardableResult
    func navigate(to path: String, record: Bool = true, select names: [String]? = nil) -> Bool {
        let target = isRemote ? Self.remoteFolder(path) : (path as NSString).standardizingPath
        // Remote folders are checked by the listing (off the main thread); a file there selects it in its folder.
        guard isRemote || Self.isFolder(target) else { return false }
        if target == folder {
            if let names {
                // The listing may still be on its way: select once it is (re)read.
                pendingSelection = names
                load()
            }
            return true
        }
        if record {
            backStack.append(folder)
            forwardStack.removeAll()
        }
        let previous = folder
        folder = target
        // Going up selects the folder we came from.
        if let names {
            pendingSelection = names
        } else if isRemote, previous.hasPrefix("/"), RemotePath.parent(previous) == target {
            pendingSelection = [RemotePath.name(previous)]
        } else if !isRemote, (previous as NSString).deletingLastPathComponent == target {
            pendingSelection = [(previous as NSString).lastPathComponent]
        } else {
            pendingSelection = []
        }
        allEntries = []
        rows = []
        gitStates = nil
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
        startWatching()
        load()
        updateHeader()
        onStateChange?()
        return true
    }

    @objc func goBack() {
        guard let previous = backStack.popLast() else { return NSSound.beep() }
        let current = folder
        if navigate(to: previous, record: false) {
            forwardStack.append(current)
        } else {
            goBack() // gone meanwhile: try the one before
        }
        updateHeader()
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { return NSSound.beep() }
        let current = folder
        if navigate(to: next, record: false) { backStack.append(current) }
        updateHeader()
    }

    /// Not at `/`, and (remote) the server has resolved the folder (a `~/…` path has no known parent yet).
    var canGoUp: Bool { folder != "/" && !(isRemote && !folder.hasPrefix("/")) }

    @objc func goUp() {
        guard canGoUp else { return NSSound.beep() }
        navigate(to: isRemote ? RemotePath.parent(folder) : (folder as NSString).deletingLastPathComponent)
    }

    /// Follow terminal: the workspace's terminal changed directory.
    func follow(_ path: String) {
        guard followsTerminal, !isRemote, path != folder else { return }
        navigate(to: path)
    }

    func setFollowsTerminal(_ on: Bool) {
        guard on != followsTerminal else { return }
        followsTerminal = on
        updateHeader()
        onStateChange?()
        if on { onFollowEnabled?() }
    }

    func setShowHidden(_ on: Bool) {
        guard on != showHidden else { return }
        showHidden = on
        updateHeader()
        applyRows(keepSelection: true)
        onStateChange?()
    }

    /// Restores the settings saved with the session.
    func restore(showHidden: Bool, followsTerminal: Bool) {
        self.showHidden = showHidden
        self.followsTerminal = followsTerminal
        updateHeader()
        applyRows(keepSelection: true)
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Loading

    /// Lists the folder again (⌘R; also when it changes on disk). A remote pane waiting for Connect connects.
    @objc func reload() {
        waitingForConnect = false
        load()
    }

    func load() {
        if isRemote {
            guard !waitingForConnect else { return updateStatus() }
            return loadRemote()
        }
        generation += 1
        let token = generation
        let path = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.read(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.apply(result)
                }
            }
        }
        loadGitStatus()
    }

    func apply(_ result: Result<[FileEntry], Error>) {
        switch result {
        case .success(let entries):
            loadError = nil
            allEntries = entries
        case .failure(let error):
            if !isRemote, !Self.isFolder(folder) {
                // Deleted or moved away: go to the nearest folder that is still there.
                navigate(to: FileNames.nearestFolder(above: folder, isFolder: Self.isFolder), record: false)
                return
            }
            loadError = error.localizedDescription
            allEntries = []
        }
        applyRows(keepSelection: pendingSelection == nil)
    }

    /// Sorts and filters `allEntries` into `rows` and reloads the table, keeping the selection by name.
    func applyRows(keepSelection: Bool) {
        let selected = keepSelection ? selectedEntries.map(\.name) : []
        rows = FileSorting.sorted(FileSorting.visible(allEntries, showHidden: showHidden), by: sortKey, ascending: ascending)
        tableView.reloadData()
        if let names = pendingSelection {
            pendingSelection = nil
            selectNames(names)
        } else {
            selectNames(selected, scroll: false)
        }
        if let rename = pendingRename, let row = rows.firstIndex(where: { $0.name == rename }) {
            pendingRename = nil
            beginRename(row: row)
        }
        updateStatus()
    }

    func selectNames(_ names: [String], scroll: Bool = true) {
        let wanted = Set(names)
        let indexes = IndexSet(rows.indices.filter { wanted.contains(rows[$0].name) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    var selectedEntries: [FileEntry] {
        tableView.selectedRowIndexes.compactMap { rows[safe: $0] }
    }

    /// The rows a command applies to: the right-clicked row (unless it is part of the selection), else the selection.
    var targetEntries: [FileEntry] {
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked), let entry = rows[safe: clicked] { return [entry] }
        return selectedEntries
    }

    nonisolated private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .localizedTypeDescriptionKey,
    ]

    nonisolated static func read(_ path: String) -> Result<[FileEntry], Error> {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [])
            return .success(items.map(entry))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func entry(_ url: URL) -> FileEntry {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        var isFolder = values?.isDirectory == true && values?.isPackage != true
        if values?.isSymbolicLink == true {
            // A link to a folder opens like a folder.
            let resolved = url.resolvingSymlinksInPath()
            let target = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            isFolder = target?.isDirectory == true && target?.isPackage != true
        }
        let name = url.lastPathComponent
        return FileEntry(name: name, isFolder: isFolder, isHidden: name.hasPrefix(".") || values?.isHidden == true,
                         size: isFolder ? nil : Int64(values?.fileSize ?? 0),
                         modified: values?.contentModificationDate, kind: values?.localizedTypeDescription ?? "")
    }

    /// Invalidates listings on their way (a remote listing that comes back after a navigation is dropped).
    func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool { token == generation }

    /// A remote listing resolved the folder (`~/x` → `/home/me/x`), or found a file: shown without a Back entry.
    func setResolvedFolder(_ resolved: String) {
        guard resolved != folder else { return }
        folder = resolved
        updateHeader()
        onStateChange?()
    }

    private func startWatching() {
        guard !isRemote else { return }
        watcher?.cancel()
        watcher = FileWatcher(path: folder) { [weak self] in self?.scheduleReload() }
    }

    /// Changes come in bursts (a copy writes many entries): list again at most every half second.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.watcher?.rearm()
                self.load()
            }
        }
    }

    // MARK: - Git

    private func loadGitStatus() {
        guard !isRemote else { return }
        gitGeneration += 1
        let token = gitGeneration
        let path = folder
        DispatchQueue.global(qos: .utility).async {
            let result = GitStatusReader.read(folder: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, token == self.gitGeneration, path == self.folder else { return }
                    self.watchGitDirectory(result?.gitDirectory)
                    let states = result?.states
                    guard states != self.gitStates else { return }
                    self.gitStates = states
                    self.updateGitColumn()
                }
            }
        }
    }

    /// Git state changes without the shown folder changing (a commit, staging, a checkout, #43): git then replaces
    /// `index` or `HEAD` in the repository's git directory, which is watched while the folder is in a repository.
    /// Edits to tracked files are seen when the folder changes or the window becomes key again (`windowDidBecomeKey`).
    private func watchGitDirectory(_ directory: String?) {
        guard directory != gitWatcher?.path else { return }
        gitWatcher?.cancel()
        gitWatcher = directory.map { FileWatcher(path: $0) { [weak self] in self?.scheduleGitReload() } }
    }

    /// Like `scheduleReload`, for the Git column only.
    private func scheduleGitReload() {
        guard !gitReloadScheduled else { return }
        gitReloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gitReloadScheduled = false
                guard self.gitWatcher != nil else { return } // closed, or out of the repository meanwhile
                self.gitWatcher?.rearm()
                self.loadGitStatus()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidBecomeKey() }
            }
        }
    }

    /// Back in the window (perhaps after editing files elsewhere): read the Git state again, off the main thread.
    private func windowDidBecomeKey() {
        guard gitStates != nil, !isHiddenOrHasHiddenAncestor else { return }
        loadGitStatus()
    }

    // MARK: - Header and footer

    private static func barButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func buildLayout() {
        for (button, action) in [(backButton, #selector(goBack)), (forwardButton, #selector(goForward)),
                                 (upButton, #selector(goUp)), (hiddenButton, #selector(toggleHiddenFiles)),
                                 (followButton, #selector(toggleFollowTerminal)),
                                 (terminalButton, #selector(openTerminalHere))] {
            button.target = self
            button.action = action
        }
        hiddenButton.setButtonType(.toggle)
        followButton.setButtonType(.toggle)
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: 11)
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.setAccessibilityIdentifier("files.path")

        remotePathLabel.font = .systemFont(ofSize: 11)
        remotePathLabel.lineBreakMode = .byTruncatingHead
        remotePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remotePathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remotePathLabel.setAccessibilityIdentifier("files.remotePath")
        let header = NSStackView(views: [backButton, forwardButton, upButton, pathControl, remotePathLabel, hiddenButton,
                                         followButton, terminalButton])
        header.orientation = .horizontal
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        header.setCustomSpacing(8, after: upButton)
        header.setCustomSpacing(8, after: pathControl)
        header.setCustomSpacing(8, after: remotePathLabel)
        header.translatesAutoresizingMaskIntoConstraints = false
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("files.status")
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        cancelButton.bezelStyle = .accessoryBarAction
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 11)
        cancelButton.target = self
        cancelButton.action = #selector(cancelFileOperation(_:))
        cancelButton.isHidden = true
        connectButton.bezelStyle = .accessoryBarAction
        connectButton.controlSize = .small
        connectButton.font = .systemFont(ofSize: 11)
        connectButton.target = self
        connectButton.action = #selector(reload)
        connectButton.isHidden = true
        connectButton.setAccessibilityIdentifier("files.connect")
        let footer = NSStackView(views: [statusLabel, progressIndicator, cancelButton, connectButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setAccessibilityIdentifier("files.message")
        for view in [header, topSeparator, scrollView, messageLabel, bottomSeparator, footer] { addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 22),
            progressIndicator.widthAnchor.constraint(equalToConstant: 120),
            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),
        ])
    }

    func updateHeader() {
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        upButton.isEnabled = canGoUp
        pathControl.isHidden = isRemote
        remotePathLabel.isHidden = !isRemote
        followButton.isHidden = isRemote
        if let host {
            remotePathLabel.stringValue = "\(host):\(folder)"
            remotePathLabel.toolTip = remotePathLabel.stringValue
            terminalButton.toolTip = String(localized: "Open SSH Terminal Here")
        } else {
            pathControl.url = folderURL
        }
        hiddenButton.state = showHidden ? .on : .off
        hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye.fill" : "eye",
                                     accessibilityDescription: String(localized: "Show Hidden Files"))
        hiddenButton.contentTintColor = showHidden ? .controlAccentColor : nil
        followButton.state = followsTerminal ? .on : .off
        followButton.contentTintColor = followsTerminal ? .controlAccentColor : nil
        followButton.toolTip = followsTerminal
            ? String(localized: "Following the terminal's directory (click to stop)")
            : String(localized: "Follow Terminal")
    }

    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        navigate(to: url.path)
        focus()
    }

    @objc func toggleHiddenFiles() { setShowHidden(!showHidden) }
    @objc func toggleFollowTerminal() { setFollowsTerminal(!followsTerminal) }

    func updateStatus() {
        guard operation == nil else { return }
        if showActiveTransfer() { return }
        connectButton.isHidden = !(isRemote && (waitingForConnect || connectionError != nil))
        let message = !isRemote || !rows.isEmpty ? nil
            : waitingForConnect ? String(localized: "Not connected. Click Connect or press ⌘R to list this folder.")
            : loadError
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        if waitingForConnect {
            statusLabel.stringValue = String(localized: "Not connected — Connect (⌘R)")
            return
        }
        if let remoteActivity {
            statusLabel.stringValue = remoteActivity
            return
        }
        if let loadError {
            statusLabel.stringValue = loadError
            return
        }
        let selected = tableView.selectedRowIndexes.count
        statusLabel.stringValue = (selected > 0
            ? String(localized: "\(selected) of \(rows.count) selected")
            : String(localized: "\(rows.count) items")) + editingSuffix
    }

    override func mouseDown(with event: NSEvent) {
        focus()
        super.mouseDown(with: event)
    }
}
