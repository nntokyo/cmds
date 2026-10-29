#if CMDS_GHOSTTY_HARNESS
// Standalone debug harness for the libghostty engine. Not compiled normally; build with
//   SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'
// Opens one window with a terminal surface. Env CMDS_HARNESS_SEND="text" (or CMDS_HARNESS_SEND_FILE=path)
// sends text after 1.5s, CMDS_HARNESS_TYPE_FILE=path types text (typeText) after 2.5s
// (literal \e \n \r \t \xNN are decoded),
// CMDS_HARNESS_ACTION="scroll_page_lines:-2" runs a libghostty binding action after 3s,
// CMDS_HARNESS_DUMP=/path writes cursorPosition + numbered visibleText() lines to that file after 3.5s.
import AppKit
import GhosttyKit

@main
@MainActor
final class GhosttyHarnessApp: NSObject, NSApplicationDelegate, TerminalSurfaceDelegate {
    private var window: NSWindow?
    private var surface: TerminalSurface?

    static func main() {
        let app = NSApplication.shared
        let delegate = GhosttyHarnessApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(GhosttySurfaceView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(GhosttySurfaceView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        let shellItem = NSMenuItem()
        mainMenu.addItem(shellItem)
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New (harness log)", action: #selector(newThing(_:)), keyEquivalent: "n").target = self
        shellItem.submenu = shellMenu
        NSApp.mainMenu = mainMenu

        let env = ProcessInfo.processInfo.environment
        var config = TerminalLaunchConfig()
        config.workingDirectory = NSHomeDirectory()
        config.environment = ["CMDS_PANE_ID": "p1", "CMDS_WORKSPACE_ID": "w1"]
        let surface = TerminalEngineProvider.shared.makeSurface(config: config)
        surface.delegate = self
        self.surface = surface

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "cmds ghostty harness"
        window.contentView = surface.view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        surface.focus()

        // Literal \e, \n, \r, \t and \xNN in the input are decoded so control input can be tested.
        func decode(_ raw: String) -> String {
            var text = raw.replacingOccurrences(of: "\\e", with: "\u{1b}")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
            while let r = text.range(of: #"\\x[0-9A-Fa-f]{2}"#, options: .regularExpression),
                  let byte = UInt8(text[r].dropFirst(2), radix: 16) {
                text.replaceSubrange(r, with: String(UnicodeScalar(byte)))
            }
            return text
        }
        let sendFromFile = env["CMDS_HARNESS_SEND_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        if let raw = sendFromFile ?? env["CMDS_HARNESS_SEND"] {
            let text = decode(raw)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.surface?.sendText(text) }
            }
        }
        if let raw = env["CMDS_HARNESS_TYPE_FILE"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
            let text = decode(raw)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated { self.surface?.typeText(text) }
            }
        }
        if let action = env["CMDS_HARNESS_ACTION"] {
            // A libghostty binding action run before the dump, e.g. "scroll_page_lines:-2".
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                MainActor.assumeIsolated {
                    guard let gs = (self.surface?.view as? GhosttySurfaceView)?.surface else { return }
                    _ = action.withCString { ghostty_surface_binding_action(gs, $0, UInt(action.utf8.count)) }
                }
            }
        }
        if let path = env["CMDS_HARNESS_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                MainActor.assumeIsolated {
                    let s = self.surface
                    let grid = s?.gridSize.map { "\($0.rows) rows x \($0.cols) cols" } ?? "nil"
                    let cursor = s?.cursorPosition.map { "row \($0.row) col \($0.col)" } ?? "nil"
                    let lines = (s?.visibleText() ?? "").components(separatedBy: "\n")
                    let numbered = lines.enumerated().map { String(format: "%02d|", $0.offset) + $0.element }
                    let out = "TITLE: \(s?.title ?? "")\nPWD: \(s?.workingDirectory ?? "")\nGRID: \(grid)\n"
                        + "CURSOR: \(cursor)\nVISIBLE LINES: \(lines.count)\n--- visible ---\n"
                        + numbered.joined(separator: "\n")
                        + "\n--- scrollback(5) ---\n" + (s?.scrollbackText(maxLines: 5) ?? "")
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    @objc func newThing(_ sender: Any?) { NSLog("harness: menu ⌘N reached the app shell") }

    func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String) { window?.title = title }
    func terminalSurface(_ surface: TerminalSurface, didChangeWorkingDirectory path: String) { NSLog("harness: pwd \(path)") }
    func terminalSurfaceDidRingBell(_ surface: TerminalSurface) { NSLog("harness: bell") }
    func terminalSurface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {
        NSLog("harness: notification \(title): \(body)")
    }
    func terminalSurfaceDidBecomeFocused(_ surface: TerminalSurface) { NSLog("harness: focused") }
    func terminalSurfaceDidClose(_ surface: TerminalSurface) {
        NSLog("harness: closed")
        NSApp.terminate(nil)
    }
}
#endif
