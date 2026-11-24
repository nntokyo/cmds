import Foundation

/// A local port forward the user started with `ssh -L` (#174 G24): a dev server on the server, at
/// `http://localhost:remotePort` there, is `http://localhost:localPort` on this Mac. cmds only finds and uses such
/// forwards (a ⌘-click on the server's `localhost` address in an SSH pane opens the forwarded page in a browser
/// pane); it never starts one.
public struct PortForward: Equatable, Hashable, Sendable {
    public var localPort: Int
    /// Where the server connects: `localhost`, `127.0.0.1`, or another host it reaches.
    public var remoteHost: String
    public var remotePort: Int

    public init(localPort: Int, remoteHost: String, remotePort: Int) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    /// The server's own loopback names: a forward to one of them reaches what the server serves on `localhost`.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0", "[::1]", "::"]

    public static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased()) || host.lowercased().hasSuffix(".localhost")
    }

    /// ssh options that take a value (`ssh(1)`), so their value is not taken for the destination.
    static let optionsWithValue = Set("BbcDEeFIiJLlmOopQRSWw")

    /// The destination and the `-L` / `-o LocalForward=` forwards of an `ssh` command line (`arguments` without the
    /// executable). Unix-socket forwards and dynamic ones are left out.
    public static func parse(sshArguments arguments: [String]) -> (destination: String?, forwards: [PortForward]) {
        var forwards: [PortForward] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument.count > 1 else {
                return (argument, forwards)  // the destination; what follows is the remote command
            }
            if argument == "--" { return (index + 1 < arguments.count ? arguments[index + 1] : nil, forwards) }
            var characters = Array(argument.dropFirst())
            while !characters.isEmpty {
                let option = characters.removeFirst()
                guard optionsWithValue.contains(option) else { continue }
                var value = String(characters)
                characters = []
                if value.isEmpty {
                    index += 1
                    value = index < arguments.count ? arguments[index] : ""
                }
                if option == "L", let forward = parse(localForward: value) {
                    forwards.append(forward)
                } else if option == "o", let forward = parse(option: value) {
                    forwards.append(forward)
                }
            }
            index += 1
        }
        return (nil, forwards)
    }

    /// `-o LocalForward=5173 localhost:5173` / `-o "LocalForward 5173 localhost:5173"`.
    static func parse(option: String) -> PortForward? {
        let parts = option.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " })
        guard parts.count == 2, parts[0].lowercased() == "localforward" else { return nil }
        return parse(configLine: String(parts[1]))
    }

    /// `[bind:]port host:hostport` as in `LocalForward` (also `ssh -G`'s `localforward` lines).
    public static func parse(configLine: String) -> PortForward? {
        let parts = configLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return parse(localForward: "\(parts[0]):\(parts[1])")
    }

    /// `-L` specs: `port:host:hostport` or `bind:port:host:hostport`, an IPv6 host in brackets.
    static func parse(localForward spec: String) -> PortForward? {
        var fields: [String] = []
        var current = ""
        var bracket = false
        for character in spec {
            switch character {
            case "[": bracket = true
            case "]": bracket = false
            case ":" where !bracket:
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        if fields.count == 4 { fields.removeFirst() }  // the bind address
        guard fields.count == 3, let local = Int(fields[0]), let remote = Int(fields[2]), !fields[1].isEmpty,
              (1...65535).contains(local), (1...65535).contains(remote) else { return nil }
        return PortForward(localPort: local, remoteHost: fields[1], remotePort: remote)
    }

    /// The host of an ssh destination as it was written: without `ssh://`, the user and a port.
    public static func hostName(ofDestination destination: String) -> String {
        var host = destination
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if destination.hasPrefix("ssh://"), let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
            host = String(host[..<colon])
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]/")).lowercased()
    }

    /// The page of `link` (the server's `http://localhost:5173/…`) through one of `forwards`: the same path on
    /// `http://localhost:<local port>`. nil when `link` is not a loopback address of the server or no forward goes
    /// to its port.
    public static func localURL(for link: String, through forwards: [PortForward]) -> URL? {
        guard let port = serverPort(of: link), var components = URLComponents(string: link) else { return nil }
        guard let forward = forwards.first(where: { $0.remotePort == port && isLoopback($0.remoteHost) }) else { return nil }
        components.host = "localhost"
        components.port = forward.localPort
        return components.url
    }

    /// The port of a loopback `http(s)` address (80 / 443 when not written); nil for anything else.
    public static func serverPort(of link: String) -> Int? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, isLoopback(host) else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }
}
