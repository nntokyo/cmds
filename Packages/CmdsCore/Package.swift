// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CmdsCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmdsCore", targets: ["CmdsCore"]),
        .executable(name: "cmds", targets: ["cmds-cli"]),
    ],
    targets: [
        .target(name: "CmdsCore"),
        .executableTarget(name: "cmds-cli", dependencies: ["CmdsCore"]),
        .testTarget(name: "CmdsCoreTests", dependencies: ["CmdsCore"]),
        // The CLI's text stays English whatever the language (docs/ARCHITECTURE.md "Localization").
        .testTarget(name: "CmdsCLITests", dependencies: ["cmds-cli", "CmdsCore"]),
    ]
)
