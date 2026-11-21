import AppKit
import CmdsCore

/// Tabs (docs/guide/workspaces-and-panes.md "Tabs"): several panes stacked in one place of the split tree
/// (`SplitNode.tabs`). Every tab is a pane of its own (terminal, browser, preview, files) with its own id; the ones not
/// shown keep running (as panes of a hidden workspace do). Focusing a pane brings its tab to the front (`applyFocus`).
extension AppController {
    /// The browser tab group a page opened from `pane` joins: the pane's own when it is a browser, else the workspace's
    /// browser on screen (the first in reading order), else any of its browser panes. nil: none, the page gets a split.
    func browserTabGroup(for pane: Pane) -> Pane? {
        if pane.kind == .browser { return pane }
        guard let workspace = workspace(id: pane.workspaceID), let root = workspace.root else { return nil }
        let visible = root.visiblePaneIDs.compactMap { workspace.panes[$0] }
        return visible.first { $0.kind == .browser } ?? workspace.orderedPanes.first { $0.kind == .browser }
    }

    /// Call before taking `paneID` out of `workspace`'s tree; afterwards the returned function names the pane to focus:
    /// the tab its group shows next (a tab of a group), else the pane on screen that followed (or preceded) it in
    /// reading order. Never a tab that is not shown, so closing a pane does not switch another group's tab.
    func nextFocus(afterRemoving paneID: String, from workspace: Workspace) -> () -> Pane? {
        let group = workspace.root?.leaf(for: paneID).flatMap { $0.isTabGroup ? $0 : nil }
        let order = workspace.root?.visiblePaneIDs ?? []
        return { [weak workspace] in
            guard let workspace, let root = workspace.root else { return nil }
            if let group, let shown = group.paneID, let pane = workspace.panes[shown] { return pane }
            let remaining = root.visiblePaneIDs
            let index = order.firstIndex(of: paneID) ?? 0
            // The first pane on screen after it that is still there, else the one before.
            let after = order[min(index + 1, order.count)...].first { remaining.contains($0) }
            let before = order[..<index].last { remaining.contains($0) }
            return (after ?? before ?? remaining.first).flatMap { workspace.panes[$0] }
        }
    }

    // MARK: - Tab context menu

