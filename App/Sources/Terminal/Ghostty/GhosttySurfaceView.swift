// Portions adapted from Ghostty's macOS app (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import GhosttyKit

/// NSView hosting one `ghostty_surface_t`. libghostty installs its own CAMetalLayer on this view
/// and renders from its renderer thread; this class forwards AppKit input/size/focus to libghostty.
@MainActor
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    weak var owner: GhosttyTerminalSurface?
    /// Launched with `waitAfterCommand`: libghostty keeps the surface when the command exits.
    private(set) var waitsAfterCommand = false

    /// Cell size in points (libghostty reports pixels via CELL_SIZE).
    private(set) var cellSize: CGSize = .zero
    var cellSizePx: CGSize = .zero {
        didSet { cellSize = convertFromBacking(cellSizePx) }
    }

    private var markedText = NSMutableAttributedString()
    /// Non-nil while inside keyDown: collects text committed via insertText.
    private var keyTextAccumulator: [String]?
    private var isFirstResponderFlag = false
    private(set) var focused = false
    private var suppressNextLeftMouseUp = false
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var cursor: NSCursor = .iBeam
    private var alertShowing = false

    override var acceptsFirstResponder: Bool { true }

    init(app: ghostty_app_t, config: TerminalLaunchConfig) {
        // Non-zero initial frame so the renderer has a drawable before layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        var cfg = ghostty_surface_config_new()
        cfg.userdata = userdata
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: userdata))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0  // inherit from config
        waitsAfterCommand = config.waitAfterCommand
        cfg.wait_after_command = config.waitAfterCommand
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        // Build C strings that stay alive until ghostty_surface_new returns (libghostty copies them).
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        func dup(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s, let p = strdup(s) else { return nil }
            allocated.append(p)
            return UnsafePointer(p)
        }
        cfg.working_directory = dup(config.workingDirectory.flatMap { $0.isEmpty ? nil : $0 })
        cfg.command = dup(config.command.flatMap { $0.isEmpty ? nil : $0 })
        var envVars: [ghostty_env_var_s] = config.environment.map { key, value in
            ghostty_env_var_s(key: dup(key), value: dup(value))
        }

        GhosttyRuntime.shared.register(self)
        let created: ghostty_surface_t? = envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        guard let created else {
            GhosttyRuntime.shared.unregister(self)
            ghosttyLog.error("ghostty_surface_new failed")
            return
        }
        surface = created
        // libghostty starts a surface as focused; until this view becomes first responder in the key window it
        // is not, and programs using focus reporting (e.g. agents that only notify while unfocused) must see that.
        ghostty_surface_set_focus(created, false)

        updateTrackingAreas()
        registerForDraggedTypes([.fileURL, .string])

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            // Local monitors run on the main thread.
            guard let self else { return event }
            let box = UncheckedSendable(event)
            return MainActor.assumeIsolated { UncheckedSendable(self.localEvent(box.value)) }.value
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frees the libghostty surface. Idempotent.
    func teardown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        removeWindowObservers()
        guard let surface else { return }
        self.surface = nil
        GhosttyRuntime.shared.unregister(self)
        ghostty_surface_free(surface)
    }

    func surfaceRequestedClose() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.owner?.handleCloseRequest() }
        }
    }

    // MARK: - Size, scale, window

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scaled = convertToBacking(bounds.size)
        guard scaled.width > 0, scaled.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    private func updateContentScale() {
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        if cellSizePx != .zero { cellSize = convertFromBacking(cellSizePx) }
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    private func updateColorScheme() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        // AppKit does not call resignFirstResponder when the first responder leaves the window: a surface moved
        // back in (workspace switch, tiled view) must not believe it still has the keyboard and steal the focus.
        isFirstResponderFlag = window != nil && window?.firstResponder === self
        guard let window else {
            if let surface { ghostty_surface_set_occlusion(surface, false) }
            updateFocus()
            return
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.windowNotification(note.name) }
            })
        }
        updateContentScale()
        updateColorScheme()
        updateDisplayID()
        updateOcclusion()
        updateFocus()
    }

    private func removeWindowObservers() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    private func windowNotification(_ name: Notification.Name) {
        switch name {
        case NSWindow.didChangeOcclusionStateNotification:
            updateOcclusion()
        case NSWindow.didChangeScreenNotification:
            updateDisplayID()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.updateContentScale() }
            }
        default:
            updateFocus()
        }
    }

    private func updateOcclusion() {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    private func updateDisplayID() {
        guard let surface, let screen = window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, id.uint32Value)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFirstResponderFlag = true
            updateFocus()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            isFirstResponderFlag = false
            updateFocus()
        }
        return ok
    }

    private func updateFocus() {
        let want = isFirstResponderFlag && (window?.isKeyWindow ?? false)
        guard want != focused else { return }
        focused = want
        if !want { suppressNextLeftMouseUp = false }
        if let surface { ghostty_surface_set_focus(surface, want) }
        if want { owner?.handleFocused() }
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let c: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: c = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: c = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: c = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: c = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: c = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: c = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: c = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: c = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: c = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COPY: c = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: c = .dragLink
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: c = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: c = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: c = .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: c = .resizeDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: c = .resizeRight
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: c = .resizeLeft
        default: c = .arrow
        }
        guard c != cursor else { return }
        cursor = c
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            c.set()
        }
    }

    func setCursorVisible(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Local event monitor

    private func localEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            // ⌘-key keyUp events are not delivered through the responder chain.
            if event.modifierFlags.contains(.command), focused, event.window === window {
                keyUp(with: event)
                return nil
            }
            return event
        case .leftMouseDown:
            return localLeftMouseDown(event)
        default:
            return event
        }
    }

    private func localLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              let content = window.contentView else { return event }
        let loc = content.convert(event.locationInWindow, from: nil)
        guard content.hitTest(loc) === self else { return event }
        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }
        if NSApp.isActive && window.isKeyWindow {
            // Click only moves focus between panes; don't report it to the program.
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }
        window.makeFirstResponder(self)
        return event
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
                                           GhosttyInput.mods(event.modifierFlags)) else {
            return super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
                                           GhosttyInput.mods(event.modifierFlags)) else {
            return super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber),
                                     GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber),
                                     GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // While dragging we keep receiving drag events outside the view.
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y,
                                     GhosttyInput.scrollMods(precise: precise, momentum: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(max(event.stage, 0)), Double(event.pressure))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods for config such as macos-option-as-alt.
        let translatedGhostty = GhosttyInput.flags(
            ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when mods are unchanged (needed for some IMEs, e.g. Korean).
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer {
            keyTextAccumulator = nil
            // After libghostty has the key: the app only clears a stale notification (cheap when there is none).
            owner?.handleKeyInput()
        }

        let markedTextBefore = markedText.length > 0
        let layoutBefore: String? = markedTextBefore ? nil : GhosttyInput.keyboardLayoutID

        interpretKeyEvents([translationEvent])

        // The key switched input sources (e.g. 英数/かな): the IME consumed it.
        if !markedTextBefore && layoutBefore != GhosttyInput.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            // IME committed (part of) the preedit while handling this key.
            for text in list where !GhosttyInput.isComposingControlInput(text, composing: composing) {
                sendCommittedText(action, text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !GhosttyInput.isComposingControlInput(text, composing: composing) {
                keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if GhosttyInput.isComposingControlInput(event.characters, composing: composing) { return }
            keyAction(action, event: event, translationEvent: translationEvent,
                      text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        keyAction(action, event: event)
    }

    /// Key equivalents (⌘/⌃ combos) reach the view hierarchy before the main menu. The app shell
    /// owns window/workspace/split shortcuts (⌘N, ⌘D, ⌘W, ⌘1…9, ⌃Tab, …), so the main menu gets the
    /// first chance; only keys the menu doesn't handle go to libghostty (its own bindings such as
    /// copy/paste/font size, or encoding to the pty). libghostty's tab/window/split actions are
    /// additionally reported as unhandled in `GhosttyRuntime.handleAction`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return false }

        // Synthetic events (e.g. AppKit's cancel: → escape) are not ours.
        if event.timestamp == 0 { return false }

        if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
            return true
        }

        var keyEv = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var bindingFlags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            keyEv.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEv, &bindingFlags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        switch event.charactersIgnoringModifiers {
        case "\r" where flags.contains(.control):
            keyDown(with: event)
            return true
        case "/" where flags.contains(.control) && flags.isDisjoint(with: [.shift, .command, .option]):
            // Treat C-/ as C-_ (avoids the system beep), like Ghostty.
            if let ev = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                         modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                         windowNumber: event.windowNumber, context: nil, characters: "_",
                                         charactersIgnoringModifiers: "_", isARepeat: event.isARepeat,
                                         keyCode: event.keyCode) {
                keyDown(with: ev)
                return true
            }
            return false
        default:
            break
        }

        if flags.contains(.command) {
            // Unbound ⌘-key nobody claimed: let libghostty encode it (e.g. kitty protocol) instead of beeping.
            keyDown(with: event)
            return true
        }
        // Plain ctrl combos continue to keyDown through the normal path.
        return false
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = GhosttyInput.keyEventText(text) {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    /// Committed text as a key event (keycode 0, no mods, not composing), as Ghostty does for IME commits.
    func sendCommittedText(_ action: ghostty_input_action_e, _ text: String) {
        guard let surface, !text.isEmpty else { return }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = 0
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0
        ev.composing = false
        text.withCString { ptr in
            ev.text = ptr
            _ = ghostty_surface_key(surface, ev)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true  // down, right, up
        case 0x7B: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])  // left
        default: return false
        }
    }

    /// Sends a synthetic key press+release for programmatic input (`sendText` / `typeText`: the socket API
    /// and the iOS companion). A key that matches one of the user's Ghostty keybindings is not pressed;
    /// `fallback` (the key's plain terminal bytes) is written to the pty instead, so remote or scripted
    /// input can only type into the terminal and never runs local actions.
    func sendKey(keyCode: UInt16, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, unshifted: UInt32, fallback: [UInt8]) {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.keycode = UInt32(keyCode)
        ev.mods = mods
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = unshifted
        ev.text = nil
        ev.composing = false
        ev.action = GHOSTTY_ACTION_PRESS
        var bindingFlags = ghostty_binding_flags_e(0)
        if ghostty_surface_key_is_binding(surface, ev, &bindingFlags) {
            writeRaw(fallback)
            return
        }
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Edit actions

    private func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Writes bytes to the pty unmodified (libghostty's `text:` binding action; never bracketed).
    func writeRaw(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var action = "text:"
        for b in bytes {
            switch b {
            case 0x5C: action += "\\\\"
            case 0x20...0x7E: action.unicodeScalars.append(Unicode.Scalar(b))
            default: action += String(format: "\\x%02x", b)
            }
        }
        if !performBinding(action) {
            ghosttyLog.warning("raw write via text: binding failed")
        }
    }

    @objc func copy(_ sender: Any?) { _ = performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { _ = performBinding("paste_from_clipboard") }
    @objc func pasteAsPlainText(_ sender: Any?) { _ = performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { _ = performBinding("select_all") }

    // MARK: - Drag & drop (files/text → paste)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let pb = sender.draggingPasteboard
        let text: String
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            text = urls.map { GhosttyRuntime.shellEscape($0.path) }.joined(separator: " ")
        } else if let s = pb.string(forType: .string) {
            text = s
        } else {
            return false
        }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        return true
    }

    // MARK: - Confirmation UI

    func presentConfirmation(message: String, detail: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard !alertShowing else {
            completion(false)
            return
        }
        alertShowing = true
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(detail.prefix(2000))
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            MainActor.assumeIsolated {
                self?.alertShowing = false
                completion(resp == .alertFirstButtonReturn)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

// MARK: - NSMenuItemValidation

extension GhosttySurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
                || NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}

// MARK: - NSTextInputClient (IME)

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: NSNotFound, length: 0) }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. input source switched mid-composition) update immediately.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: GhosttyTerminalSurface.string(from: text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {
            w = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // libghostty uses a top-left origin.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        // Committed outside keyDown (dictation, character palette): send as typed text.
        sendCommittedText(GHOSTTY_ACTION_PRESS, chars)
    }

    /// Prevents NSBeep for unhandled selectors (e.g. noop: for ⌘-keys); the key itself is
    /// encoded by keyDown after interpretKeyEvents returns.
    override func doCommand(by selector: Selector) {}
}
