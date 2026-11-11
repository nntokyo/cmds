import AppKit
import CmdsCore
import os

private let assistantLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// Listening (#243): what was heard, the listen shortcut and the confirmation keys, turned into the machine's
/// steps and carried out.
@available(macOS 26.0, *)
extension AssistantController {
    /// A finished utterance from the microphone (or `debug.assistant`). Not addressed: dropped here, unstored.
    /// Said by name while the assistant speaks or works (barge-in), it stops that first; the HUD shows the new
    /// transcript at once.
    func hear(_ text: String) {
        let request = machine.request
        let step = machine.hear(text, names: names, now: Date())
        if machine.request != request { interrupt() }
        perform(step)
    }

    /// The listen shortcut.
    func hotkey() {
        guard isOn else { return }
        let request = machine.request
        machine.hotkey(now: Date())
        if machine.request != request { interrupt() }
        if machine.phase == .listening, !listener.isRunning, usesMicrophone {
            temporaryMicrophone = true
            startMicrophone()
        }
        refresh()
    }

    /// Return / Esc (while the card shows) and the card's buttons.
    func key(_ key: AssistantMachine.Key) {
        let request = machine.request
        let step = machine.key(key, now: Date())
        if machine.request != request { interrupt() }
        perform(step)
    }

    /// Stops what the assistant was saying or working out (a new request, barge-in): the voice, and the task with its
    /// `claude` process (cancelled: `AssistantBrain` terminates it). A late answer is dropped by its request number.
    func interrupt() {
        speech += 1
        voice.stop()
        work?.cancel()
        work = nil
        claudeWorkingFor = nil
    }

    func globalKey(_ key: AssistantHotkeys.Key) {
        switch key {
        case .listen: hotkey()
        case .confirm, .enter, .cancel:
            if let shown = pendingShownAt, Date().timeIntervalSince(shown) < AssistantTuning.confirmArmDelay { return }
            self.key(key == .cancel ? .cancel : .confirm)
        }
    }

    func perform(_ step: AssistantMachine.Step) {
        if step != .ignore { lastStep = step }
        switch step {
        case .ignore:
            return
        case .wake:
            refresh()
        case .handle(var intent):
            // The answer to "Which one?": the request asked back about, aimed at the workspace named. The rest of its
            // utterance still follows; any other new request drops it.
            if let previous = askedBack, case .question(let answer) = intent, let retargeted = previous.retargeted(answer) {
                intent = retargeted
            } else {
                queued = []
                createdForQueue = []
            }
            askedBack = nil
            assistantLog.info("assistant command: \(String(describing: intent).prefix(24), privacy: .private)")
            refresh()
            handle(intent)
        case .execute(let action):
            run(action)
        case .cancelled:
            // No to a card is no to the rest of that utterance as well.
            queued = []
            say(AssistantStrings.localized(.cancelled))
        case .needsKey:
            needsKey = true
            speakOnly(AssistantStrings.localized(.voiceNotEnough))
        case .expired:
            queued = []
            say(AssistantStrings.localized(.expired))
        }
    }
}
