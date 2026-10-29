import Foundation
import XCTest
@testable import CmdsCore

final class RemoteAPIPolicyTests: XCTestCase {
    let scope = RemoteScope(paneID: "p7", workspaceID: "w3")

    func testRefusesMethodsOutsideTheAllowlist() {
        for method in ["browser.eval", "browser.open", "workspace.close", "workspace.create", "pane.split", "pane.close",
                       "pane.focus", "events.subscribe", "system.stats", "agent.list", "nope"] {
            XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: method, params: nil, scope: scope), method) { error in
                XCTAssertEqual((error as? RPCError)?.code, 403)
            }
        }
    }

    func testPinsPaneAndWorkspace() throws {
        let notify = try RemoteAPIPolicy.authorize(method: "notify", params: ["body": "hi"], scope: scope)
        XCTAssertEqual(notify?["pane"]?.stringValue, "p7")
        XCTAssertEqual(notify?["body"]?.stringValue, "hi")
        let status = try RemoteAPIPolicy.authorize(method: "sidebar.set_status", params: ["text": "x", "workspace": "w3"], scope: scope)
        XCTAssertEqual(status?["workspace"]?.stringValue, "w3")
        XCTAssertNil(status?["pane"])
        let read = try RemoteAPIPolicy.authorize(method: "pane.read_text", params: ["pane": "p7"], scope: scope)
        XCTAssertEqual(read?["pane"]?.stringValue, "p7")
    }

    func testRefusesOtherPanesAndWorkspaces() {
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "pane.send_text", params: ["pane": "p1", "text": "rm -rf ~\n"], scope: scope)) {
            XCTAssertEqual(($0 as? RPCError)?.code, 403)
        }
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "sidebar.set_status", params: ["workspace": "w1", "text": "x"], scope: scope)) {
            XCTAssertEqual(($0 as? RPCError)?.code, 403)
        }
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "notify", params: ["pane": 3, "body": "x"], scope: scope))
        XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: "notify", params: ["x", "y"], scope: scope))
    }

    func testDropsRemotePid() throws {
        let params = try RemoteAPIPolicy.authorize(method: "agent.report", params: ["pid": 123, "usage": [:]], scope: scope)
        XCTAssertNil(params?["pid"])
        XCTAssertEqual(params?["pane"]?.stringValue, "p7")
    }

    func testFiltersResults() {
        let workspaces: JSONValue = [
            ["id": "w1", "panes": [["id": "p1"]]],
            ["id": "w3", "panes": [["id": "p6"], ["id": "p7"]], "layout": ["pane": ["id": "p6"]]],
        ]
        let filtered = RemoteAPIPolicy.filterResult(method: "workspace.list", result: workspaces, scope: scope)
        XCTAssertEqual(filtered, [["id": "w3", "panes": [["id": "p7"]]]])
        let panes = RemoteAPIPolicy.filterResult(method: "pane.list", result: [["id": "p6"], ["id": "p7"]], scope: scope)
        XCTAssertEqual(panes, [["id": "p7"]])
        let identify = RemoteAPIPolicy.filterResult(method: "system.identify",
                                                    result: ["version": "1", "pid": 4, "socketPath": "/x"], scope: scope)
        XCTAssertEqual(identify, ["version": "1"])
    }
}

final class SSHLaunchTests: XCTestCase {
    func testValidatesHost() throws {
        XCTAssertEqual(try SSHLaunch.validateHost(" home "), "home")
        XCTAssertNoThrow(try SSHLaunch.validateHost("me@example.com"))
        XCTAssertNoThrow(try SSHLaunch.validateHost("ssh://me@[::1]:2222"))
        for bad in ["", "-oProxyCommand=evil", "a b", "h;rm", "h'x", "h\nx", "h$(x)"] {
            XCTAssertThrowsError(try SSHLaunch.validateHost(bad), bad)
        }
    }

    func testValidatesRemoteCwd() throws {
        XCTAssertNil(try SSHLaunch.validateRemoteCwd("  "))
        XCTAssertEqual(try SSHLaunch.validateRemoteCwd("~/src/my app"), "~/src/my app")
        for bad in ["relative", "/a'b", "/a\\b", "/a\nb", "/a\"b"] {
            XCTAssertThrowsError(try SSHLaunch.validateRemoteCwd(bad), bad)
        }
    }

