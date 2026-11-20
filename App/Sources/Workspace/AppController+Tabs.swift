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
                if command == .closeOthers { try focusPane(id: paneID) }
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

    /// A new tab right after `paneID` showing the same: a browser's page, a preview's file, a files pane's folder, a
    /// terminal in the same directory (SSH: the same host).
    @discardableResult
    func duplicateTab(paneID: String) throws -> PaneInfo {
        let pane = try resolvePane(paneID)
        if let browser = pane.browser {
            return try newTab(paneID: pane.id, kind: .browser, url: browser.currentURL?.absoluteString ?? "")
        }
        if let preview = pane.preview {
            return try split(paneID: pane.id, direction: .right, kind: .preview,
                             file: PreviewTarget(path: preview.path, format: preview.forcedFormat), asTab: true)
        }
        if let files = pane.files {
            return try split(paneID: pane.id, direction: .right, kind: .files, cwd: files.folder,
                             filesHost: files.host, asTab: true)
        }
        return try split(paneID: pane.id, direction: .right, kind: .terminal, asTab: true)
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
        let wantedKey = key(wanted)
        // What the tab shows, or what it was asked to show (a page still loading, or one the server redirected).
        guard let pane = workspace.orderedPanes.first(where: { pane in
            guard pane.openedBy == requester.id, let browser = pane.browser else { return false }
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
        let mine = workspace.orderedPanes.filter { $0.openedBy == opener && $0.browser != nil }
        guard mine.count > Self.maxAgentTabs else { return }
        // Pane ids grow with creation (`p12` before `p13`): the oldest first.
        let oldest = mine.sorted { (Int($0.id.dropFirst()) ?? 0) < (Int($1.id.dropFirst()) ?? 0) }
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
