import Foundation

/// The pane and workspace an SSH pane's forwarded socket is bound to.
public struct RemoteScope: Sendable, Equatable {
    public var paneID: String
    public var workspaceID: String

    public init(paneID: String, workspaceID: String) {
        self.paneID = paneID
        self.workspaceID = workspaceID
    }
}

/// Server-side allowlist for the per-pane sockets that SSH panes forward to the remote host (docs/SSH.md).
///
/// Anything on the server that can reach the forwarded socket (the remote user, root, or whoever compromised the
/// server) gets exactly this: report about and read/type into its *own* pane, and set its own workspace's sidebar
/// text. No other panes, no workspace/pane creation or closing (a new local terminal would mean code execution on the
/// Mac), no browser, no events, no machine-wide stats.
public enum RemoteAPIPolicy {
    /// Methods a remote socket may call. Every other method is refused with 403.
    public static let allowedMethods: Set<String> = [
        "system.ping", "system.identify",
        "notify", "sidebar.set_status",
        "agent.report", "agent.claude_hook", "agent.claude_status",
        "remote.location",
        "pane.read_text", "pane.send_text",
        "pane.list", "workspace.list",
    ]

    /// Methods whose `pane` param is forced to the scope's pane.
    static let paneMethods: Set<String> = [
        "notify", "agent.report", "agent.claude_hook", "agent.claude_status", "remote.location",
        "pane.read_text", "pane.send_text",
    ]

    /// Methods whose `workspace` param is forced to the scope's workspace.
    static let workspaceMethods: Set<String> = ["sidebar.set_status", "pane.list", "workspace.list"]

    public static func forbidden(_ message: String) -> RPCError { RPCError(code: 403, message: message) }

    /// Checks a request from a remote socket and returns its params with every target pinned to the scope.
    /// A `pane`/`workspace` naming anything else is refused (not silently redirected), so a script that tries to
    /// reach another pane learns that it cannot.
    public static func authorize(method: String, params: JSONValue?, scope: RemoteScope) throws -> JSONValue? {
        guard allowedMethods.contains(method) else {
            if method == "pane.open_file" {
                throw forbidden("cmds open is not available over an SSH connection: the file is on the server, not on this Mac "
                    + "(copy it to the Mac, e.g. with scp, and open it there)")
            }
            throw forbidden("\(method) is not available over an SSH connection (remote sockets only reach their own pane)")
        }
        var object: [String: JSONValue]
        switch params {
        case nil, .null?: object = [:]
        case .object(let value)?: object = value
        default: throw RPCError.invalidParams("params must be an object")
        }
        try pin("pane", to: scope.paneID, in: &object, applies: paneMethods.contains(method))
        try pin("workspace", to: scope.workspaceID, in: &object, applies: workspaceMethods.contains(method))
        // A remote process id means nothing on the Mac (the app would watch an unrelated local process).
        if method == "agent.report" { object["pid"] = nil }
        // Only ids the methods above know; anything else (e.g. `id` of workspace.* methods) is dropped.
        object["id"] = nil
        return object.isEmpty ? nil : .object(object)
    }

    private static func pin(_ key: String, to value: String, in object: inout [String: JSONValue], applies: Bool) throws {
        switch object[key] {
        case nil, .null?:
            break
        case .string(let given)? where given == value:
            break
        case .string(let given)?:
            throw forbidden("\(key) \(given) is not reachable from this SSH pane (only \(value))")
        default:
            throw RPCError.invalidParams("\(key) must be a string")
        }
        object[key] = applies ? .string(value) : nil
    }

    /// Removes everything outside the scope from a result: other workspaces and panes, layout, paths of the app.
    public static func filterResult(method: String, result: JSONValue?, scope: RemoteScope) -> JSONValue? {
        switch method {
        case "workspace.list":
            guard case .array(let workspaces)? = result else { return result }
            return .array(workspaces.compactMap { workspace -> JSONValue? in
                guard case .object(var object) = workspace, object["id"]?.stringValue == scope.workspaceID else { return nil }
                if case .array(let panes)? = object["panes"] {
                    object["panes"] = .array(panes.filter { $0["id"]?.stringValue == scope.paneID })
                }
                object["layout"] = nil
                return .object(object)
            })
        case "pane.list":
            guard case .array(let panes)? = result else { return result }
            return .array(panes.filter { $0["id"]?.stringValue == scope.paneID })
        case "system.identify":
            guard case .object(let object)? = result else { return result }
            return .object(object.filter { ["version", "build"].contains($0.key) })
        default:
            return result
        }
    }
}