    func testBootstrapSurvivesAnyRemoteShellQuoting() {
        let script = SSHLaunch.bootstrapScript
        XCTAssertFalse(script.contains("'"))
        XCTAssertFalse(script.contains("\\"))
        XCTAssertFalse(script.contains("!"))
        XCTAssertFalse(script.contains("\n"))
    }

    func testRemoteSocketPathsAreFresh() {
        let first = SSHLaunch.makeRemoteSocketPath()
        XCTAssertTrue(first.hasPrefix("/tmp/cmds-") && first.hasSuffix(".sock"))
        XCTAssertNotEqual(first, SSHLaunch.makeRemoteSocketPath())
    }

    func testArguments() throws {
        let launch = try SSHLaunch(host: "home", remoteCwd: "~/src")
        let args = launch.arguments(paneID: "p2", workspaceID: "w1", localSocket: "/L/p2.sock", remoteSocket: "/tmp/cmds-x.sock")
        XCTAssertEqual(Array(args.prefix(7)), ["-t", "-o", "StreamLocalBindUnlink=yes", "-R", "/tmp/cmds-x.sock:/L/p2.sock", "--", "home"])
        XCTAssertEqual(args.count, 8)
        XCTAssertTrue(args[7].hasPrefix("exec env 'CMDS_SOCKET_PATH=/tmp/cmds-x.sock' 'CMDS_PANE_ID=p2' 'CMDS_WORKSPACE_ID=w1' 'CMDS_REMOTE_CWD=~/src' sh -c '"))
    }

    /// Runs the remote command through a real `sh` (as sshd would through the login shell) with a fake shell.
    func testBootstrapRunsShellInDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-bootstrap-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeShell = directory.appendingPathComponent("fakeshell")
        try "#!/bin/sh\necho \"cwd=$(pwd) pane=$CMDS_PANE_ID sock=${CMDS_SOCKET_PATH:-none} args=$*\"\n"
            .write(to: fakeShell, atomically: true, encoding: .utf8)
        chmod(fakeShell.path, 0o755)
        let launch = try SSHLaunch(host: "h", remoteCwd: directory.path)
        let command = launch.remoteCommand(paneID: "p9", workspaceID: "w9", remoteSocket: directory.appendingPathComponent("missing.sock").path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["SHELL": fakeShell.path, "HOME": directory.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let resolved = (directory.path as NSString).resolvingSymlinksInPath
        XCTAssertTrue(text.contains("pane=p9"), text)
        XCTAssertTrue(text.contains("sock=none"), text) // no socket owned by us: not exported
        XCTAssertTrue(text.contains("args=-l"), text)
        XCTAssertTrue(text.contains("cwd=\(resolved)") || text.contains("cwd=\(directory.path)"), text)
    }
}

final class SSHConfigHostsTests: XCTestCase {
    func testParsesHostsAndIncludes() {
        let parsed = SSHConfigHosts.parse("""
            # comment
            Host home nas
              HostName 10.0.0.2
            Host *.internal !bad
            host=work
            Include config.d/* "~/other conf"
            Match host x
            """)
        XCTAssertEqual(parsed.hosts, ["home", "nas", "work"])
        XCTAssertEqual(parsed.includes, ["config.d/*", "~/other conf"])
    }

