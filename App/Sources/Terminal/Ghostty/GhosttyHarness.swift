#if CMDS_GHOSTTY_HARNESS
// Standalone debug harness for the libghostty engine. Not compiled normally; build with
//   SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'
// Opens one window with a terminal surface. Env CMDS_HARNESS_SEND="text" types text after 1s,
// CMDS_HARNESS_DUMP=/path writes visibleText() to that file after 3s.
import AppKit

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

        if let text = env["CMDS_HARNESS_SEND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self.surface?.sendText(text) }
            }
        }
        if let path = env["CMDS_HARNESS_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                MainActor.assumeIsolated {
                    let s = self.surface
                    let out = "TITLE: \(s?.title ?? "")\nPWD: \(s?.workingDirectory ?? "")\n--- visible ---\n"
                        + (s?.visibleText() ?? "") + "\n--- scrollback(5) ---\n" + (s?.scrollbackText(maxLines: 5) ?? "")
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
