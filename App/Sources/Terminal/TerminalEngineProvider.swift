import AppKit

@MainActor
enum TerminalEngineProvider {
    static let shared: TerminalEngine = GhosttyTerminalEngine()
}
