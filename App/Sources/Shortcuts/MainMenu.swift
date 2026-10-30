import AppKit
import CmdsCore

/// Builds the main menu. Shortcuts are listed in docs/reference/shortcuts.md.
@MainActor
enum MainMenu {
    static func build(router: CommandRouter) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(router)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(router)))
        main.addItem(submenu(paneMenu(router)))
        main.addItem(submenu(workspaceMenu(router)))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu(router)
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        #if DEBUG
        main.addItem(submenu(debugMenu(router)))
        #endif
        return main
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "cmds")
        menu.addItem(item("About cmds", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Install Command Line Tool…", #selector(CLIInstaller.installCommandLineTool(_:)), "", target: CLIInstaller.shared))
        menu.addItem(.separator())
        SyncMenuActions.items().forEach(menu.addItem)
        menu.addItem(.separator())
        KeepAwakeManager.items().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(submenu(AppLanguage.menu()))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide cmds", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Quit cmds", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    private static func fileMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item("New Workspace", #selector(CommandRouter.newWorkspace(_:)), "n", target: router))
        menu.addItem(item("New SSH Workspace…", #selector(CommandRouter.newSSHWorkspace(_:)), "n", [.command, .shift], target: router))
        menu.addItem(item("Open Browser Split", #selector(CommandRouter.openBrowser(_:)), "b", [.command, .shift], target: router))
        menu.addItem(item("Open in Preview…", #selector(CommandRouter.openInPreview(_:)), "o", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Export Workspaces…", #selector(CommandRouter.exportWorkspaces(_:)), "", target: router))
        menu.addItem(item("Import Workspaces…", #selector(CommandRouter.importWorkspaces(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", #selector(CommandRouter.closePane(_:)), "w", target: router))
        menu.addItem(item("Close Workspace", #selector(CommandRouter.closeWorkspace(_:)), "w", [.command, .shift], target: router))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item("Toggle Sidebar", #selector(CommandRouter.toggleSidebar(_:)), "b", target: router))
        menu.addItem(item("Compact Sidebar", #selector(CommandRouter.toggleCompactSidebar(_:)), "s", [.command, .control], target: router))
        menu.addItem(item("Filter Workspaces", #selector(CommandRouter.filterWorkspaces(_:)), "f", [.command, .option], target: router))
        menu.addItem(item("Group Workspaces by Project", #selector(CommandRouter.toggleGroupByProject(_:)), "", target: router))
        menu.addItem(item("Show CPU and Memory per Workspace", #selector(CommandRouter.toggleWorkspaceUsage(_:)), "", target: router))
        menu.addItem(item("Zoom Pane", #selector(CommandRouter.toggleZoom(_:)), "\r", [.command, .shift], target: router))
        menu.addItem(.separator())
        let resumeMenu = NSMenu(title: String(localized: "Resume Agent Sessions on Launch"))
        let modes: [(String.LocalizationValue, AgentResumeMode)] = [("Ask", .ask), ("Always", .always), ("Never", .never)]
        for (title, mode) in modes {
            let entry = item(title, #selector(CommandRouter.setAgentResumeMode(_:)), "", target: router)
            entry.representedObject = mode.rawValue
            resumeMenu.addItem(entry)
        }
        menu.addItem(submenu(resumeMenu))
        menu.addItem(.separator())
        menu.addItem(item("Focus Address Bar", #selector(CommandRouter.browserFocusAddress(_:)), "l", target: router))
        menu.addItem(item("Reload Page", #selector(CommandRouter.browserReload(_:)), "r", target: router))
        menu.addItem(item("Back", #selector(CommandRouter.browserBack(_:)), "[", target: router))
        menu.addItem(item("Forward", #selector(CommandRouter.browserForward(_:)), "]", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func paneMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Pane"))
        menu.addItem(item("Split Right", #selector(CommandRouter.splitRight(_:)), "d", target: router))
        menu.addItem(item("Split Down", #selector(CommandRouter.splitDown(_:)), "d", [.command, .shift], target: router))
        menu.addItem(.separator())
        let arrows: [(String.LocalizationValue, Int, Selector)] = [
            ("Focus Left", NSLeftArrowFunctionKey, #selector(CommandRouter.focusLeft(_:))),
            ("Focus Right", NSRightArrowFunctionKey, #selector(CommandRouter.focusRight(_:))),
            ("Focus Up", NSUpArrowFunctionKey, #selector(CommandRouter.focusUp(_:))),
            ("Focus Down", NSDownArrowFunctionKey, #selector(CommandRouter.focusDown(_:))),
        ]
        for (title, key, action) in arrows {
            menu.addItem(item(title, action, String(Character(UnicodeScalar(key)!)), [.command, .option], target: router))
        }
        menu.addItem(.separator())
        menu.addItem(item("Jump to Latest Attention", #selector(CommandRouter.jumpToAttention(_:)), "u", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Resume Agent Session", #selector(CommandRouter.resumeAgentSession(_:)), "", target: router))
        menu.addItem(item("Resume All Agent Sessions", #selector(CommandRouter.resumeAllAgentSessions(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Install Remote Helper…", #selector(CommandRouter.installRemoteHelper(_:)), "", target: router))
        return menu
    }

    private static func workspaceMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Workspace"))
        menu.addItem(item("Rename Workspace…", #selector(CommandRouter.renameWorkspace(_:)), "r", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Next Workspace", #selector(CommandRouter.nextWorkspace(_:)), "}", target: router))
        menu.addItem(item("Previous Workspace", #selector(CommandRouter.previousWorkspace(_:)), "{", target: router))
        // ⌃Tab alternates, hidden from the menu but still active as key equivalents.
        let next = item("Next Workspace", #selector(CommandRouter.nextWorkspace(_:)), "\t", [.control], target: router)
        let previous = item("Previous Workspace", #selector(CommandRouter.previousWorkspace(_:)), "\t", [.control, .shift], target: router)
        for alternate in [next, previous] {
            alternate.isHidden = true
            alternate.allowsKeyEquivalentWhenHidden = true
            menu.addItem(alternate)
        }
        menu.addItem(.separator())
        for index in 0..<9 {
            let entry = item("Workspace \(index + 1)", #selector(CommandRouter.selectWorkspace(_:)), "\(index + 1)", target: router)
            entry.tag = index
            menu.addItem(entry)
        }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", target: NSApp))
        return menu
    }

    private static func helpMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))
        menu.addItem(item("Keyboard Shortcuts", #selector(CommandRouter.showShortcuts(_:)), "?", target: router))
        return menu
    }

    #if DEBUG
    private static func debugMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Debug"))
        menu.addItem(item("Notify Another Pane", #selector(CommandRouter.debugNotifyOtherPane(_:)), "", target: router))
        menu.addItem(item("Notify Focused Pane in 3 s", #selector(CommandRouter.debugNotifyFocusedPaneLater(_:)), "", target: router))
        menu.addItem(item("Set Sidebar Status", #selector(CommandRouter.debugSetStatus(_:)), "", target: router))
        return menu
    }
    #endif

    // MARK: - Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// `title` is looked up in Localizable.xcstrings (literals at the call sites are extracted).
    private static func item(_ title: String.LocalizationValue, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
