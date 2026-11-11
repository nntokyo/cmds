#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.assistant`, docs/internals/testing.md): the assistant without a microphone. `on` turns it on in
/// text-only mode (the microphone is never started from here, so no privacy prompt), `hear` injects a recognised
/// utterance as it would come from speech recognition (unaddressed ones are dropped the same way), `key` / `click`
/// answer the confirmation card as Return / Esc or its buttons would.
@available(macOS 26.0, *)
extension AssistantController {
    /// `action`: `state` (default), `on` (`mute?`, `style?`, `web?`, `interpreter?`, `reportTasks?`, `projectFolders?`), `off`, `pause`, `resume`, `hotkey`, `hear` (`text`),
    /// `speak` (`text`: speaking it without a voice until `spoken`), `spoken`,
    /// `key` (`confirm` / `cancel`: Return / Esc), `click` (`confirm` / `cancel`: the card's buttons). `snapshot`
    /// adds the HUD drawn off screen (`png_base64`; without the window's translucency).
    func debugPerform(_ params: JSONValue?) throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "state"
        switch action {
        case "state": break
        case "on":
            if let mute = params?["mute"]?.boolValue { AppSettings.shared.assistantMuted = mute }
            if let web = params?["web"]?.boolValue { AppSettings.shared.assistantWeb = web }
            if let interpreter = params?["interpreter"]?.boolValue { AppSettings.shared.assistantInterpreter = interpreter }
            if let report = params?["reportTasks"]?.boolValue { AppSettings.shared.assistantReportTasks = report }
            if let folders = params?["projectFolders"]?.stringValue { AppSettings.shared.assistantProjectFolders = folders }
            if let style = params?["style"]?.stringValue.flatMap(AssistantStyle.init(rawValue:)) {
                AppSettings.shared.assistantStyle = style
            }
            turnOn(microphone: false)
        case "off": turnOff()
        case "pause": pause()
        case "resume": resume()
        case "hotkey": hotkey()
        case "speak":
            guard let text = params?["text"]?.stringValue else { throw RPCError.invalidParams("text is required") }
            debugSpeak(text)
        case "spoken": debugSpeechEnded()
        case "hear":
            guard let text = params?["text"]?.stringValue else { throw RPCError.invalidParams("text is required") }
            hear(text)
        case "key", "click":
            guard let which = params?["key"]?.stringValue ?? params?["button"]?.stringValue,
                  which == "confirm" || which == "cancel" else { throw RPCError.invalidParams("key must be confirm or cancel") }
            if action == "click" {
                which == "confirm" ? hud.debugClickConfirm() : hud.debugClickCancel()
            } else {
                key(which == "confirm" ? .confirm : .cancel)
            }
        default:
            throw RPCError.invalidParams("unknown action \(action)")
        }
        refresh()
        return debugState(snapshot: params?["snapshot"]?.boolValue == true)
    }

    private func debugState(snapshot: Bool) -> JSONValue {
        var state: [String: JSONValue] = [
            "on": .bool(isOn),
            "unlock": PaidFeatures.unlock(.assistant).map { .string($0.rawValue) } ?? .null,
            "phase": .string(machine.phase.rawValue),
            "transcript": machine.transcript.map(JSONValue.string) ?? .null,
            "answer": machine.answer.map(JSONValue.string) ?? .null,
            "spoken": lastSpoken.map(JSONValue.string) ?? .null,
            "problem": problem.map(JSONValue.string) ?? .null,
            "lastStep": lastStep.map { .string(String(describing: $0)) } ?? .null,
            "request": .number(Double(machine.request)),
            "voiceActive": .bool(machine.voiceActive),
            "followUpSeconds": machine.followUpUntil.map { .number(max(0, $0.timeIntervalSinceNow)) } ?? .null,
            "claudeWorking": .bool(claudeWorking),
            "microphone": .bool(usesMicrophone),
            "confirmationKeys": .bool(hotkeys?.confirmationKeysOn ?? false),
            "muted": .bool(AppSettings.shared.assistantMuted),
            "web": .bool(AppSettings.shared.assistantWeb),
            "interpreter": .bool(AppSettings.shared.assistantInterpreter),
            "hudVisible": .bool(hud.isVisible),
            "queued": .array(queued.map { .string(String(describing: $0)) }),
            "watching": .array(taskWatch.entries.map { .string($0.paneID) }),
            "vocabulary": .array(vocabulary.map(JSONValue.string)),
            "hud": .object(hud.debugTexts.mapValues(JSONValue.string)),
            "window": .number(Double(hud.panel.windowNumber)),
        ]
        if let action = machine.pending {
            state["pending"] = .object([
                "kind": .string(String(describing: action.kind)),
                "workspace": action.workspaceID.map(JSONValue.string) ?? .null,
                "pane": action.paneID.map(JSONValue.string) ?? .null,
                "text": .string(action.text),
                "confirmation": .string(action.confirmation.rawValue),
                "reasons": .array(action.allReasons.map { .string($0.rawValue) }),
                "also": .array(action.also.map { other in
                    .object(["kind": .string(String(describing: other.kind)), "workspace": other.workspaceID.map(JSONValue.string) ?? .null,
                             "pane": other.paneID.map(JSONValue.string) ?? .null, "text": .string(other.text)])
                }),
            ])
        } else {
            state["pending"] = .null
        }
        let frame = hud.panel.frame
        state["frame"] = .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
        if snapshot, let view = hud.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            state["png_base64"] = rep.representation(using: .png, properties: [:]).map { .string($0.base64EncodedString()) } ?? .null
        }
        return .object(state)
    }
}
#endif
