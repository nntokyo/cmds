import AppKit
import CmdsCore

/// Claude in Chrome's native host (`ClaudeChromeHost`): the browser's manifest names a script in one account's config
/// directory, so a config directory made again (signing in afresh, moving accounts) leaves the extension unable to
/// connect under every account. cmds checks when it starts, when Settings › Claude Accounts opens or changes, and when
/// a pane's Claude Code reports its account (at most once a minute), and offers to put the script back. Each missing
/// script is offered once per run; `cmds accounts chrome` and `account.repair_chrome` repair it without asking.
extension AppController {
    private static var chromeHostOffered: Set<String> = []
    private static var chromeHostCheckedAt: Date = .distantPast
    private static var chromeHostAlertShown = false

    /// The config directories where a working wrapper may be: the accounts' and plain claude's.
    private var chromeHostConfigDirs: [String] {
        claudeAccounts.accounts.map { ClaudeAccounts.expandedPath($0.configDir) } + [NSHomeDirectory() + "/.claude"]
    }

    /// The missing host scripts (`account.list`'s `chromeHostMissing`).
    func chromeHostMissing() -> [String] {
        ClaudeChromeHost.check().map(\.host).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// `account.repair_chrome`: writes the missing scripts. Returns those written.
    @discardableResult
    func repairChromeHost() throws -> [String] {
        let broken = ClaudeChromeHost.check()
        do {
            let written = try ClaudeChromeHost.repair(broken, configDirs: chromeHostConfigDirs)
            if !written.isEmpty { NotificationCenter.default.post(name: Self.accountsDidChange, object: nil) }
            let left = broken.filter { !$0.repairable }.map(\.host)
            if written.isEmpty, !left.isEmpty {
                throw RPCError.invalidParams("not Claude Code's script, left alone: \(left.joined(separator: ", ")) "
                                             + "(start claude with --chrome to register it again)")
            }
            return written
        } catch let error as ClaudeChromeHost.RepairError {
            throw RPCError(code: -32603, message: error.description)
        }
    }

    /// From a pane's status line report: checks at most once a minute.
    func checkChromeHostSoon() {
        guard Date().timeIntervalSince(Self.chromeHostCheckedAt) >= 60 else { return }
        offerChromeHostRepair()
    }

    /// Offers to repair a missing host script (once per script and run; only with accounts, the case it comes from).
    /// `window`: show the alert as its sheet.
    func offerChromeHostRepair(in window: NSWindow? = nil) {
        Self.chromeHostCheckedAt = Date()
        guard !claudeAccounts.accounts.isEmpty, !Self.chromeHostAlertShown else { return }
        let broken = ClaudeChromeHost.check().filter { $0.repairable && !Self.chromeHostOffered.contains($0.host) }
        guard !broken.isEmpty else { return }
        broken.forEach { Self.chromeHostOffered.insert($0.host) }
        let paths = Set(broken.map(\.host)).sorted().map { ($0 as NSString).abbreviatingWithTildeInPath }
        let alert = NSAlert()
        alert.messageText = String(localized: "Claude in Chrome cannot connect")
        alert.informativeText = String(localized: """
            The browser starts Claude Code through a script that is missing: \(paths.joined(separator: ", ")). \
            Its config folder was probably made again. Put the script back? Nothing else is changed.
            """)
        alert.addButton(withTitle: String(localized: "Repair"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        Self.chromeHostAlertShown = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Self.chromeHostAlertShown = false
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.repairChromeHost()
            } catch {
                let failed = NSAlert()
                failed.messageText = String(localized: "Claude in Chrome could not be repaired")
                failed.informativeText = (error as? RPCError)?.message ?? "\(error)"
                failed.runModal()
            }
        }
        if let window = window ?? self.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