/// Builds the command an SSH pane runs (docs/SSH.md): the user's own `ssh` (so `~/.ssh/config`, agents, jump hosts
/// and keys apply) with the pane's API socket forwarded to a fresh remote Unix socket, and a one-line bootstrap that
/// exports `CMDS_SOCKET_PATH`/`CMDS_PANE_ID`/`CMDS_WORKSPACE_ID` before starting the remote login shell.
///
/// The bootstrap is the remote command instead of `SetEnv`, which needs `AcceptEnv` on the server (Debian/Ubuntu only
/// accept `LANG LC_*`). It is a single line without `'`, `\` or `!`, wrapped in single quotes, so sh, bash, zsh,
/// fish and tcsh (whatever runs the remote command) all pass it to `sh -c` unchanged.
public struct SSHLaunch: Sendable, Equatable, Codable {
    public var host: String
    public var remoteCwd: String?

    public init(host: String, remoteCwd: String? = nil) throws {
        self.host = try Self.validateHost(host)
        self.remoteCwd = try Self.validateRemoteCwd(remoteCwd)
    }

    public struct InvalidInput: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    /// `host`, `user@host`, an `~/.ssh/config` alias or an `ssh://user@host:port` URI. Never an option (`-…`).
    public static func validateHost(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw InvalidInput(description: "host is empty") }
        guard !host.hasPrefix("-") else { throw InvalidInput(description: "host must not start with '-'") }
        guard host.count <= 255 else { throw InvalidInput(description: "host is too long") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]%/+")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw InvalidInput(description: "host may only contain letters, digits and . _ - @ : [ ] % / +")
        }
        return host
    }

    /// Absolute path or `~/…`. No quotes, backslashes or control characters (the bootstrap passes it through the
    /// remote user's shell, which may be fish or tcsh). Empty means the remote home directory.
    public static func validateRemoteCwd(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        guard path.count <= 1024 else { throw InvalidInput(description: "remote directory is too long") }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || "'\\\"`".unicodeScalars.contains($0) }) else {
            throw InvalidInput(description: "remote directory must not contain quotes, backslashes or control characters")
        }
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            throw InvalidInput(description: "remote directory must be absolute or start with ~/")
        }
        return path
    }

    /// Short label for the sidebar: `ssh home`.
    public var label: String { "ssh \(host)" }

    /// A fresh path for each connection: the server leaves the socket file behind when the connection drops, and a
    /// reused path would make the next forward fail (`StreamLocalBindUnlink` is a server option, default no).
    /// 96 random bits; the bootstrap also checks the socket is owned by the remote user before using it.
    public static func makeRemoteSocketPath() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return "/tmp/cmds-" + bytes.map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    /// The remote bootstrap (runs under `sh -c` on the server):
    /// 1. use the forwarded socket only if it exists and belongs to us, else drop `CMDS_SOCKET_PATH`;
    /// 2. fall back to `TERM=xterm-256color` when the server has no `xterm-ghostty` terminfo;
    /// 3. `cd` to the requested directory; 4. start the login shell; 5. remove the socket file afterwards.
    public static let bootstrapScript = [
        #"s="$CMDS_SOCKET_PATH""#,
        #"[ -S "$s" ] || sleep 1"#,
        #"if [ -S "$s" ] && [ -O "$s" ]; then export CMDS_SOCKET_PATH; else unset CMDS_SOCKET_PATH; s=""; echo "cmds: socket forwarding unavailable on this server; cmds-remote.sh is disabled in this shell" >&2; fi"#,
        #"if [ "$TERM" = xterm-ghostty ]; then infocmp xterm-ghostty >/dev/null 2>&1 || { TERM=xterm-256color; export TERM; }; fi"#,
        #"d="$CMDS_REMOTE_CWD"; unset CMDS_REMOTE_CWD"#,
        #"case "$d" in "~") d="$HOME";; "~/"*) d="$HOME${d#"~"}";; esac"#,
        #"if [ -n "$d" ]; then cd "$d" 2>/dev/null || echo "cmds: cannot cd to $d" >&2; fi"#,
        #""${SHELL:-/bin/sh}" -l"#,
        #"rc=$?"#,
        #"if [ -n "$s" ]; then rm -f "$s"; fi"#,
        #"exit $rc"#,
    ].joined(separator: "; ")

    /// The command line the remote user's shell runs.
    public func remoteCommand(paneID: String, workspaceID: String, remoteSocket: String) -> String {
        var assignments = [
            "CMDS_SOCKET_PATH=\(remoteSocket)",
            "CMDS_PANE_ID=\(paneID)",
            "CMDS_WORKSPACE_ID=\(workspaceID)",
        ]
        if let remoteCwd { assignments.append("CMDS_REMOTE_CWD=\(remoteCwd)") }
        return (["exec", "env"] + assignments.map(Self.singleQuoted) + ["sh", "-c", Self.singleQuoted(Self.bootstrapScript)])
            .joined(separator: " ")
    }

    /// `ssh` arguments (after the program name).
    public func arguments(paneID: String, workspaceID: String, localSocket: String, remoteSocket: String) -> [String] {
        [
            "-t",
            "-o", "StreamLocalBindUnlink=yes",
            "-R", "\(remoteSocket):\(localSocket)",
            "--", host,
            remoteCommand(paneID: paneID, workspaceID: workspaceID, remoteSocket: remoteSocket),
        ]
    }

    /// The local command line for the terminal. libghostty runs it as `bash -c "exec -l <command>"`, so it must
    /// start with the program (no `exec` of its own).
    public func localCommand(paneID: String, workspaceID: String, localSocket: String, remoteSocket: String,
                             ssh: String = "ssh") -> String {
        ([Self.singleQuoted(ssh)]
            + arguments(paneID: paneID, workspaceID: workspaceID, localSocket: localSocket, remoteSocket: remoteSocket)
            .map(Self.singleQuoted)).joined(separator: " ")
    }

    /// POSIX single quoting (`'` becomes `'\''`).
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Read-only parse of `~/.ssh/config` (and its `Include`s) for host completion: the literal names of `Host` lines.
/// Patterns (`*`, `?`, `!negated`) are skipped; nothing is ever written.
public enum SSHConfigHosts {
    public static func parse(_ text: String) -> (hosts: [String], includes: [String]) {
        var hosts: [String] = []
        var includes: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let keywordEnd = line.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? line.endIndex
            let keyword = line[..<keywordEnd].lowercased()
            var rest = line[keywordEnd...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let values = words(rest)
            switch keyword {
            case "host":
                hosts += values.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            case "include":
                includes += values
            default:
                break
            }
        }
        return (hosts, includes)
    }

