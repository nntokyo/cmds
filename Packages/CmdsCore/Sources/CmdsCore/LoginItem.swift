import Foundation

/// Open cmds at login (#451): what `app.login_item` reports.
public enum LoginItemStatus: String, Codable, Sendable {
    case on
    case off
    /// Registered, but switched off in System Settings › General › Login Items.
    case needsApproval
    /// This copy cannot be a login item (not in an Applications folder, or the system refused).
    case unavailable
}

/// Result of `app.login_item`.
public struct LoginItemState: Codable, Equatable, Sendable {
    public var status: LoginItemStatus
    /// Why it is `unavailable` or `needsApproval`, in English.
    public var problem: String?

    public init(status: LoginItemStatus, problem: String? = nil) {
        self.status = status
        self.problem = problem
    }

    private enum CodingKeys: String, CodingKey { case status, problem }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(LoginItemStatus.self, forKey: .status)) ?? .unavailable
        problem = c.lenientString(.problem)
    }

    /// `on`, `off`, `needs approval: …`, `unavailable: …` (`cmds launch-at-login`).
    public var summary: String {
        switch status {
        case .on: return "on"
        case .off: return "off"
        case .needsApproval: return "needs approval: " + (problem ?? LoginItemPolicy.approvalHint)
        case .unavailable: return "unavailable" + (problem.map { ": " + $0 } ?? "")
        }
    }
}

public enum LoginItemPolicy {
    public static let approvalHint = "turn cmds on in System Settings › General › Login Items"
    public static let notInApplications = "move cmds to an Applications folder first (this copy may go away)"

    /// Only a copy in `/Applications` or `~/Applications` (or a folder in them) is made a login item: one in a DMG, a
    /// download or build folder would leave the login item pointing at nothing.
    public static func isInApplicationsFolder(_ appPath: String, home: String) -> Bool {
        let path = (appPath as NSString).standardizingPath
        guard path.hasSuffix(".app") else { return false }
        let roots = ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        return roots.contains { path.hasPrefix($0 + "/") }
    }
}
