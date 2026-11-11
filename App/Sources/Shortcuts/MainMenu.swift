import AppKit
import CmdsCore

/// Builds the main menu. Shortcuts are listed in docs/reference/shortcuts.md.
@MainActor
enum MainMenu {
    static func build(router: CommandRouter) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(router)))
        main.addItem(submenu(editMenu(router)))
        main.addItem(submenu(viewMenu(router)))
        main.addItem(submenu(paneMenu(router)))
        main.addItem(submenu(workspaceMenu(router)))
        let window = windowMenu(router)
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
        menu.addItem(item("Check for Updates…", #selector(Updater.checkForUpdates(_:)), "", target: Updater.shared))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(SettingsWindowController.showSettings(_:)), ",", target: SettingsWindowController.shared))
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
        menu.addItem(item("New Worktree Workspace…", #selector(CommandRouter.newWorktreeWorkspace(_:)), "n", [.command, .option], target: router))
        menu.addItem(item("Open Browser Split", #selector(CommandRouter.openBrowser(_:)), "b", [.command, .shift], target: router))
        menu.addItem(item("Open in Preview…", #selector(CommandRouter.openInPreview(_:)), "o", [.command, .shift], target: router))
        menu.addItem(item("New Files Pane", #selector(CommandRouter.openFilesPane(_:)), "e", [.command, .shift], target: router))
        menu.addItem(item("New Remote Files Pane…", #selector(CommandRouter.openRemoteFilesPane(_:)), "e", [.command, .shift, .option], target: router))
        menu.addItem(.separator())
        menu.addItem(submenu(router.recentAgentSessions.makeMenu()))
        menu.addItem(.separator())
        menu.addItem(item("Export Workspaces…", #selector(CommandRouter.exportWorkspaces(_:)), "", target: router))
        menu.addItem(item("Import Workspaces…", #selector(CommandRouter.importWorkspaces(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", #selector(CommandRouter.closePane(_:)), "w", target: router))
        menu.addItem(item("Close Workspace", #selector(CommandRouter.closeWorkspace(_:)), "w", [.command, .shift], target: router))
        return menu
    }

    private static func editMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // The terminal's find bar (TerminalFind). The sidebar takes ⌘F itself while it has the keyboard (filter), a
        // files list ⇧⌘G (Go to Folder).
        let find = NSMenu(title: String(localized: "Find"))
        find.addItem(item("Find…", #selector(CommandRouter.find(_:)), "f", target: router))
        find.addItem(item("Find Next", #selector(CommandRouter.findNext(_:)), "g", target: router))
        find.addItem(item("Find Previous", #selector(CommandRouter.findPrevious(_:)), "g", [.command, .shift], target: router))
        menu.addItem(submenu(find))
        return menu
    }

    private static func viewMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item("Command Palette…", #selector(CommandRouter.showCommandPalette(_:)), "p", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Sidebar", #selector(CommandRouter.toggleSidebar(_:)), "b", target: router))
        menu.addItem(item("Compact Sidebar", #selector(CommandRouter.toggleCompactSidebar(_:)), "s", [.command, .control], target: router))
        menu.addItem(item("Filter Workspaces", #selector(CommandRouter.filterWorkspaces(_:)), "f", [.command, .option], target: router))
        menu.addItem(item("Group Workspaces by Project", #selector(CommandRouter.toggleGroupByProject(_:)), "", target: router))
        menu.addItem(item("Show CPU and Memory per Workspace", #selector(CommandRouter.toggleWorkspaceUsage(_:)), "", target: router))
        menu.addItem(item("Zoom Pane", #selector(CommandRouter.toggleZoom(_:)), "\r", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Tile All Workspaces", #selector(CommandRouter.toggleTileAll(_:)), "t", [.command, .control], target: router))
        menu.addItem(item("Tile Selected Workspaces", #selector(CommandRouter.tileSelected(_:)), "", target: router))
        menu.addItem(item("Show Single Workspace", #selector(CommandRouter.showSingleWorkspace(_:)), "", target: router))
        // Keyboard alternative to dragging tile headers. Not ⌃⌥⌘: window managers (Magnet) take ⌃⌥⌘←/→ for "move to display".
        let tileMoves: [(String.LocalizationValue, Int, Selector)] = [
            ("Move Tile Left", NSLeftArrowFunctionKey, #selector(CommandRouter.moveTileLeft(_:))),
            ("Move Tile Right", NSRightArrowFunctionKey, #selector(CommandRouter.moveTileRight(_:))),
            ("Move Tile Up", NSUpArrowFunctionKey, #selector(CommandRouter.moveTileUp(_:))),
            ("Move Tile Down", NSDownArrowFunctionKey, #selector(CommandRouter.moveTileDown(_:))),
        ]
        for (title, key, action) in tileMoves {
            menu.addItem(item(title, action, String(Character(UnicodeScalar(key)!)), [.control, .shift, .command],
                              target: router))
        }
        menu.addItem(.separator())
        // Text size of the focused pane (nil target: the first responder; see TextSizeActions).
        menu.addItem(item("Bigger", #selector(TextSizeActions.cmdsTextBigger(_:)), "="))
        let biggerPlus = item("Bigger", #selector(TextSizeActions.cmdsTextBigger(_:)), "+")
        biggerPlus.isHidden = true
        biggerPlus.allowsKeyEquivalentWhenHidden = true
        menu.addItem(biggerPlus)
        menu.addItem(item("Smaller", #selector(TextSizeActions.cmdsTextSmaller(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(TextSizeActions.cmdsTextActualSize(_:)), "0"))
        menu.addItem(.separator())
        let resumeMenu = NSMenu(title: String(localized: "Resume Agent Sessions on Launch"))
        let modes: [(String.LocalizationValue, AgentResumeMode)] = [("Ask", .ask), ("Always", .always), ("Never", .never)]
        for (title, mode) in modes {
            let entry = item(title, #selector(CommandRouter.setAgentResumeMode(_:)), "", target: router)
            entry.representedObject = mode.rawValue
            resumeMenu.addItem(entry)
        }
        menu.addItem(submenu(resumeMenu))
        let subagentsMenu = NSMenu(title: String(localized: "Show Subagents"))
        for display in SubagentDisplay.allCases {
            let entry = NSMenuItem(title: display.title, action: #selector(CommandRouter.setSubagentDisplay(_:)), keyEquivalent: "")
            entry.target = router
            entry.representedObject = display.rawValue
            subagentsMenu.addItem(entry)
        }
        menu.addItem(submenu(subagentsMenu))
        menu.addItem(.separator())
        menu.addItem(item("Focus Address Bar", #selector(CommandRouter.browserFocusAddress(_:)), "l", target: router))
        menu.addItem(item("Reload Page", #selector(CommandRouter.browserReload(_:)), "r", target: router))
        menu.addItem(item("Reload on File Changes", #selector(CommandRouter.browserToggleWatch(_:)), "", target: router))
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
        // Moving panes (#218): ⇧ added to the focus keys. Not ⌃⇧⌘ (Move Tile) nor ⌃⌥⌘ (window managers).
        let swaps: [(String.LocalizationValue, Int, Selector)] = [
            ("Swap with Pane Left", NSLeftArrowFunctionKey, #selector(CommandRouter.swapLeft(_:))),
            ("Swap with Pane Right", NSRightArrowFunctionKey, #selector(CommandRouter.swapRight(_:))),
            ("Swap with Pane Up", NSUpArrowFunctionKey, #selector(CommandRouter.swapUp(_:))),
            ("Swap with Pane Down", NSDownArrowFunctionKey, #selector(CommandRouter.swapDown(_:))),
        ]
        for (title, key, action) in swaps {
            menu.addItem(item(title, action, String(Character(UnicodeScalar(key)!)), [.command, .option, .shift],
                              target: router))
        }
        menu.addItem(item("Move to Workspace…", #selector(CommandRouter.moveToWorkspace(_:)), "", target: router))
        menu.addItem(item("Move to New Workspace", #selector(CommandRouter.moveToNewWorkspace(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Jump to Latest Attention", #selector(CommandRouter.jumpToAttention(_:)), "u", [.command, .shift], target: router))
        menu.addItem(.separator())
        menu.addItem(item("Resume Agent Session", #selector(CommandRouter.resumeAgentSession(_:)), "", target: router))
        menu.addItem(item("Resume All Agent Sessions", #selector(CommandRouter.resumeAllAgentSessions(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Install Remote Helper…", #selector(CommandRouter.installRemoteHelper(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(submenu(filesMenu(router)))
        return menu
    }

    /// Pane › Files: commands of the focused files pane. Its list takes F-keys, Space and Return itself; they are not
    /// menu key equivalents, which would take them away from terminal programs.
    private static func filesMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Files"))
        menu.addItem(item("Show in Preview Pane", #selector(CommandRouter.filesPreview(_:)), "", target: router))
        menu.addItem(item("Edit", #selector(CommandRouter.filesEdit(_:)), "", target: router))
        menu.addItem(item("Stop Editing", #selector(CommandRouter.filesStopEditing(_:)), "", target: router))
        menu.addItem(item("Copy to Other Pane", #selector(CommandRouter.filesCopyToOtherPane(_:)), "", target: router))
        menu.addItem(item("Move to Other Pane", #selector(CommandRouter.filesMoveToOtherPane(_:)), "", target: router))
        menu.addItem(item("Compare and Sync with Other Pane…", #selector(CommandRouter.filesCompare(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("New Folder", #selector(CommandRouter.filesNewFolder(_:)), "", target: router))
        menu.addItem(item("Rename", #selector(CommandRouter.filesRename(_:)), "", target: router))
        menu.addItem(item("Move to Trash", #selector(CommandRouter.filesMoveToTrash(_:)), "", target: router))
        menu.addItem(.separator())
        menu.addItem(item("Enclosing Folder", #selector(CommandRouter.filesEnclosingFolder(_:)), "", target: router))
        menu.addItem(item("Go to Folder…", #selector(CommandRouter.filesGoToFolder(_:)), "", target: router))
        menu.addItem(item("Show Hidden Files", #selector(CommandRouter.filesToggleHidden(_:)), "", target: router))
        menu.addItem(item("Follow Terminal", #selector(CommandRouter.filesToggleFollow(_:)), "", target: router))
        menu.addItem(item("Open Terminal Here", #selector(CommandRouter.filesOpenTerminal(_:)), "", target: router))
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

    private static func windowMenu(_ router: CommandRouter) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Schedules…", #selector(SchedulesWindowController.showSchedules(_:)), "", target: SchedulesWindowController.shared))
        menu.addItem(item("Transfers", #selector(CommandRouter.showTransfers(_:)), "t", [.command, .option], target: router))
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
