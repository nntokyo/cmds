#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.files` / `debug.files_snapshot`, docs/internals/testing.md): drive a files pane without UI
/// scripting.
extension FilesPane {
    /// `state` (default) reports; `select` (names), `copyToOther`, `moveToOther`, `newFolder`, `rename` (name,
    /// newName), `paste` (paths, move; `host:/path` for remote items), `trash`, `reload` (also Connect), `goto` (path),
    /// `hidden` (on), `follow` (on), `preview`, `terminal`, `back`, `forward`, `up`. `conflict` answers
    /// name conflicts of later operations without asking (keepBoth, replace, skip, stop).
    func debugPerform(_ params: JSONValue?) throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "state"
        if let raw = params?["conflict"]?.stringValue {
            let answers: [String: FileOperation.Resolution] = ["keepBoth": .keepBoth, "replace": .replace, "skip": .skip, "stop": .stop]
            guard let answer = answers[raw] else { throw RPCError.invalidParams("conflict must be keepBoth, replace, skip or stop") }
            debugConflictAnswer = answer
        }
        switch action {
        case "state": break
        case "select": selectNames((params?["names"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "copyToOther": copyToOtherPane()
        case "moveToOther": moveToOtherPane()
        case "newFolder": newFolder()
        case "rename":
            guard let name = params?["name"]?.stringValue, let newName = params?["newName"]?.stringValue,
                  let row = rows.firstIndex(where: { $0.name == name }) else { throw RPCError.invalidParams("name/newName") }
            rename(rows[row], to: newName)
        case "paste":
            let paths = (params?["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
            let move = params?["move"]?.boolValue ?? false
            let sources = try paths.map { path -> FileLocation in
                do { return try FileLocation.parse(path) } catch { throw RPCError.invalidParams("\(error)") }
            }
            copyOrMoveHere(sources, move: move)
        case "trash": moveToTrash()
        case "reload": reload()
        case "goto":
            guard let path = params?["path"]?.stringValue else { throw RPCError.invalidParams("path") }
            navigate(to: isRemote ? RemotePath.resolve(typed: path, in: folder) : FileNames.resolve(typed: path, in: folder))
        case "hidden": setShowHidden(params?["on"] != .bool(false))
        case "follow": setFollowsTerminal(params?["on"] != .bool(false))
        case "preview": previewSelection()
        case "terminal": openTerminalHere()
        case "back": goBack()
        case "forward": goForward()
        case "up": goUp()
        default: throw RPCError.invalidParams("unknown action \(action)")
        }
        return .object([
            "folder": .string(folder),
            "rows": .array(rows.map { .string($0.name) }),
            "selected": .array(selectedEntries.map { .string($0.name) }),
            "git": gitStates.map { states in .object(states.mapValues { .string($0.rawValue) }) } ?? .null,
            "busy": .bool(operation != nil || activeTransfer != nil || remoteActivity != nil),
            "host": host.map(JSONValue.string) ?? .null,
            "connectionError": connectionError.map(JSONValue.string) ?? .null,
            "loadError": loadError.map(JSONValue.string) ?? .null,
            "waitingForConnect": .bool(waitingForConnect),
            "status": .string(statusLabel.stringValue),
            "back": .number(Double(backStack.count)),
            "forward": .number(Double(forwardStack.count)),
            "showHidden": .bool(showHidden),
            "follow": .bool(followsTerminal),
        ])
    }

    /// PNG of the pane as drawn, also while the window is hidden.
    func debugSnapshot() throws -> Data {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { throw RPCError(code: 500, message: "no bitmap") }
        cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RPCError(code: 500, message: "PNG encoding failed") }
        return png
    }
}
#endif
