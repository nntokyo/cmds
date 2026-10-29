import SwiftUI

/// cmds companion: mirrors workspaces and terminal screens of the cmds Mac app.
/// Launch with `-mock` to run against built-in demo data (no Mac needed); add `-mockFullScreenTUI` to make the
/// Claude pane a large full-screen TUI screen (used by `TerminalScreenTests`).
@main
struct CompanionApp: App {
    @State private var client = CompanionClient.live()
    @State private var browser = MacBrowser()
    @Environment(\.scenePhase) private var scenePhase

    static let isMock = ProcessInfo.processInfo.arguments.contains("-mock")

    init() {
        AttentionNotifier.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .environment(browser)
                .onAppear {
                    guard client.target == nil else { return }
                    if Self.isMock {
                        client.connect(to: .mock)
                    } else if let last = RecentMacs.load().first {
                        client.connect(to: last)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            client.isAppActive = phase == .active
            if phase == .active { client.resumeIfNeeded() }
        }
    }
}
