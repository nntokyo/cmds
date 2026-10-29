import SwiftUI

/// cmds companion: mirrors workspaces and terminal screens of the cmds Mac app.
/// Launch with `-mock` to run against built-in demo data (no Mac needed).
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
