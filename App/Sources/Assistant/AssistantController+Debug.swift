#if DEBUG
import AppKit
import CmdsCore

/// Tests only (`debug.assistant`, docs/internals/testing.md): the assistant without a microphone. `on` turns it on in
/// text-only mode (the microphone is never started from here, so no privacy prompt), `hear` injects a recognised
/// utterance as it would come from speech recognition (unaddressed ones are dropped the same way), `key` / `click`
/// answer the confirmation card as Return / Esc or its buttons would.
@available(macOS 26.0, *)
extension AssistantController {
    /// `action`: `state` (default), `on` (`mute?`, `style?`, `web?`, `interpreter?`, `reportTasks?`, `projectFolders?`,
    /// `showWhileWaiting?`, `orbSize?`, `listening?`), `off`, `pause`, `resume`, `recorders` (`apps`: bundle IDs to take
    /// as recording, #278; none: Core Audio again), `ignore_recorder` (the menu bar's "Don't Pause for …", #295),
    /// `clear_ignored` (Settings' Remove › Remove All), `unignore` (`app`: Remove › one app, #305), `live_recorders`
    /// (who records now by Core Audio, through the same rules; changes nothing, #310), `hotkey`, `hotkey_up` (push to talk),
    /// `hear` (`text`; `noisy?`, `pushed?`: as heard in a loud room / with the shortcut held),
    /// `speak` (`text`: speaking it without a voice until `spoken`; `card: true`: reading out the card that waits),
    /// `spoken`, `hear_audio` (`path`: an audio file through speech recognition instead of the microphone; `tail?`
    /// seconds of quiet after it, default 10; `endpoint?` false: only the recogniser ends the utterance; `release?`
    /// seconds: push to talk, the shortcut held from the start and let go then; `heardAudio` in the state), `problem`
    /// (`text`, none clears it: as if the microphone had failed, for Settings' problem row),
    /// `key` (`confirm` / `cancel`: Return / Esc), `click` (`confirm` / `cancel`: the card's buttons; `orb`: the
    /// waiting orb), `level` (`value` 0…1: as the microphone's level), `move_orb` (`x`, `y`: as if the orb were
    /// dropped with its centre there). `snapshot` adds the HUD drawn off screen (`png_base64`; without the window's
    /// translucency) and the waiting orb (`orb.png_base64`) when it shows.
    ///
    /// The parameters of `on` are runtime overrides until `off` or a relaunch, never written to the settings: a test
    /// must not leave the user's assistant muted or changed. `state` has the values in effect and the settings.
    func debugPerform(_ params: JSONValue?) throws -> JSONValue {
        let action = params?["action"]?.stringValue ?? "state"
        switch action {
        case "state": break
        case "on":
            overrides.set(from: params)
            turnOn(microphone: false)
        case "off": turnOff()
        case "pause": pause()
        case "resume": resume()
        case "recorders":
            // Apps to take as recording instead of Core Audio's (#278); none: Core Audio again.
            overrides.recorders = params?["apps"]?.arrayValue?.compactMap(\.stringValue)
            shareMicrophone()
        case "ignore_recorder":
            // The menu bar's "Don't Pause for …" (#295); writes the setting (an isolated instance's own).
            guard canIgnoreRecorder else { throw RPCError.invalidParams("not paused for an app that can be ignored") }
            ignoreRecorder()
        case "clear_ignored":
            // Settings › Assistant's Remove › Remove All (#295).
            settings.assistantIgnoredRecorders = []
        case "live_recorders":
            // #310: who records now by Core Audio, through the same rules (no microphone of its own, no pause).
            let live = AssistantMicrophoneShare.recorders(AssistantAudioDevices.processes(), own: getpid(),
                                                         ownBundleID: Bundle.main.bundleIdentifier ?? "",
                                                         ignored: Set(settings.assistantIgnoredRecorders))
            return .object(["recorders": .array(live.map { .object(["pid": .number(Double($0.pid)), "id": .string($0.bundleID)]) })])
        case "unignore":
            // Settings › Assistant's Remove › one app (#305).
            guard let id = params?["app"]?.stringValue else { throw RPCError.invalidParams("app is required") }
            settings.assistantIgnoredRecorders.removeAll { $0 == id }
        case "hotkey": hotkey()
        case "hotkey_up": hotkeyReleased()
        case "speak":
            guard let text = params?["text"]?.stringValue else { throw RPCError.invalidParams("text is required") }
            debugSpeak(text, card: params?["card"]?.boolValue == true)
        case "spoken": debugSpeechEnded()
        case "problem": debugSetProblem(params?["text"]?.stringValue)
        case "hear":
            guard let text = params?["text"]?.stringValue else { throw RPCError.invalidParams("text is required") }
            hear(text, heard: AssistantHeard(noisy: params?["noisy"]?.boolValue == true, pushed: params?["pushed"]?.boolValue == true))
        case "hear_audio":
            // An audio file instead of the microphone, through the same recognition (#248: the end of an utterance).
            guard let path = params?["path"]?.stringValue, path.hasPrefix("/") else { throw RPCError.invalidParams("an absolute path is required") }
            guard !usesMicrophone, !listener.isRunning else { throw RPCError.invalidParams("the microphone is in use") }
            let tail = Self.number(params?["tail"]) ?? 10
            let release = Self.number(params?["release"])
            listener.finalizesEarly = params?["endpoint"]?.boolValue ?? true
            let locale = language.locale
            Task { [weak self] in
                // `endpoint: false` is for this call only (#272).
                defer { self?.listener.finalizesEarly = true }
                do {
                    try await self?.listener.debugFeed(URL(fileURLWithPath: path), locale: locale, tail: tail, release: release)
                } catch {
                    self?.debugSetProblem("hear_audio: \(error.localizedDescription)")
                }
            }
        case "click" where params?["button"]?.stringValue == "orb":
            orb.debugClick()
        case "level":
            guard let value = Self.number(params?["value"]) else { throw RPCError.invalidParams("value is required") }
            heard(level: Float(value))
        case "move_orb":
            guard let x = Self.number(params?["x"]), let y = Self.number(params?["y"]) else {
                throw RPCError.invalidParams("x and y are required")
            }
            orbMoved(to: CGPoint(x: x, y: y))
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

    private static func json(_ timeline: AssistantTimeline) -> JSONValue {
        .object([
            "request": .number(Double(timeline.request)),
            "route": timeline.route.map { .string($0.rawValue) } ?? .null,
            "ms": .object(timeline.milliseconds.mapValues { .number(Double($0)) }),
            "firstSound": timeline.firstSound.map { .number(Double($0)) } ?? .null,
        ])
    }

    private static func json(_ frame: NSRect) -> JSONValue {
        .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
    }

    private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }

    private func debugState(snapshot: Bool) -> JSONValue {
        let inputs = AssistantAudioDevices.inputs()
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
            "listening": .string(listening.rawValue),
            "held": .bool(listener.isHeld),
            // Paused for another app's recording (#278), and the user resumed during it.
            "pausedFor": pausedForApp.map(JSONValue.string) ?? .null,
            "shareOverridden": .bool(microphoneShare.overridden),
            // Its bundle ID, the menu bar's "Don't Pause for …" (null: not offered) and the ignore list (#295).
            "pausedForBundleID": pausedForBundleID.map(JSONValue.string) ?? .null,
            "ignoreOffer": ignorableRecorderName.map(JSONValue.string) ?? .null,
            "ignoredRecorders": .array(settings.assistantIgnoredRecorders.map(JSONValue.string)),
            // Inputs as Settings lists them, and the one `Microphone` chooses now (#270; nothing is opened).
            "inputs": .array(inputs.map { device in
                .object(["name": .string(device.name), "headset": .bool(device.isHeadset)])
            }),
            "chosenInput": AssistantInputDevice.chosen(settings.assistantMicrophone, devices: inputs)
                .map { .string($0.name) } ?? .null,
            "confirmationKeys": .bool(hotkeys?.confirmationKeysOn ?? false),
            "muted": .bool(muted),
            "mutedSetting": .bool(AppSettings.shared.assistantMuted),
            "web": .bool(usesWeb),
            "interpreter": .bool(usesInterpreter),
            "reportTasks": .bool(reportsTasks),
            "style": .string(style.rawValue),
            "projectFolders": .string(projectFolders),
            // What the settings say (the parameters of `on` never change them).
            "settings": .object([
                "muted": .bool(settings.assistantMuted), "web": .bool(settings.assistantWeb),
                "interpreter": .bool(settings.assistantInterpreter), "reportTasks": .bool(settings.assistantReportTasks),
                "style": .string(settings.assistantStyle.rawValue), "projectFolders": .string(settings.assistantProjectFolders),
                "showWhileWaiting": .bool(settings.assistantShowWhileWaiting), "orbSize": .string(settings.assistantOrbSize.rawValue),
                "listening": .string(settings.assistantListening.rawValue), "microphone": .string(settings.assistantMicrophone),
                "shareMicrophone": .bool(settings.assistantShareMicrophone),
            ]),
            "hudVisible": .bool(hud.isVisible),
            "queued": .array(queued.map { .string(String(describing: $0)) }),
            "watching": .array(taskWatch.entries.map { .string($0.paneID) }),
            "vocabulary": .array(vocabulary.map(JSONValue.string)),
            "hud": .object(hud.debugTexts.mapValues(JSONValue.string)),
            "window": .number(Double(hud.panel.windowNumber)),
            // Stage times of the current request and the last few (#248), milliseconds from the transcript.
            "timing": timeline.map(Self.json) ?? .null,
            "timings": .array(timelines.map(Self.json)),
            // The last `hear_audio` (#270): final transcripts and early finalisations, seconds from the file's start.
            "heardAudio": listener.debugRecord.map { record in
                .object([
                    "done": .bool(record.done),
                    "finals": .array(record.finals.map { final in
                        .object(["text": .string(final.text), "at": .number(final.at), "noisy": .bool(final.noisy),
                                 "confidences": .array(final.confidences.map(JSONValue.number))])
                    }),
                    "finalizes": .array(record.finalizes.map(JSONValue.number)),
                    "floor": .number(Double(record.floor)),
                ])
            } ?? .null,
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
        state["frame"] = Self.json(hud.panel.frame)
        var orbState: [String: JSONValue] = [
            "visible": .bool(orb.isShown),
            "look": orb.look.map { .string($0.rawValue) } ?? .null,
            "showWhileWaiting": .bool(showsWhileWaiting),
            "size": .string(orbSize.rawValue),
            "saved": settings.assistantOrbCenter.map { .string(AssistantPresence.format($0)) } ?? .null,
            "hearing": .bool(hearing.isHearing),
            "frame": Self.json(orb.panel.frame),
            "window": .number(Double(orb.panel.windowNumber)),
        ]
        if snapshot, orb.isShown {
            orbState["png_base64"] = orb.debugSnapshot().map { .string($0.base64EncodedString()) } ?? .null
        }
        state["orb"] = .object(orbState)
        if snapshot {
            state["png_base64"] = hud.debugSnapshot().map { .string($0.base64EncodedString()) } ?? .null
        }
        return .object(state)
    }
}

extension AssistantOverrides {
    /// The parameters of `debug.assistant` `on` that are given (`mute`, `style`, `web`, `interpreter`, `reportTasks`,
    /// `projectFolders`, `showWhileWaiting`, `orbSize`); the others stay as they were.
    mutating func set(from params: JSONValue?) {
        if let mute = params?["mute"]?.boolValue { muted = mute }
        if let web = params?["web"]?.boolValue { self.web = web }
        if let interpreter = params?["interpreter"]?.boolValue { self.interpreter = interpreter }
        if let report = params?["reportTasks"]?.boolValue { reportTasks = report }
        if let folders = params?["projectFolders"]?.stringValue { projectFolders = folders }
        if let style = params?["style"]?.stringValue.flatMap(AssistantStyle.init(rawValue:)) { self.style = style }
        if let shows = params?["showWhileWaiting"]?.boolValue { showWhileWaiting = shows }
        if let size = params?["orbSize"]?.stringValue.flatMap(AssistantPresence.Size.init(rawValue:)) { orbSize = size }
        if let mode = params?["listening"]?.stringValue.flatMap(AssistantListening.init(rawValue:)) { listening = mode }
    }
}
#endif
