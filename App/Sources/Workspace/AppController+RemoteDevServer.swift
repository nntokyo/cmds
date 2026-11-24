import AppKit
import CmdsCore
import Darwin

/// A dev server on an SSH host, opened here (#174 G24): ⌘-click on the server's `http://localhost:5173` in an SSH pane
/// opens the page in a browser pane through a port forward you started (`ssh -L 15173:localhost:5173 HOST`, in any
/// terminal, or `LocalForward` in ~/.ssh/config). Without one nothing opens (this Mac's own localhost would be another
/// page) and the sidebar says which `ssh -L` would do it. cmds never starts a forward itself.
extension AppController {
    /// ⌘-click on a loopback address in SSH pane `pane`.
    func openServerPage(_ link: String, from pane: Pane) {
        guard let host = pane.ssh?.launch.host, let port = PortForward.serverPort(of: link) else { return }
        let forwards = PortForwardFinder.forwards(to: host)
        if let local = PortForward.localURL(for: link, through: forwards) {
            _ = try? openBrowser(paneID: pane.id, url: local.absoluteString, recordOpener: true)
            return
        }
        NSSound.beep()
        let portText = String(port)  // as written, without a thousands separator
        let text = String(localized: "No port forward to :\(portText) on \(host). Start one: ssh -N -L \(portText):localhost:\(portText) \(host)",
                          comment: "sidebar status after a click on a server's localhost address without a forward; arguments: port, host, port, port, host")
        try? setStatus(workspaceID: pane.workspaceID, text: text, level: .warning)
    }
}

/// The port forwards of the `ssh` processes running on this Mac (the user's): those whose destination is the host
/// and whose local port is listening. Read when asked (a click), never polled.
enum PortForwardFinder {
    static func forwards(to host: String) -> [PortForward] {
        let wanted = PortForward.hostName(ofDestination: host)
        var found: [PortForward] = []
        var unexplained = false
        for pid in ProcessScanner.allPIDs() where isSSH(pid) {
            let (destination, forwards) = PortForward.parse(sshArguments: Array(arguments(pid).dropFirst()))
            guard let destination, PortForward.hostName(ofDestination: destination) == wanted else { continue }
            let listening = ProcessScanner.listeningPorts(pid: pid)
            found += forwards.filter { listening.contains($0.localPort) }
            if !listening.subtracting(forwards.map(\.localPort)).isEmpty { unexplained = true }
        }
        // A forward from ~/.ssh/config (`LocalForward`) is not on the command line: ask ssh what the host's config says.
        if unexplained {
            found += configForwards(host: host).filter { forward in !found.contains { $0.localPort == forward.localPort } }
        }
        return found
    }

    private static func isSSH(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return (String(cString: path) as NSString).lastPathComponent == "ssh"
    }

    /// argv of the process (the user's own processes only).
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]), maxArguments: 64)?.arguments ?? []
        }
    }

    /// `LocalForward` lines of `ssh -G HOST` (reads the config, connects nowhere).
    private static func configForwards(host: String) -> [PortForward] {
        guard let output = CommandOutput.complete("/usr/bin/ssh", ["-G", "--", host], timeout: 2), output.status == 0 else { return [] }
        return String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.lowercased().hasPrefix("localforward ") else { return nil }
            return PortForward.parse(configLine: String(line.dropFirst("localforward ".count)))
        }
    }
}
