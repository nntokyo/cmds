import AppKit
import WebKit
import CmdsCore

// Login profiles (BrowserProfiles.swift, docs/guide/workspaces-and-panes.md "Login profiles").
extension BrowserPane {
    /// Moves the pane to the profile `name` (nil: the shared default data): a new web view on that profile's data
    /// store loads the page again there. Back / forward history is lost, like a suspended tab.
    func setProfile(_ name: String?) {
        guard name != profile else { return }
        let page = pendingURL == nil ? (loadFailure?.url ?? webView.url) : nil
        profile = name
        replaceWebView(dataStore: BrowserProfiles.store(for: name))
        if let page, Self.isWebPage(page) {
            if page.isFileURL {
                webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: page))
            }
        } else if pendingURL == nil {
            showStartPage()  // the start page, about:blank, blob: and data: pages
        }
        updateProfileButton()
        stateDidChange()
        onEmulationChange?()  // saved with the session
    }

    func updateProfileButton() {
        profileButton.title = profile ?? ""
        profileButton.imagePosition = profile == nil ? .imageOnly : .imageLeading
        profileButton.isBordered = profile != nil  // a pane in a profile stands out; the shared data is a plain icon
        profileButton.toolTip = profile.map { String(localized: "Login profile: \($0)") }
            ?? String(localized: "Login profile: shared (default)")
    }

    @objc func profileButtonClicked(_ sender: NSButton) {
        popUpToolbarMenu(profileMenu(), below: sender)
    }

    /// Shared (default), every profile, and New Profile…; the pane's is checked.
    func profileMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ name: String?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(profileChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == profile ? .on : .off
            return item
        }
        menu.addItem(item(String(localized: "Shared (Default)"), nil))
        for name in Set(BrowserProfiles.names + [profile].compactMap { $0 }).sorted() { menu.addItem(item(name, name)) }
        menu.addItem(.separator())
        let new = NSMenuItem(title: String(localized: "New Profile…"), action: #selector(newProfileChosen(_:)), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    @objc private func profileChosen(_ sender: NSMenuItem) {
        setProfile(sender.representedObject as? String)
    }

    @objc private func newProfileChosen(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Login Profile")
        alert.informativeText = String(localized: "Pages in a profile keep their own cookies and sign-ins. Panes with the same profile share them.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Profile name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard let name = try BrowserProfile.validated(field.stringValue) else { return }
            setProfile(name)
        } catch {
            let problem = NSAlert()
            problem.messageText = String(localized: "The profile name cannot be used.")
            problem.informativeText = String(localized: "Use at most 64 characters, without control characters.")
            problem.runModal()
        }
    }
}
