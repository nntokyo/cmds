import Foundation
import XCTest
@testable import CmdsCore

/// Port forwards the user started with `ssh -L` (#174 G24).
final class PortForwardTests: XCTestCase {
    func testParseCommandLines() {
        var parsed = PortForward.parse(sshArguments: ["-N", "-L", "15173:localhost:5173", "dev"])
        XCTAssertEqual(parsed.destination, "dev")
        XCTAssertEqual(parsed.forwards, [PortForward(localPort: 15173, remoteHost: "localhost", remotePort: 5173)])

        parsed = PortForward.parse(sshArguments: ["-fNL127.0.0.1:3000:127.0.0.1:3000", "-p", "2222", "-i", "key",
                                                  "-o", "LocalForward=8080 [::1]:80", "me@box.example", "uptime", "-L", "1:a:2"])
        XCTAssertEqual(parsed.destination, "me@box.example")
        XCTAssertEqual(parsed.forwards, [PortForward(localPort: 3000, remoteHost: "127.0.0.1", remotePort: 3000),
                                         PortForward(localPort: 8080, remoteHost: "::1", remotePort: 80)],
                       "options after the destination belong to the remote command")

        parsed = PortForward.parse(sshArguments: ["-D", "1080", "-L", "/tmp/s:/tmp/r", "-R", "9000:localhost:9000", "h"])
        XCTAssertEqual(parsed.destination, "h")
        XCTAssertEqual(parsed.forwards, [], "dynamic, Unix-socket and remote forwards are not local ports")
        XCTAssertNil(PortForward.parse(sshArguments: ["-v"]).destination)
    }

    func testConfigLines() {
        XCTAssertEqual(PortForward.parse(configLine: "5173 localhost:5173"),
                       PortForward(localPort: 5173, remoteHost: "localhost", remotePort: 5173))
        XCTAssertEqual(PortForward.parse(configLine: "[127.0.0.1]:4000 [::1]:4000"),
                       PortForward(localPort: 4000, remoteHost: "::1", remotePort: 4000))
        XCTAssertNil(PortForward.parse(configLine: "5173"))
        XCTAssertNil(PortForward.parse(configLine: "99999 localhost:1"))
    }

    func testHostNames() {
        XCTAssertEqual(PortForward.hostName(ofDestination: "me@Box.example"), "box.example")
        XCTAssertEqual(PortForward.hostName(ofDestination: "ssh://me@box:2222"), "box")
        XCTAssertEqual(PortForward.hostName(ofDestination: "dev"), "dev")
    }

    func testLocalURL() {
        let forwards = [PortForward(localPort: 15173, remoteHost: "localhost", remotePort: 5173),
                        PortForward(localPort: 9000, remoteHost: "db.internal", remotePort: 3000)]
        XCTAssertEqual(PortForward.localURL(for: "http://localhost:5173/app?x=1#top", through: forwards)?.absoluteString,
                       "http://localhost:15173/app?x=1#top")
        XCTAssertEqual(PortForward.localURL(for: "http://127.0.0.1:5173/", through: forwards)?.absoluteString,
                       "http://localhost:15173/")
        XCTAssertNil(PortForward.localURL(for: "http://localhost:3000/", through: forwards),
                     "the 3000 forward goes to another host, not the server's own localhost")
        XCTAssertNil(PortForward.localURL(for: "http://example.com:5173/", through: forwards))
        XCTAssertNil(PortForward.localURL(for: "ftp://localhost:5173/", through: forwards))
        XCTAssertEqual(PortForward.serverPort(of: "http://localhost/"), 80)
        XCTAssertEqual(PortForward.serverPort(of: "http://[::1]:8080/"), 8080)
        XCTAssertNil(PortForward.serverPort(of: "https://github.com/"))
    }
}
