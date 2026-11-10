import Foundation

/// Params of `pane.move` (#218, docs/reference/api.md): `pane`, and where it goes: `beside` another pane (on `side`,
/// default right), into `workspace` (beside its focused pane), or `newWorkspace`. `focus` (default true): the moved
/// pane takes the keyboard and its workspace is shown.
public struct PaneMoveRequest: Equatable, Sendable {
    public var pane: String
    public var workspace: String?
    public var beside: String?
    public var side: PaneSide
    public var newWorkspace: Bool
    public var focus: Bool

    public init(pane: String, workspace: String? = nil, beside: String? = nil, side: PaneSide = .right,
                newWorkspace: Bool = false, focus: Bool = true) {
        self.pane = pane
        self.workspace = workspace
        self.beside = beside
        self.side = side
        self.newWorkspace = newWorkspace
        self.focus = focus
    }

    public init(params: JSONValue?) throws {
        let params = RequestParams(params)
        guard let pane = try params.string("pane"), !pane.isEmpty else { throw RPCError.invalidParams("missing param: pane") }
        let side = try params.string("side").map { raw -> PaneSide in
            guard let side = PaneSide(rawValue: raw) else {
                throw RPCError.invalidParams("side must be \"left\", \"right\", \"top\" or \"bottom\"")
            }
            return side
        }
        self.init(pane: pane, workspace: try params.string("workspace"), beside: try params.string("beside"),
                  side: side ?? .right, newWorkspace: try params.bool("newWorkspace") ?? false,
                  focus: try params.bool("focus") ?? true)
        if newWorkspace {
            guard workspace == nil, beside == nil, side == nil else {
                throw RPCError.invalidParams("newWorkspace cannot be combined with workspace, beside or side")
            }
        } else if workspace == nil, beside == nil {
            throw RPCError.invalidParams("give workspace, beside or newWorkspace")
        }
        if beside == pane { throw RPCError.invalidParams("a pane cannot be moved beside itself") }
    }
}
