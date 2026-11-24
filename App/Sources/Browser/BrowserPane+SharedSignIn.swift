import AppKit
import CmdsCore
import WebKit

/// A page in the shared browser data on a site signed in there (`SharedSignIn`: X, Amazon, GitHub, Google, note…):
/// every workspace uses that sign-in, so an agent could act as another workspace's account. The pane says so once per
/// site, offers its workspace's own profile, and `browser.get_url` / page actions return it as `warning`.
extension BrowserPane {
    /// Tests only (`debug.shared_signin_site`): a local site treated like X or Amazon. Always empty in release builds.
    nonisolated(unsafe) static var testSites: [SharedSignIn.Site] = []

    func checkSharedSignIn() {
        guard profile == nil, let url = webView.url, let site = SharedSignIn.site(forHost: url.host, extra: Self.testSites) else {
            sharedSignIn = nil
            return
        }
        let store = webView.configuration.websiteDataStore
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self, self.profile == nil, SharedSignIn.site(forHost: self.webView.url?.host, extra: Self.testSites) == site else { return }
                let signedIn = SharedSignIn.isSignedIn(site, cookies: cookies.map { (name: $0.name, domain: $0.domain) })
                self.sharedSignIn = signedIn ? site.name : nil
                guard signedIn, self.sharedSignInWarned.insert(site.name).inserted else { return }
                let move = self.onUseWorkspaceProfile
                self.showNotice(.sharedSignIn(site: site.name, canMove: move != nil), onMove: move)
            }
        }
    }

    /// What an agent is told (`warning` in `browser.get_url` and page actions).
    var sharedSignInWarning: String? {
        sharedSignIn.map {
            "This page uses the shared browser sign-ins, where \($0) is signed in for every workspace (maybe as another workspace's account). "
                + "Check the account before acting, or use a login profile of your own (browser_profile)."
        }
    }
}
