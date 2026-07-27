import Cocoa
import GhosttyKit

/// An NSView backed by a libghostty surface.
///
/// libghostty owns the rendering entirely: it installs its own layer on this
/// view and makes it layer-hosting. Our job is to create the surface, keep it
/// informed about size/scale/focus, and forward input.
///
/// Input handling here is adapted from Ghostty's own macOS embedding layer
/// (MIT, Mitchell Hashimoto and Ghostty contributors).
final class GhosttySurfaceView: NSView, NSTextInputClient {
    let id = UUID()

    private(set) var surface: ghostty_surface_t?
    private(set) weak var ghosttyApp: GhosttyApp?

    /// Title reported by the terminal, used by the Cmd-K switcher.
    private(set) var title: String = "Terminal"
    /// Working directory reported by the shell via OSC 7.
    private(set) var pwd: String?

    var cellSize: CGSize = .zero

    /// Called whenever the title or pwd changes so the switcher can refresh.
    var onMetadataChange: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    /// Text committed by the input method during the current keyDown, if any.
    private var keyTextAccumulator: [String]?
    private var mouseEntered = false
    private var cursorVisible = true
    private var mouseShape: NSCursor = .iBeam
    private var eventMonitor: Any?

    // MARK: - Lifecycle

    init(app: GhosttyApp, command: String? = nil, workingDirectory: String? = nil) throws {
        self.ghosttyApp = app
        super.init(frame: .zero)

        guard let cApp = app.app else { throw GhosttyError.appFailed }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        // The C config holds borrowed pointers, so keep the strings alive for
        // the duration of ghostty_surface_new.
        let surface: ghostty_surface_t? = withOptionalCString(command) { cmdPtr in
            withOptionalCString(workingDirectory) { cwdPtr in
                config.command = cmdPtr
                config.working_directory = cwdPtr
                return ghostty_surface_new(cApp, &config)
            }
        }

        guard let surface else { throw GhosttyError.surfaceFailed }
        self.surface = surface
        app.register(self, for: surface)

        // Command-modified keys don't generate keyUp through the responder
        // chain, so watch for them globally within the app.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            guard event.modifierFlags.contains(.command) else { return event }
            self.keyUp(with: event)
            return nil
        }

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    /// Tear the surface down. Must be called before the view is released so the
    /// pty and render thread shut down deterministically.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghosttyApp?.unregister(surface)
        ghostty_surface_free(surface)
    }

    // MARK: - Geometry and focus

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocus(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocus(false) }
        return result
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    private func syncSize() {
        guard let surface else { return }
        // libghostty wants pixels, not points.
        let scale = window?.backingScaleFactor ?? 2
        let width = UInt32(max(0, frame.size.width * scale))
        let height = UInt32(max(0, frame.size.height * scale))
        ghostty_surface_set_size(surface, width, height)
    }

    func requestRender() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    func applyInitialSize(width: Int, height: Int) {
        // kterm sizes windows itself; the initial size request only matters for
        // the very first window, which the window controller handles.
        _ = (width, height)
    }

    // MARK: - Metadata

    func setTitle(_ newTitle: String) {
        guard title != newTitle else { return }
        title = newTitle
        onMetadataChange?()
    }

    func setPwd(_ newPwd: String) {
        // The pwd arrives as a file:// URL from OSC 7.
        let path = URL(string: newPwd)?.path ?? newPwd
        guard pwd != path else { return }
        pwd = path
        onMetadataChange?()
    }

    /// A short label for this surface, for the Cmd-K switcher.
    var displayTitle: String {
        title.isEmpty ? (pwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal") : title
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInActiveApp],
            owner: self,
            userInfo: nil))
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        mouseShape = switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: .resizeUpDown
        default: .arrow
        }
        if mouseEntered { mouseShape.set() }
    }

    func setMouseVisibility(_ visible: Bool) {
        guard visible != cursorVisible else { return }
        cursorVisible = visible
        if visible { NSCursor.unhide() } else { NSCursor.hide() }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseEntered = true
        mouseShape.set()
    }

    override func mouseExited(with event: NSEvent) {
        mouseEntered = false
        // Don't leave the cursor hidden once it leaves the terminal.
        setMouseVisibility(true)
    }

    override func mouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_LEFT, .press) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_LEFT, .release) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RIGHT, .press) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RIGHT, .release) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_MIDDLE, .press) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_MIDDLE, .release) }

    private enum ButtonState { case press, release }

    private func mouseButton(
        _ event: NSEvent,
        _ button: ghostty_input_mouse_button_e,
        _ state: ButtonState
    ) {
        guard let surface else { return }
        // A click anywhere in the terminal should also give it keyboard focus.
        if state == .press, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        _ = ghostty_surface_mouse_button(
            surface,
            state == .press ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            button,
            GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { mouseMove(event) }
    override func mouseDragged(with event: NSEvent) { mouseMove(event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMove(event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMove(event) }

    private func mouseMove(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface, pos.x, pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            mods = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
            let momentum: ghostty_input_mouse_momentum_e = switch event.momentumPhase {
            case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
            case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
            case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
            case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
            case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
            case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
            default: GHOSTTY_MOUSE_MOMENTUM_NONE
            }

            // Precise deltas and momentum are packed into a single int: bit 0
            // marks "precise", the remaining bits carry the momentum phase.
            mods = 1
            mods |= Int32(momentum.rawValue) << 1
        }

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Ask libghostty which modifiers should participate in text translation
        // (this is what makes option-as-alt configurable) and rebuild the event
        // if they differ from what AppKit gave us.
        let translationModsGhostty = GhosttyInput.modifierFlags(
            ghostty_surface_key_translation_mods(
                surface, GhosttyInput.mods(event.modifierFlags)))

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // IMPORTANT: reuse the original event when the mods match. AppKit does
        // object-identity comparisons internally and rebuilding it breaks IMEs.
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
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Run the event through AppKit's text input system so input methods
        // (Japanese, Korean, dead keys) work. Anything they commit lands in the
        // accumulator via insertText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: hadMarkedText)

        // We're composing if there's preedit now, or if this event just cleared
        // preedit that existed before — either way it shouldn't be encoded.
        let composing = markedText.length > 0 || hadMarkedText

        if let committed = keyTextAccumulator, !committed.isEmpty {
            for text in committed {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
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
            // The modifier is down, but we still need to know whether it's the
            // side that generated this event — otherwise releasing left-shift
            // while right-shift is held would read as a press.
            let sidePressed: Bool = switch event.keyCode {
            case 0x3C: event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }

        _ = keyAction(action, event: event)
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

        var keyEvent = event.ghosttyKeyEvent(
            action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // Only pass text through when it isn't a bare control character —
        // libghostty encodes those itself, and passing both breaks ctrl+enter.
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        unmarkText()

        let text: String
        switch string {
        case let v as NSAttributedString: text = v.string
        case let v as String: text = v
        default: return
        }
        guard !text.isEmpty else { return }

        // Inside a keyDown, stash the text so keyDown can attach it to the key
        // event (which preserves modifier information). Outside of one — e.g. a
        // paste routed through the input system — send it directly.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
            }
        }
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return NSRect() }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // libghostty reports a top-left origin; AppKit wants bottom-left screen
        // coordinates for the IME candidate window.
        let viewRect = NSRect(x: x, y: frame.size.height - y - height, width: width, height: height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func doCommand(by selector: Selector) {
        // Swallow AppKit's editing commands; the terminal encodes these keys
        // itself from the key event.
    }

    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

/// Run `body` with a C string for `value`, or nil when `value` is nil.
private func withOptionalCString<R>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
