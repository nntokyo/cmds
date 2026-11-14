import AppKit
import CmdsCore

/// Settings › Agents › Antigravity limits (#290): adds `cmds hook agy-status` to the status line in agy's
/// `settings.json`, so its quota windows reach cmds (sidebar footer, menu bar, widget, iPhone). Asks before replacing
/// another status line; keeps a copy of the file first (`settings.json.cmds-backup-<time>`).
@MainActor
enum AntigravitySetup {
    static var path: String { AntigravitySettings.path() }

    static var state: AntigravitySettings.State {
        AntigravitySettings.state(of: FileManager.default.contents(atPath: path),
                                  exists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The `cmds` the status line runs: this app's own CLI by its full path (agy in any terminal finds it, also
    /// without Install Command Line Tool…), else `cmds` on the PATH.
    static var cli: String { BundledCLI.executablePath ?? "cmds" }

    /// Sets it up after asking; `done` runs when the file was written.
    static func setUp(in window: NSWindow?, done: @escaping () -> Void) {
        let current = state
        switch current {
        case .setUp:
            done()
            return
        case .unreadable:
            show(String(localized: "Antigravity’s settings file is not valid JSON, so cmds left it alone: \(path)", comment: "Settings › Agents › Antigravity limits"),
                 in: window)
            return
        case .otherCommand(let command):
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace Antigravity’s status line?", comment: "Settings › Agents › Antigravity limits")
            alert.informativeText = String(localized: "It runs “\(command)” now. cmds puts its own command there, with Antigravity’s default status line kept; a copy of the file is saved next to it.",
                                           comment: "Settings › Agents › Antigravity limits")
            alert.addButton(withTitle: String(localized: "Replace", comment: "Settings › Agents › Antigravity limits"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let answer: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn { write(in: window, done: done) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
        case .noFile, .notSetUp, .needsUpdate:
            // #305: cmds' own hook by a bare `cmds` or a gone path is rewritten without asking.
            write(in: window, done: done)
        }
    }

    private static func write(in window: NSWindow?, done: () -> Void) {
        let fileManager = FileManager.default
        let existing = fileManager.contents(atPath: path)
        guard let data = AntigravitySettings.settingUp(existing, cli: cli) else {
            show(String(localized: "Antigravity’s settings file is not valid JSON, so cmds left it alone: \(path)", comment: "Settings › Agents › Antigravity limits"),
                 in: window)
            return
        }
        do {
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if existing != nil {
                let stamp = Int(Date().timeIntervalSince1970)
                try fileManager.copyItem(atPath: path, toPath: "\(path).cmds-backup-\(stamp)")
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            done()
        } catch {
            show(error.localizedDescription, in: window)
        }
    }

    /// The row's note: whether it is set up, and what it shows.
    static func note(for state: AntigravitySettings.State) -> String {
        switch state {
        case .setUp:
            return String(localized: "Set up. The quota windows (Gemini 5h / 7d…) show in the sidebar footer and the menu bar while agy runs in a terminal (not with agy -p), and are kept until they reset.",
                          comment: "Settings › Agents › Antigravity limits")
        case .needsUpdate:
            return String(localized: "Antigravity’s status line runs cmds through the PATH or a path that is gone, so agy outside cmds may not reach it. Update writes this app’s full path.",
                          comment: "Settings › Agents › Antigravity limits")
        case .otherCommand:
            return String(localized: "Antigravity’s status line runs another command. Set Up replaces it (asks first) so cmds gets its quota windows.",
                          comment: "Settings › Agents › Antigravity limits")
        case .unreadable:
            return String(localized: "Antigravity’s settings file is not valid JSON.", comment: "Settings › Agents › Antigravity limits")
        case .noFile, .notSetUp:
            return String(localized: "Adds cmds to Antigravity’s status line (~/.gemini/antigravity-cli/settings.json), so its quota windows show in the sidebar footer and the menu bar.",
                          comment: "Settings › Agents › Antigravity limits")
        }
    }

    private static func show(_ text: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Antigravity could not be set up", comment: "Settings › Agents › Antigravity limits")
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
