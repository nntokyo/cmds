// swift-tools-version: 5.10
import PackageDescription

// SSH tunnel for the iOS companion's remote access (docs/internals/sync-protocol.md "Remote access via SSH"). Kept out of
// CmdsCore so the Mac app and the `cmds` CLI do not link SwiftNIO; only the companion depends on it.
let package = Package(
    name: "CmdsSSH",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmdsSSH", targets: ["CmdsSSH"]),
    ],
    dependencies: [
        .package(path: "../CmdsCore"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "CmdsSSH", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "CmdsSSHTests", dependencies: [
            "CmdsSSH",
            .product(name: "CmdsCore", package: "CmdsCore"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
