import Foundation
import ServiceManagement
import CmdsCore

/// Settings › General › Open cmds at login (#451), through `SMAppService.mainApp`. Off unless someone turns it on.
/// An isolated instance (`CMDS_SUPPORT_DIR`) never touches the Mac's login items: it keeps the choice in memory, so a
/// test changes nothing (as `AgentResumeSettings` does).
@MainActor
enum LoginItem {
    private static var isolatedOn = false

    private static var isIsolated: Bool { CmdsEnv.supportDirectoryOverride() != nil }

    static var state: LoginItemState {
        if isIsolated { return LoginItemState(status: isolatedOn ? .on : .off) }
        switch SMAppService.mainApp.status {
        case .enabled: return LoginItemState(status: .on)
        case .requiresApproval: return LoginItemState(status: .needsApproval, problem: LoginItemPolicy.approvalHint)
        case .notRegistered: return LoginItemState(status: .off)
        case .notFound: return LoginItemState(status: unavailableReason == nil ? .off : .unavailable, problem: unavailableReason)
        @unknown default: return LoginItemState(status: .off)
        }
    }

    /// Why this copy cannot be a login item (nil: it can).
    static var unavailableReason: String? {
        if isIsolated { return nil }
        let ok = LoginItemPolicy.isInApplicationsFolder(Bundle.main.bundlePath, home: NSHomeDirectory())
        return ok ? nil : LoginItemPolicy.notInApplications
    }

    /// Turns it on or off; throws (English) when this copy cannot be one or the system refuses.
    static func set(_ on: Bool) throws {
        if isIsolated {
            isolatedOn = on
            return
        }
        if on {
            if let reason = unavailableReason { throw RPCError.invalidParams(reason) }
            guard SMAppService.mainApp.status != .enabled else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Registered but not allowed: the user switches it on in System Settings.
                if SMAppService.mainApp.status == .requiresApproval { return }
                throw RPCError.invalidParams("could not add cmds to the login items: \(error.localizedDescription)")
            }
        } else {
            guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw RPCError.invalidParams("could not remove cmds from the login items: \(error.localizedDescription)")
            }
        }
    }
}
