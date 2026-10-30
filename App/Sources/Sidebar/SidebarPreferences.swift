import Foundation

enum SidebarPreferences {
    /// View › Show CPU and Memory per Workspace (off by default; the footer shows the Mac's totals).
    static var showsWorkspaceUsage: Bool {
        get { UserDefaults.standard.bool(forKey: "SidebarShowsWorkspaceUsage") }
        set { UserDefaults.standard.set(newValue, forKey: "SidebarShowsWorkspaceUsage") }
    }
}
