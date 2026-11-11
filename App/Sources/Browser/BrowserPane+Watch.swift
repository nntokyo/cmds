import AppKit
import CoreServices
import CmdsCore

// Reload on file changes (#252; rules in CmdsCore/BrowserWatch.swift): FSEvents on the watched folder while the pane is
// in a window, debounced, and only for pages `BrowserWatch.reloads` (local ones unless remote pages were turned on).
extension BrowserPane {
    /// The watch button's label and its menu's first item (View › Reload on File Changes is MainMenu's).
    static var watchTitle: String { String(localized: "Reload on File Changes") }

    /// `browser.watch` and the toolbar menu: applies `change` (`defaultFolder` when turning on without a folder) and
    /// returns the state as the API reports it.
    @discardableResult
    func applyWatch(_ change: BrowserWatchChange, defaultFolder: String?) throws -> JSONValue {
        let watch = try change.applied(to: self.watch, defaultFolder: defaultFolder)
        // A query reports a folder that has gone (`error`) instead of failing.
        if !change.isQuery, let folder = watch?.folder, !Self.isFolder(folder) {
            throw RPCError.invalidParams("not a folder: \(folder)")
        }
        setWatch(watch)
        return watchJSON
    }

    var watchJSON: JSONValue {
        BrowserWatch.json(watch, active: watch == nil ? nil : directoryWatcher != nil && watchProblem == nil,
                          problem: watchProblem)
    }

    func setWatch(_ watch: BrowserWatch?) {
        guard watch != self.watch else { return }
        if watch?.folder != self.watch?.folder { watchEventID = nil }  // no replay of another folder's history
        self.watch = watch
        updateWatcher()
        if watch == nil { watchEventID = nil }  // turned on again later: nothing to replay
        updateWatchButton()
    }

    /// Runs the watcher while the pane is in a window and its page may reload; stops it otherwise. Restarting after
    /// the pane was off screen replays what changed meanwhile (FSEvents history since it stopped), so the page reloads
    /// once when it is shown again; after a page that does not reload (remote) nothing is replayed. A watcher that
    /// FSEvents did not start (`watchProblem`) is tried again on the next call.
    func updateWatcher() {
        let wanted = window != nil && (watch?.reloads(webView.url) ?? false)
        if wanted, let watch, directoryWatcher?.folder != watch.folder {
            directoryWatcher?.stop()
            directoryWatcher = DirectoryWatcher(folder: watch.folder, since: watchEventID, handler: { [weak self] changes in
                self?.filesChanged(changes)
            }, rootChanged: { [weak self] in
                self?.watchFolderChanged()
            })
            if directoryWatcher != nil {
                watchEventID = nil
                watchProblem = Self.isFolder(watch.folder) ? nil : .folderMissing
            } else {
                watchProblem = .cannotWatch
            }
        } else if !wanted {
            watchProblem = nil  // paused, which the toolbar and `active` show
            guard let watcher = directoryWatcher else { return }
            watchEventID = window == nil ? FSEventsGetCurrentEventId() : nil
            watcher.stop()
            directoryWatcher = nil
            cancelPendingReload()
        }
    }

