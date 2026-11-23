import AppKit
import CmdsCore
import Security

/// A workspace's environment variables (#174 G23, `WorkspaceEnvironment`): edited in Workspace › Environment
/// Variables…, given to the terminals opened in the workspace afterwards. Secrets stay in the Keychain: only their
/// reference is saved, and the value is read when a terminal opens. The API lists the names, never a value.
extension AppController {
    /// The variables for a new terminal of `workspace`. A secret that cannot be read is left out and named in the
    /// sidebar's status text.
    func workspaceVariables(_ workspace: Workspace) -> [String: String] {
        guard !workspace.environment.isEmpty else { return [:] }
        let (variables, missing) = workspace.environment.resolved(secret: Self.keychainPassword)
        if !missing.isEmpty {
            let text = String(localized: "Not in the Keychain: \(missing.joined(separator: ", "))",
                              comment: "sidebar status when a workspace variable's Keychain item cannot be read; argument: variable names")
            try? setStatus(workspaceID: workspace.id, text: text)
        }
        return variables
    }

    /// The Keychain service of the secrets `cmds env secret` keeps (`workspace.set_secret`), one item per name.
    static let secretService = "cmds.env"

    /// A generic password of the login Keychain, read without ever asking: an item cmds may not read without the
    /// user's say (one another app or `security` made) counts as missing, so opening a terminal never waits on a
    /// Keychain dialog. cmds' own items (`storeSecret`) and items that allow cmds in Keychain Access are read.
    static func keychainPassword(service: String, account: String?) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = withoutKeychainDialogs { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Runs `body` with the file-based Keychain's dialogs turned off (they return errSecInteractionNotAllowed), as
    /// `kSecUseAuthenticationUIFail` alone does not promise that for an item's access list.
    private static func withoutKeychainDialogs<T>(_ body: () -> T) -> T {
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }

    /// `workspace.set_secret`: keeps `value` as cmds' own Keychain item for `name` (readable by cmds without asking)
    /// and sets `name` in the workspace to it; an empty value deletes the item and the variable.
    func setSecret(name: String, value: String, workspaceID: String?) throws -> JSONValue {
        let workspace = try resolveWorkspace(workspaceID)
        let entry = WorkspaceEnvironment.Entry(name: name, value: .keychain(service: Self.secretService, account: name))
        // Checks the name as a line of the editor would be.
        do { _ = try WorkspaceEnvironment.parse(entry.line) } catch let error as WorkspaceEnvironment.Invalid {
            throw RPCError.invalidParams(error.description)
        }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.secretService,
                                   kSecAttrAccount as String: name]
        SecItemDelete(item as CFDictionary)
        var environment = workspace.environment
        environment.entries.removeAll { $0.name == name }
        if !value.isEmpty {
            var add = item
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrLabel as String] = "cmds: \(name)"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw RPCError(code: 500, message: "could not save \(name) in the Keychain (\(status))")
            }
            environment.entries.append(entry)
        }
        guard environment.entries.count <= WorkspaceEnvironment.maxEntries else {
            throw RPCError.invalidParams("at most \(WorkspaceEnvironment.maxEntries) variables")
        }
        workspace.environment = environment
        emit(.workspace(id: workspace.id))
        return try workspaceEnvironmentInfo(workspaceID: workspace.id)
    }

    /// `workspace.env`: the names, and where each secret is kept; no value is given out.
    func workspaceEnvironmentInfo(workspaceID: String?) throws -> JSONValue {
        let workspace = try resolveWorkspace(workspaceID)
        return .object(["workspace": .string(workspace.id), "variables": .array(workspace.environment.entries.map { entry in
            var object: [String: JSONValue] = ["name": .string(entry.name), "secret": .bool(entry.isSecret)]
            if case .keychain(let service, let account) = entry.value {
                object["keychain"] = .string(service + (account.map { "/\($0)" } ?? ""))
            }
            return .object(object)
        })])
    }

    /// Sets the variables from `NAME=value` lines (the menu's editor and `debug.workspace_env`).
    func setWorkspaceEnvironment(_ text: String, workspace: Workspace) throws {
        do {
            workspace.environment = try WorkspaceEnvironment.parse(text)
        } catch let error as WorkspaceEnvironment.Invalid {
            throw RPCError.invalidParams(error.description)
        }
        emit(.workspace(id: workspace.id))
    }

    /// Workspace › Environment Variables…: edits the selected workspace's variables as `NAME=value` lines.
    func editWorkspaceEnvironmentFromMenu() {
        guard let workspace = selectedWorkspace else { return NSSound.beep() }
        editWorkspaceEnvironment(workspace, text: workspace.environment.lines.joined(separator: "\n"), error: nil)
    }

    private func editWorkspaceEnvironment(_ workspace: Workspace, text: String, error: String?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Environment Variables", comment: "title of the workspace environment variables editor")
        let help = String(localized: """
            One NAME=value per line, for the terminals opened in this workspace from now on. Do not write a secret \
            here: run cmds env secret NAME in a terminal of the workspace to keep it in the Keychain.
            """, comment: "workspace environment variables editor: how to write them")
        alert.informativeText = error.map { "\($0)\n\n\(help)" } ?? help
        if error != nil { alert.alertStyle = .warning }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as? NSTextView
        textView?.string = text
        textView?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView?.isAutomaticQuoteSubstitutionEnabled = false
        textView?.isAutomaticDashSubstitutionEnabled = false
        textView?.isAutomaticTextReplacementEnabled = false
        textView?.isAutomaticSpellingCorrectionEnabled = false
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let edited = textView?.string ?? ""
            do {
                try self.setWorkspaceEnvironment(edited, workspace: workspace)
            } catch let error as RPCError {
                // Shown again with the text kept, after this sheet has gone.
                DispatchQueue.main.async { self.editWorkspaceEnvironment(workspace, text: edited, error: error.message) }
            } catch {}
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
            alert.window.initialFirstResponder = textView
        } else {
            handle(alert.runModal())
        }
    }
}