    /// A command of a tab's context menu (TabBarView); beeps when it cannot be done.
    func runTabCommand(_ command: TabCommand, paneID: String) {
        do {
            switch command {
            case .close:
                try closePane(id: paneID)
            case .closeOthers, .closeToTheRight:
                let pane = try resolvePane(paneID)
                guard let leaf = workspace(id: pane.workspaceID)?.root?.leaf(for: paneID),
                      let index = leaf.tabs.firstIndex(of: paneID) else { return NSSound.beep() }
                let closing = command == .closeOthers ? leaf.tabs.filter { $0 != paneID } : Array(leaf.tabs[(index + 1)...])
                // Several terminals at once (programs, agents) only after asking.
                let terminals = closing.compactMap { self.pane(id: $0) }.filter { $0.terminal != nil }.count
                if terminals > 0, closing.count > 1 {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Close \(closing.count) tabs?", comment: "Tab context menu")
                    alert.informativeText = String(localized: "Programs running in their terminals will be ended.", comment: "Tab context menu")
                    alert.addButton(withTitle: String(localized: "Close", comment: "Tab context menu"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                // The kept tab shows (without taking the keyboard from elsewhere).
                if command == .closeOthers, leaf.paneID != paneID {
                    if let workspace = workspace(id: pane.workspaceID), workspace.focusedPaneID.map(leaf.tabs.contains) == true {
                        applyFocus(pane, in: workspace)
                    } else {
                        leaf.selectTab(paneID)
                    }
                }
                for id in closing { try? closePane(id: id) }
            case .duplicate:
                try duplicateTab(paneID: paneID)
            case .reload:
                try browser(paneID: paneID).reload()
            case .moveToNewWorkspace:
                movePaneToNewWorkspaceFromUI(paneID: paneID)
            }
        } catch {
            NSSound.beep()
        }
    }

    /// A new tab right after `paneID` showing the same, with the same settings: a browser's page (device size, color
    /// scheme, responsive view, reload on file changes), a preview's file, a files pane's folder (hidden files, Follow
    /// Terminal), a terminal in the same directory (SSH: the same host; the same Claude account).
    @discardableResult
    func duplicateTab(paneID: String) throws -> PaneInfo {
        let pane = try resolvePane(paneID)
        if let browser = pane.browser {
            let url = browser.currentURL.flatMap { $0.scheme == "about" ? nil : $0.absoluteString } ?? ""
            let info = try newTab(paneID: pane.id, kind: .browser, url: url)
            if let copy = self.pane(id: info.id)?.browser {
                if !browser.emulation.isDefault { copy.setEmulation(browser.emulation) }
                if let responsive = browser.responsive { copy.setResponsive(responsive) }
                if let watch = browser.watch { copy.setWatch(watch) }
            }
            return try paneInfo(id: info.id)
        }
        if let preview = pane.preview {
            return try split(paneID: pane.id, direction: .right, kind: .preview,
                             file: PreviewTarget(path: preview.path, format: preview.forcedFormat), asTab: true)
        }
        if let files = pane.files {
            let info = try split(paneID: pane.id, direction: .right, kind: .files, cwd: files.folder,
                                 filesHost: files.host, asTab: true)
            self.pane(id: info.id)?.files?.restore(showHidden: files.showHidden, followsTerminal: files.followsTerminal)
            return try paneInfo(id: info.id)
        }
        // A local terminal keeps its Claude account (its shell gets the account's CLAUDE_CONFIG_DIR).
        let account = pane.ssh == nil ? pane.claudeAccount.flatMap { claudeAccounts.account(named: $0) } : nil
        return try split(paneID: pane.id, direction: .right, kind: .terminal, account: account, asTab: true)
    }

    // MARK: - Tabs agents open

    /// Tabs one agent (terminal pane) keeps open in a workspace; the oldest it opened that are not shown close beyond.
    static let maxAgentTabs = 10

    /// A browser tab `requester` opened before showing the same page (fragment ignored): loaded again and shown
    /// instead of a new tab, so an agent checking its page again and again does not pile up tabs. nil: none.
    func reuseAgentTab(of requester: Pane, url: String, focus: Bool) throws -> PaneInfo? {
        guard let wanted = BrowserPane.url(fromUserInput: url), let workspace = workspace(id: requester.workspaceID) else {
            return nil
        }
        // The same page: scheme and host in any case, an empty path as `/`, no fragment.
        func key(_ url: URL?) -> String? {
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if parts.path.isEmpty { parts.path = "/" }
            return parts.string
        }
        guard let wantedKey = key(wanted) else { return nil }
        // What the tab shows, or what it was asked to show (a page still loading, or one the server redirected).
        guard let pane = workspace.orderedPanes.first(where: { pane in
            guard pane.openedBy == requester.id, pane.agentTabOrder != nil, let browser = pane.browser else { return false }
            return key(browser.currentURL) == wantedKey || key(browser.requestedURL) == wantedKey
        }), let browser = pane.browser else { return nil }
        try browser.navigate(to: wanted.absoluteString)
        if focus {
            try focusPane(id: pane.id)
        } else if let leaf = workspace.root?.leaf(for: pane.id), leaf.paneID != pane.id,
                  !(workspace.focusedPaneID.map(leaf.tabs.contains) ?? false) {
            leaf.selectTab(pane.id)
            emit(.workspace(id: workspace.id))
        }
        return try paneInfo(id: pane.id)
    }

    /// Closes the oldest background browser tabs opened by `opener` beyond `maxAgentTabs` (never the shown or focused
    /// one, never tabs the user opened).
    func closeOldAgentTabs(openedBy opener: String, keeping kept: String) {
        guard let pane = pane(id: kept), let workspace = workspace(id: pane.workspaceID), let root = workspace.root else { return }
        // Only tabs an agent opened in this run (`agentTabOrder`): never ones `cmds browser open` opened for a person.
        let mine = workspace.orderedPanes.filter { $0.openedBy == opener && $0.browser != nil && $0.agentTabOrder != nil }
        guard mine.count > Self.maxAgentTabs else { return }
        // In the order they opened.
        let oldest = mine.sorted { ($0.agentTabOrder ?? 0) < ($1.agentTabOrder ?? 0) }
        var excess = mine.count - Self.maxAgentTabs
        for candidate in oldest where excess > 0 {
            guard candidate.id != kept, candidate.id != workspace.focusedPaneID, root.isBackgroundTab(candidate.id) else { continue }
            try? closePane(id: candidate.id)
            excess -= 1
        }
    }

    /// ⌘T: a new tab beside `paneID` (default: the focused pane): a browser tab (start page, address bar focused) for
    /// a browser, else a terminal in the pane's directory. Returns the new pane.
    @discardableResult
    func newTab(paneID: String? = nil, kind: PaneKind? = nil, url: String? = nil, cwd: String? = nil,
                focus: Bool = true, recordOpener: Bool = false) throws -> PaneInfo {
        let source = try resolvePane(paneID)
        let kind = kind ?? (source.kind == .browser ? .browser : .terminal)
        if kind == .browser, let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           BrowserPane.url(fromUserInput: url) == nil {
            throw RPCError.invalidParams("cannot load \"\(url.prefix(200))\": not a valid URL")
        }
        guard kind == .terminal || kind == .browser else {
            throw RPCError.invalidParams("a new tab is a terminal or a browser")
        }
        let info = try split(paneID: source.id, direction: .right, kind: kind, url: kind == .browser ? (url ?? "") : nil,
                             cwd: kind == .terminal ? cwd : nil, focus: focus, recordOpener: recordOpener, asTab: true)
        if focus, kind == .browser, url?.isEmpty != false { pane(id: info.id)?.browser?.focusAddressBar() }
        return info
    }

    /// Shows the tab `paneID` and gives it the keyboard.
    func selectTab(paneID: String) throws {
        try focusPane(id: paneID)
    }

    /// The tab `offset` places from the focused pane's (wrapping); beeps when the focused pane has no other tab.
    func selectAdjacentTab(offset: Int) {
        guard let workspace = selectedWorkspace, let focused = workspace.focusedPaneID,
              let next = workspace.root?.leaf(for: focused)?.tab(offset: offset) else { return NSSound.beep() }
        try? focusPane(id: next)
    }

    /// Pane › Move Tab Left / Right (⌃⇧⌘[ / ⌃⇧⌘]): the focused tab one place along its bar (beeps at the ends).
    func moveFocusedTab(by offset: Int) {
        guard let workspace = selectedWorkspace, let id = workspace.focusedPaneID,
              let leaf = workspace.root?.leaf(for: id), leaf.isTabGroup, let index = leaf.tabs.firstIndex(of: id),
              leaf.tabs.indices.contains(index + offset) else { return NSSound.beep() }
        leaf.moveTab(id, to: index + offset)
        emit(.workspace(id: workspace.id))
    }

    /// Moves `paneID` into the tab group of `targetID` (a pane dropped on a tab bar or on the top strip of a pane,
    /// `pane.move` with `tab`) at `index` among its tabs (nil: right after the target), shown and focused. Across
    /// workspaces as `movePane` does; within the group it only reorders.
    func moveIntoTabs(paneID: String, of targetID: String, index: Int? = nil, focus: Bool = true) throws {
        let pane = try resolvePane(paneID)
        let target = try resolvePane(targetID)
        guard let destination = workspace(id: target.workspaceID), let leaf = destination.root?.leaf(for: target.id) else {
            throw RPCError.notFound("pane not found: \(targetID)")
        }
        guard let from = leaf.tabs.firstIndex(of: pane.id) else {
            try movePane(paneID: pane.id, beside: target.id, focus: focus, intoTabs: true, tabIndex: index)
            return
        }
        // Already in the group (a tab dragged along its own bar, whose target is the shown tab: maybe itself).
        guard pane !== target || index != nil else { throw RPCError.invalidParams("a pane cannot be a tab of itself") }
        let to = index ?? (leaf.tabs.firstIndex(of: target.id) ?? 0) + 1
        leaf.moveTab(pane.id, to: to > from ? to - 1 : to)
        guard focus else { return emit(.workspace(id: destination.id)) }
        let changedWorkspace = destination.id != selectedWorkspaceID
        setSelectedWorkspace(destination.id)
        applyFocus(pane, in: destination)
        emit(changedWorkspace ? .workspaces : .workspace(id: destination.id))
        pane.focus()
    }
}
