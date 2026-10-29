import AppKit
import CmdsCore

/// "New SSH Workspace…": host (completion from `~/.ssh/config` `Host` entries, read only), remote directory, title.
@MainActor
enum SSHConnectSheet {
    private static let lastHostKey = "SSHConnectLastHost"

    static func present(in window: NSWindow?, controller: AppController) {
        let alert = NSAlert()
        alert.messageText = "New SSH Workspace"
        alert.informativeText = "Runs your ssh (with ~/.ssh/config) and forwards this pane's cmds socket to the server, "
            + "so cmds-remote.sh there can notify and report agent usage. Nothing is installed on the server."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let host = NSComboBox()
        host.completes = true
        host.usesDataSource = false
        host.addItems(withObjectValues: SSHConfigHosts.load())
        host.placeholderString = "host, user@host or ~/.ssh/config alias"
        host.stringValue = UserDefaults.standard.string(forKey: lastHostKey) ?? ""
        let directory = NSTextField()
        directory.placeholderString = "remote directory (optional, e.g. ~/src/app)"
        let title = NSTextField()
        title.placeholderString = "workspace title (optional)"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Host:"), host],
            [NSTextField(labelWithString: "Directory:"), directory],
            [NSTextField(labelWithString: "Title:"), title],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for field in [host, directory, title] as [NSView] {
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = host

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let launch = try SSHLaunch(host: host.stringValue, remoteCwd: directory.stringValue)
                UserDefaults.standard.set(launch.host, forKey: lastHostKey)
                let name = title.stringValue.trimmingCharacters(in: .whitespaces)
                try controller.createSSHWorkspace(launch, title: name.isEmpty ? nil : name)
            } catch {
                let failure = NSAlert()
                failure.messageText = "Cannot open the SSH workspace"
                failure.informativeText = (error as? SSHLaunch.InvalidInput)?.description
                    ?? (error as? RPCError)?.message ?? error.localizedDescription
                failure.runModal()
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

/// "Install Remote Helper…": types a one-line installer into the focused SSH pane's remote shell, only after the
/// user confirms. Installs `~/.local/bin/cmds-remote.sh` and, when the server has no `cmds`, a `cmds` link to it
/// (so the same Claude Code hook lines work there).
@MainActor
enum RemoteHelperInstaller {
    static func confirmAndInstall(pane: Pane, window: NSWindow?) {
        guard let ssh = pane.ssh, ssh.connected, let terminal = pane.terminal else { return }
        let alert = NSAlert()
        alert.messageText = "Install the remote helper on \(ssh.launch.host)?"
        alert.informativeText = """
            cmds will type one command into this pane's remote shell. It writes ~/.local/bin/cmds-remote.sh \
            (a small sh script; needs python3, socat or nc there) and, if the server has no `cmds` command, \
            ~/.local/bin/cmds linking to it. Nothing else changes.

            Make sure the pane shows a shell prompt (no program running) before you continue.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, ssh.connected, pane.terminal === terminal else { return }
            terminal.sendText(RemoteHelperScript.installCommand() + "\n")
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}