    /// Hosts from `~/.ssh/config` and the files it includes (relative paths are under `~/.ssh`), in file order,
    /// without duplicates.
    public static func load(home: String = NSHomeDirectory(), maxFiles: Int = 32) -> [String] {
        let sshDirectory = (home as NSString).appendingPathComponent(".ssh")
        var queue = [(sshDirectory as NSString).appendingPathComponent("config")]
        var visited = Set<String>()
        var result: [String] = []
        var seen = Set<String>()
        while let path = queue.first, visited.count < maxFiles {
            queue.removeFirst()
            guard visited.insert(path).inserted,
                  let data = FileManager.default.contents(atPath: path), data.count < 1_000_000 else { continue }
            let parsed = parse(String(decoding: data, as: UTF8.self))
            for host in parsed.hosts where seen.insert(host).inserted { result.append(host) }
            for include in parsed.includes {
                var pattern = include
                if pattern.hasPrefix("~/") { pattern = (home as NSString).appendingPathComponent(String(pattern.dropFirst(2))) }
                if !pattern.hasPrefix("/") { pattern = (sshDirectory as NSString).appendingPathComponent(pattern) }
                queue += glob(pattern)
            }
        }
        return result
    }

    private static func glob(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard Darwin.glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_matchc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }.sorted()
    }

    /// Splits on whitespace, honouring double quotes.
    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if (character == " " || character == "\t") && !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
