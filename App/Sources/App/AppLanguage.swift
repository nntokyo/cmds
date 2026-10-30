import AppKit
import CmdsCore

/// cmds › Language: System / 日本語 / English (docs/ARCHITECTURE.md "Localization").
///
/// The UI follows the system language (System Settings › General › Language & Region, which also has a per-app
/// override). This menu sets `AppleLanguages` in the app's own defaults domain, which AppKit reads at launch, so it
/// takes effect after a relaunch. An isolated instance (`CMDS_SUPPORT_DIR`) never touches the defaults of the app in
/// use: launch it with `-AppleLanguages '(ja)'` instead; the menu only shows the choice.
@MainActor
enum AppLanguage {
    static let defaultsKey = "AppleLanguages"
    /// Localizations shipped in the app, with their names in their own language (not translated).
    static let choices: [(code: String, name: String)] = [("ja", "日本語"), ("en", "English")]
    private static var isolatedChoice: String??

    /// The language code chosen in this menu, or nil for "System".
    static var override: String? {
        if isolated, let isolatedChoice { return isolatedChoice }
        let domain = isolated
            ? UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            : UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "tokyo.n-n.cmds") ?? [:]
        return (domain[defaultsKey] as? [String])?.first.map { code in
            choices.first { code.hasPrefix($0.code) }?.code ?? code
        }
    }

    private static var isolated: Bool { CmdsEnv.supportDirectoryOverride() != nil }

    static func menu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Language"))
        let system = NSMenuItem(title: String(localized: "System"), action: #selector(LanguageMenuTarget.choose(_:)), keyEquivalent: "")
        system.target = LanguageMenuTarget.shared
        system.toolTip = String(localized: "Use the language set in System Settings › General › Language & Region.")
        menu.addItem(system)
        menu.addItem(.separator())
        for choice in choices {
            let item = NSMenuItem(title: choice.name, action: #selector(LanguageMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = LanguageMenuTarget.shared
            item.representedObject = choice.code
            menu.addItem(item)
        }
        return menu
    }

    static func set(_ code: String?) {
        guard code != override else { return }
        if isolated {
            isolatedChoice = .some(code)
            return
        }
        if let code {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        askToRelaunch()
    }

    private static func askToRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch cmds to change the language?")
        alert.informativeText = String(localized: "Programs running in the terminals will end. Workspaces and panes are restored after the relaunch.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    /// Opens the app again once this process has exited (gives up after a minute, e.g. when quitting was cancelled).
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            i=0; while /bin/kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 300 ] && exit 0; sleep 0.2; done
            exec /usr/bin/open "$2"
            """, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return NSSound.beep() }
        NSApp.terminate(nil)
    }
}

@MainActor
final class LanguageMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = LanguageMenuTarget()

    @objc func choose(_ sender: NSMenuItem) { AppLanguage.set(sender.representedObject as? String) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = (menuItem.representedObject as? String) == AppLanguage.override ? .on : .off
        return true
    }
}