    func testLoadFollowsIncludes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-sshcfg-\(UUID().uuidString.prefix(8))")
        let ssh = home.appendingPathComponent(".ssh/config.d")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Include config.d/*\nHost a\n".write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try "Host b a\n".write(to: ssh.appendingPathComponent("x.conf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHConfigHosts.load(home: home.path), ["a", "b"])
    }
}

/// Runs `cmds-remote.sh` against an in-process socket server and checks the requests it sends.
final class RemoteHelperScriptTests: XCTestCase {
    private var directory: URL!
    private var script: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/cmds-rh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent(RemoteHelperScript.fileName)
        try RemoteHelperScript.source.write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSyntax() throws {
        let result = try run(["-n", script.path], shell: true)
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testRequestsPerTransport() throws {
        var transports = ["python3"]
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") { transports.append("nc") }
        for transport in transports {
            let (requests, outputs) = try withServer(reply: { request in
                if request.method == "pane.read_text" { return #"{"id":1,"result":{"text":"a \"q\"\nb"}}"# }
                if request.method == "pane.send_text" { return #"{"id":1,"error":{"code":403,"message":"nope"}}"# }
                return #"{"id":1,"result":{}}"#
            }) { socket in
                [
                    try run([script.path, "notify", "--title", "T", "hi \"there\"\tx"], socket: socket, transport: transport),
                    try run([script.path, "hook", "claude-status"], socket: socket, transport: transport,
                            stdin: "{\"model\": {\"id\": \"m\"},\n \"x\": 1}\n"),
                    try run([script.path, "read"], socket: socket, transport: transport),
                    try run([script.path, "send", "--enter", "ls"], socket: socket, transport: transport),
                ]
            }
            XCTAssertEqual(requests.map(\.method), ["notify", "agent.claude_status", "pane.read_text", "pane.send_text"], transport)
            XCTAssertEqual(requests[0].params?["body"]?.stringValue, "hi \"there\"\tx")
            XCTAssertEqual(requests[0].params?["title"]?.stringValue, "T")
            XCTAssertEqual(requests[1].params?["input"]?["x"]?.intValue, 1)
            XCTAssertEqual(outputs[0].status, 0, outputs[0].stderr)
            XCTAssertEqual(outputs[1].status, 0)
            XCTAssertEqual(outputs[2].stdout, "a \"q\"\nb\n", transport)
            XCTAssertEqual(outputs[3].status, 1, transport)
            XCTAssertTrue(outputs[3].stderr.contains("nope"), outputs[3].stderr)
            XCTAssertEqual(requests[3].params?["text"]?.stringValue, "ls\n")
        }
    }

    func testInstallCommand() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteHelperScript.installCommand()]
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let installed = directory.appendingPathComponent(".local/bin/cmds-remote.sh")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), RemoteHelperScript.source)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(".local/bin/cmds").path),
                       "cmds-remote.sh")
    }

    func testHooksAreSilentOutsideCmds() throws {
        let result = try run([script.path, "hook", "claude"], socket: nil, transport: "python3", stdin: "{}")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout + result.stderr, "")
        let notify = try run([script.path, "notify", "x"], socket: nil, transport: "python3")
        XCTAssertEqual(notify.status, 3)
    }

    // MARK: - Helpers

    private struct Output { var status: Int32; var stdout: String; var stderr: String }

    private func run(_ arguments: [String], socket: String? = nil, transport: String = "python3", stdin: String = "",
                     shell: Bool = false) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin", "CMDS_TRANSPORT": transport, "HOME": directory.path]
        if let socket { environment["CMDS_SOCKET_PATH"] = socket; environment["CMDS_PANE_ID"] = "p1" }
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = shell
        return Output(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                      stderr: String(decoding: err, as: UTF8.self))
    }

    /// Accepts connections on a fresh socket, records one request per connection and answers it.
    private func withServer<T>(reply: @escaping @Sendable (RPCRequest) -> String,
                               _ body: (String) throws -> T) throws -> ([RPCRequest], T) {
        let path = directory.appendingPathComponent("s.sock").path
        let fd = try UnixSocket.makeStreamSocket()
        try UnixSocket.bindAndListen(fd, path: path)

        let box = Box()
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = JSONLineBuffer()
                var lines: [Data] = []
                while lines.isEmpty, let chunk = try? UnixSocket.read(client), !chunk.isEmpty {
                    lines = (try? buffer.append(chunk)) ?? []
                }
                if let line = lines.first, let request = try? JSONDecoder().decode(RPCRequest.self, from: line) {
                    box.lock.lock(); box.requests.append(request); box.lock.unlock()
                    try? UnixSocket.writeAll(client, Data((reply(request) + "\n").utf8))
                } else if let line = lines.first {
                    box.lock.lock(); box.requests.append(RPCRequest(id: 0, method: "INVALID " + String(decoding: line, as: UTF8.self))); box.lock.unlock()
                }
                close(client)
            }
        }
        thread.start()
        defer { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }
        let result = try body(path)
        box.lock.lock(); defer { box.lock.unlock() }
        return (box.requests, result)
    }
}

private final class Box: @unchecked Sendable { var requests: [RPCRequest] = []; let lock = NSLock() }
