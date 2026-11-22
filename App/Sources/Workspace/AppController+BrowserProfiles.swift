import Foundation
import CmdsCore

// Login profiles of browser panes (BrowserProfiles.swift, docs/guide/workspaces-and-panes.md "Login profiles").
extension AppController {
    /// `browser.profile`: the profile of a browser pane, or of the pages a terminal pane opens; with `change`, set first
    /// (`.some(nil)`: the shared data). A browser pane moved to another profile loads its page again there.
    /// `openedBy` (`cmds mcp`): only that terminal pane itself or a pane opened from it.
    func browserProfile(paneID: String?, change: String??, openedBy: String?) throws -> BrowserProfileState {
        let pane = try resolvePane(paneID)
        if let openedBy, pane.id != openedBy, pane.openedBy != openedBy {
            throw RPCError.invalidParams("pane \(pane.id) is neither pane \(openedBy) nor opened from it")
        }
        guard pane.browser != nil || (pane.kind == .terminal && pane.ssh == nil) else {
            throw RPCError.invalidParams("pane \(pane.id) is neither a browser nor a local terminal")
        }
        if let change {
            if let browser = pane.browser {
                browser.setProfile(change)
            } else if pane.browserProfile != change {
                pane.browserProfile = change
                scheduleSave()
            }
            if let change { _ = BrowserProfiles.store(for: change) }  // listed from now on
            emit(.workspace(id: pane.workspaceID))
        }
        return BrowserProfileState(pane: pane.id, profile: pane.profileForOpenedPages, profiles: BrowserProfiles.names)
    }

    /// `browser.profile_remove`: deletes a profile's cookies and storage; refused while a pane uses it.
    func removeBrowserProfile(_ raw: String) async throws -> [String] {
        guard let name = try BrowserProfile.validated(raw) else { throw RPCError.invalidParams("missing param: profile") }
        let users = workspaces.flatMap(\.orderedPanes).filter { $0.profileForOpenedPages == name }.map(\.id)
        guard users.isEmpty else {
            throw RPCError.invalidParams("profile \"\(name)\" is used by \(users.joined(separator: ", ")); move or close them first")
        }
        try await BrowserProfiles.remove(name)
        return BrowserProfiles.names
    }
}
