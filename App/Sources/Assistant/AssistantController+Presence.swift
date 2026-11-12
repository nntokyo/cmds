import AppKit
import CmdsCore

/// The waiting orb (#243): shown while the assistant is on and waits for its name (Settings › Assistant › Show while
/// waiting), hidden while the HUD shows (it grows into it), dim while paused, following the microphone while it hears
/// speech, orange when a workspace needs the user. The rules are `AssistantPresence` (CmdsCore).
@available(macOS 26.0, *)
extension AssistantController {
    /// Puts the orb in step with the state; called by `refresh()`, on state and screen changes and the level.
    func updatePresence() {
        presenceUpdatePending = false
        let attention = isOn && AgentOverview.summary(controller).needingUserCount > 0
        let shown = AssistantPresence.shown(phase: machine.phase, hudShown: hud.isVisible,
                                            showWhileWaiting: settings.assistantShowWhileWaiting,
                                            attention: attention, hearing: hearing.isHearing)
        let before = presence
        presence = shown
        switch shown {
        case .orb(let look):
            let size = settings.assistantOrbSize
            let center = AssistantPresence.center(saved: settings.assistantOrbCenter, side: size.side,
                                                  visibles: NSScreen.screens.map(\.visibleFrame))
            orb.show(look: look, phase: machine.phase, style: settings.assistantStyle, size: size, center: center,
                     fromHUD: before == .hud)
        case .hud:
            orb.hide(intoHUD: true)
        case .none:
            orb.hide(intoHUD: false)
        }
    }

    /// Workspaces change in bursts: one update on the next turn of the run loop.
    func schedulePresenceUpdate() {
        guard isOn, !presenceUpdatePending else { return }
        presenceUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updatePresence() }
        }
    }

    /// The microphone's level: the HUD's orb and waveform, or the waiting orb.
    func heard(level: Float) {
        hud.level(level)
        if hearing.update(level: level, now: Date()) { updatePresence() }
        orb.level(level)
    }

    /// The user dropped the orb here: remembered (moved fully onto its screen).
    func orbMoved(to center: CGPoint) {
        settings.assistantOrbCenter = AssistantPresence.center(saved: center, side: settings.assistantOrbSize.side,
                                                               visibles: NSScreen.screens.map(\.visibleFrame))
        updatePresence()
    }
}
