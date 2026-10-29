import AppKit

/// The `cmds` CLI shipped at `cmds.app/Contents/Resources/bin/cmds` (copied there by a build phase, see project.yml).
enum BundledCLI {
    static var binDirectory: String? { Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true).path }

    static var executablePath: String? {
        guard let path = binDirectory.map({ ($0 as NSString).appendingPathComponent("cmds") }),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `PATH` for spawned terminals: the bundled bin directory first, then the app's own `PATH`.
    /// Login shells run `path_helper`, which keeps these entries (after the system ones).
    static var terminalPATH: String? {
        guard let bin = binDirectory else { return nil }
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let rest = inherited.split(separator: ":").filter { $0 != bin }.joined(separator: ":")
        return rest.isEmpty ? bin : "\(bin):\(rest)"
    }
}

/// "Install Command Line Tool…": symlinks /usr/local/bin/cmds to the bundled CLI, asking for admin rights if needed.
@MainActor
final class CLIInstaller: NSObject {
    static let shared = CLIInstaller()
    static let linkPath = "/usr/local/bin/cmds"

    @objc func installCommandLineTool(_ sender: Any?) {
        guard let target = BundledCLI.executablePath else {
            return show("The command line tool is missing from this build of cmds.", style: .warning)
        }
        let fileManager = FileManager.default
        let existing = try? fileManager.destinationOfSymbolicLink(atPath: Self.linkPath)
        if existing == target {
            return show("The command line tool is already installed at \(Self.linkPath).", style: .informational)
        }

        let alert = NSAlert()
        alert.messageText = "Install the cmds command line tool?"
        var info = "This creates a symbolic link\n\(Self.linkPath) → \(target)\n\nso `cmds` works in any terminal. "
        if fileManager.fileExists(atPath: Self.linkPath) || existing != nil {
            info += "The existing \(Self.linkPath) will be replaced. "
        }
        info += "You may be asked for an administrator password."
        alert.informativeText = info
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try installDirectly(target: target)
        } catch {
            guard installWithAdministratorPrivileges(target: target) else { return }
        }
        show("Installed. Run `cmds --help` in a new terminal.", style: .informational)
    }

    private func installDirectly(target: String) throws {
        let fileManager = FileManager.default
        let directory = (Self.linkPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if (try? fileManager.destinationOfSymbolicLink(atPath: Self.linkPath)) != nil || fileManager.fileExists(atPath: Self.linkPath) {
            try fileManager.removeItem(atPath: Self.linkPath)
        }
        try fileManager.createSymbolicLink(atPath: Self.linkPath, withDestinationPath: target)
    }

    /// Returns false if the user cancelled or the script failed (an error alert is shown for failures).
    private func installWithAdministratorPrivileges(target: String) -> Bool {
        func literal(_ string: String) -> String {
            "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let directory = (Self.linkPath as NSString).deletingLastPathComponent
        let source = """
            do shell script "mkdir -p " & quoted form of \(literal(directory)) & " && ln -sfn " & quoted form of \(literal(target)) & " " & quoted form of \(literal(Self.linkPath)) with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return true }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return false } // user cancelled
        show("Could not install the command line tool: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")", style: .warning)
        return false
    }

    private func show(_ message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.runModal()
    }
}
