import AppKit
import Carbon.HIToolbox

/// Global keys of the assistant (#243), as Carbon hot keys (no Accessibility permission needed, nothing else is
/// read): the shortcut that makes it listen for one command, and — only while an action waits for confirmation —
/// Return / Enter (confirm) and Esc (cancel). The HUD never takes the keyboard, so these are how a key answers it;
/// while they are registered those keys go to the assistant, not to the terminal.
@MainActor
final class AssistantHotkeys {
    enum Key: UInt32 {
        case listen = 1
        case confirm = 2
        case enter = 3
        case cancel = 4
    }

    var onKey: ((Key) -> Void)?
    /// A key came up (push to talk, #270).
    var onRelease: ((Key) -> Void)?
    private var handler: EventHandlerRef?
    private var registered: [Key: EventHotKeyRef] = [:]
    private static let signature: OSType = 0x434D_4441  // "CMDA"
    private static weak var current: AssistantHotkeys?

    init() {
        Self.current = self
        // Released too: push to talk ends when the listen shortcut comes up (#270).
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == AssistantHotkeys.signature, let key = Key(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if released {
                        AssistantHotkeys.current?.onRelease?(key)
                    } else {
                        AssistantHotkeys.current?.onKey?(key)
                    }
                }
            }
            return noErr
        }, types.count, &types, nil, &handler)
    }

    /// The listen shortcut from Settings (nil: none).
    func setListen(_ hotkey: AssistantHotkey) {
        unregister(.listen)
        if let carbon = hotkey.carbon { register(.listen, keyCode: carbon.keyCode, modifiers: carbon.modifiers) }
    }

    /// Return, Enter and Esc while a confirmation card shows.
    func setConfirmationKeys(_ on: Bool) {
        if on {
            if registered[.confirm] == nil { register(.confirm, keyCode: UInt32(kVK_Return), modifiers: 0) }
            if registered[.enter] == nil { register(.enter, keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0) }
            if registered[.cancel] == nil { register(.cancel, keyCode: UInt32(kVK_Escape), modifiers: 0) }
        } else {
            [Key.confirm, .enter, .cancel].forEach(unregister)
        }
    }

    var confirmationKeysOn: Bool { registered[.confirm] != nil }

    private func register(_ key: Key, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: key.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { registered[key] = ref }
    }

    private func unregister(_ key: Key) {
        guard let ref = registered.removeValue(forKey: key) else { return }
        UnregisterEventHotKey(ref)
    }
}