    /// The watched folder itself was removed, moved or created again: shown on the toolbar and in `browser.watch`
    /// while it is missing (FSEvents keeps watching the path, so a folder created there again is watched).
    private func watchFolderChanged() {
        guard let watch, directoryWatcher != nil else { return }
        watchProblem = Self.isFolder(watch.folder) ? nil : .folderMissing
        updateWatchButton()
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Drops a reload that is waiting for the debounce.
    private func cancelPendingReload() {
        watchReload?.cancel()
        watchReload = nil
        watchDebounce.reset()
    }

    private func filesChanged(_ changes: [DirectoryWatcher.Change]) {
        guard let watch else { return }
        // FSEvents reports real paths (/private/tmp for /tmp, links resolved).
        let folder = DirectoryWatcher.realPath(watch.folder)
        let keep = BrowserWatch.pageFolder(webView.url).map(DirectoryWatcher.realPath)
        let counted = changes.filter { !BrowserWatch.isIgnored($0.path, folder: folder, keep: keep, isFolder: $0.isFolder) }
        guard !counted.isEmpty else { return }
        #if DEBUG
        watchCountedPaths = counted.map(\.path)
        #endif
        let fire = watchDebounce.change(at: Date())
        watchReload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchDebounce.reset()
                self.watchReload = nil
                guard self.window != nil, self.watch?.reloads(self.webView.url) == true else { return }
                self.reload()
                #if DEBUG
                self.watchReloadCount += 1
                #endif
            }
        }
        watchReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fire.timeIntervalSinceNow), execute: item)
    }

    func stopWatching() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        watchProblem = nil
        cancelPendingReload()
    }

    // MARK: - Toolbar

    func updateWatchButton() {
        let failed = watch != nil && watchProblem != nil
        watchButton.contentTintColor = watch == nil ? nil : failed ? .systemRed : .controlAccentColor
        watchButton.image = NSImage(systemSymbolName: watch == nil ? "eye" : failed ? "eye.trianglebadge.exclamationmark" : "eye.fill",
                                    accessibilityDescription: Self.watchTitle)
        var tip = Self.watchTitle
        if let watch {
            tip += " — " + (watch.folder as NSString).abbreviatingWithTildeInPath
            if let problem = watchProblemText {
                tip += "\n" + problem
            } else if directoryWatcher == nil {
                tip += "\n" + String(localized: "Paused: the page is not local or the pane is not on screen.")
            }
        }
        watchButton.toolTip = tip
    }

    /// Why the watch is not watching, for the toolbar (`browser.watch` reports `BrowserWatch.Problem.message`).
    private var watchProblemText: String? {
        guard watch != nil else { return nil }
        switch watchProblem {
        case .cannotWatch: return String(localized: "Not watching: the folder cannot be watched.")
        case .folderMissing: return String(localized: "Not watching: the folder was removed or moved.")
        case nil: return nil
        }
    }

    /// Applies a change from the toolbar menu; beeps when it fails or the folder cannot be watched, as the main
    /// toggle does.
    private func applyWatchFromMenu(_ change: BrowserWatchChange) {
        do {
            try applyWatch(change, defaultFolder: nil)
            if watchProblem != nil { NSSound.beep() }
        } catch {
            NSSound.beep()
        }
    }

    @objc func watchButtonClicked(_ sender: NSButton) {
        onFocus?()
        popUpToolbarMenu(watchMenu(), below: sender)
    }

    func watchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector?, on: Bool = false, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.isEnabled = enabled
            return item
        }
        menu.addItem(item(Self.watchTitle, #selector(toggleWatch), on: watch != nil))
        let folder = watch?.folder ?? defaultWatchFolder?()
        let folderTitle = folder.map { String(localized: "Folder: \(($0 as NSString).abbreviatingWithTildeInPath)") }
            ?? String(localized: "Folder: none")
        menu.addItem(item(folderTitle, nil, enabled: false))
        if let problem = watchProblemText { menu.addItem(item(problem, nil, enabled: false)) }
        menu.addItem(item(String(localized: "Choose Folder…"), #selector(chooseWatchFolder)))
        menu.addItem(.separator())
        let remote = item(String(localized: "Also Reload Remote Pages"), #selector(toggleWatchRemote), on: watch?.remote == true,
                          enabled: watch != nil)
        remote.toolTip = String(localized: "By default only local pages (file:// and localhost) reload.")
        menu.addItem(remote)
        menu.addItem(.separator())
        let ignored = item(String(localized: "Ignored: .git, node_modules, build folders, dot files"), nil, enabled: false)
        menu.addItem(ignored)
        return menu
    }

    /// Turns watching on (the folder of the last watch, else the workspace's) or off; asks for a folder when there is
    /// none, beeps when the folder cannot be watched.
    @objc func toggleWatch() {
        do {
            var change = BrowserWatchChange(off: watch != nil)
            change.turnsOn = watch == nil
            try applyWatch(change, defaultFolder: defaultWatchFolder?())
            if watchProblem != nil { NSSound.beep() }
        } catch {
            if watch == nil { chooseWatchFolder() } else { NSSound.beep() }
        }
    }

    @objc func toggleWatchRemote() {
        guard let watch else { return }
        applyWatchFromMenu(BrowserWatchChange(remote: !watch.remote))
    }

    @objc func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Watch")
        panel.message = String(localized: "Reload this page when files in the folder change.")
        if let folder = watch?.folder ?? defaultWatchFolder?() { panel.directoryURL = URL(fileURLWithPath: folder) }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.applyWatchFromMenu(BrowserWatchChange(folder: url.standardizedFileURL.path))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
