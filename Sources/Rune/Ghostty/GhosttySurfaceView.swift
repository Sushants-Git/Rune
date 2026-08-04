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
final class GhosttySurfaceView: NSView, @MainActor NSTextInputClient {
    let id = UUID()

    private(set) var surface: ghostty_surface_t?
    private(set) weak var ghosttyApp: GhosttyApp?

    /// Title reported by the terminal, used by the Cmd-K switcher.
    private(set) var title: String = "Terminal"
    /// Working directory reported by the shell via OSC 7.
    private(set) var pwd: String?
    /// This surface's background, from config and then from any OSC 11 change.
    /// Rune paints the title bar with it.
    private(set) var backgroundColor: NSColor = .black

    var cellSize: CGSize = .zero

    /// Called whenever the title or pwd changes so the switcher can refresh.
    var onMetadataChange: (() -> Void)?

    /// Called when this surface should take focus — a click in a split, say.
    /// Routed through the controller rather than grabbing first responder
    /// directly, so the tab's idea of which pane is focused stays true.
    var onFocusRequest: (() -> Void)?

    /// Set when the terminal asks for you, cleared when you look at it.
    private(set) var wantsAttention = false

    private var markedText = NSMutableAttributedString()
    /// Text committed by the input method during the current keyDown, if any.
    private var keyTextAccumulator: [String]?
    private var mouseEntered = false
    private var cursorVisible = true
    private var mouseShape: NSCursor = .iBeam
    private var eventMonitor: Any?
    /// Watches for the window moving between displays; see `syncDisplayID`.
    private var screenObserver: (any NSObjectProtocol)?

    // MARK: - Lifecycle

    init(app: GhosttyApp, command: String? = nil, workingDirectory: String? = nil) throws {
        self.ghosttyApp = app
        super.init(frame: .zero)
        self.backgroundColor = app.backgroundColor

        guard let cApp = app.app else { throw GhosttyError.appFailed }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)

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
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Tear the surface down. Must be called before the view is released so the
    /// pty and render thread shut down deterministically.
    func close() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        guard let surface else { return }
        self.surface = nil
        ghosttyApp?.unregister(surface)
        ghostty_surface_free(surface)
    }

    // MARK: - Geometry and focus

    override var acceptsFirstResponder: Bool { true }

    /// Take the click that activates the window, rather than swallowing it.
    /// Without this the first click into a background Rune only raises the
    /// window, so clicking straight onto a split doesn't focus that split.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // libghostty draws its IOSurface into a layer with top-left gravity, so the
    // view has to use a top-left origin too.
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
        syncDisplayID()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Follow the window between displays, so the surface's display link can
        // be re-pointed at whichever one it's actually on.
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncDisplayID()
                    // The new display may scale differently.
                    self.viewDidChangeBackingProperties()
                }
            }
        }

        syncDisplayID()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    /// Point this surface's CVDisplayLink at the display the window is on.
    ///
    /// libghostty creates the link with `CVDisplayLinkCreateWithActiveCGDisplays`,
    /// which does *not* bind it to any particular display — the host has to say
    /// which one. Ghostty's own app does this on every screen change, and its
    /// comment explains why: "if vsync is enabled, this will be used with the
    /// CVDisplayLink to ensure the proper refresh rate is going."
    ///
    /// Without it the link runs against whatever display it defaulted to. On a
    /// ProMotion panel, whose refresh rate is adaptive, that means frames get
    /// presented out of phase with the display: the terminal stays responsive,
    /// but motion judders, and scrolling in particular feels slow.
    private func syncDisplayID() {
        guard let surface, let screen = window?.screen else { return }
        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
    }

    private func syncSize() {
        guard let surface else { return }
        // libghostty wants the framebuffer size in pixels.
        let backing = convertToBacking(frame.size)
        ghostty_surface_set_size(
            surface, UInt32(max(0, backing.width)), UInt32(max(0, backing.height)))
    }

    /// Draw, now, on every frame libghostty asks for.
    ///
    /// Do not throttle this. It is tempting to: the draw is synchronous on the
    /// calling thread, and a scroll gesture reports at 120Hz, so it looks like
    /// a stream that wants rate limiting. It isn't one.
    ///
    /// On macOS the Metal renderer drives itself from a CVDisplayLink, and
    /// libghostty says so outright — "if [vsync is on], the renderer or apprt is
    /// responsible for triggering draw_now calls to the render thread. That is
    /// the only way to trigger a drawFrame." So these requests arrive exactly
    /// once per display refresh, phase-locked to the panel, already.
    ///
    /// Rate limiting them against a second, free-running clock is how you turn
    /// a vsync-locked stream into a stuttering one: normal delivery jitter puts
    /// a request a hair inside the window, it gets dropped and re-scheduled a
    /// frame late, and the cadence beats against the display. That read as
    /// "scrolling feels slow" even though the average frame rate was fine.
    func requestRender() {
        guard let surface else { return }
        renderCount += 1
        ghostty_surface_draw(surface)
    }

    /// Temporary diagnostic for ZoomScrollTest: how many draw requests
    /// libghostty has made of this surface.
    var renderCount = 0

    /// Run a libghostty keybinding action (e.g. `copy_to_clipboard`) against
    /// this surface. See Ghostty's docs for the action grammar.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    // Editing commands arrive through the responder chain rather than being
    // aimed at the terminal directly, so that while the ⌘K switcher is open
    // they act on its search field instead of on the terminal behind it.

    @objc func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    func applyInitialSize(width: Int, height: Int) {
        // Rune sizes windows itself; the initial size request only matters for
        // the very first window, which the window controller handles.
        _ = (width, height)
    }

    // MARK: - Metadata

    func setTitle(_ newTitle: String) {
        guard title != newTitle else { return }
        title = newTitle
        onMetadataChange?()
    }

    func setBackgroundColor(_ color: NSColor) {
        guard backgroundColor != color else { return }
        backgroundColor = color
        onMetadataChange?()
    }

    func setPwd(_ newPwd: String) {
        // The pwd arrives as a file:// URL from OSC 7.
        let path = URL(string: newPwd)?.path ?? newPwd
        guard pwd != path else { return }
        pwd = path
        onMetadataChange?()
    }

    /// What this terminal is doing, for the ⌘K list and the tab strip.
    ///
    /// Stored, not computed. Working it out means a `sysctl` for the foreground
    /// process's arguments and a read of the rendered screen, and it used to be
    /// recomputed on every read — of which there are a dozen per chrome sync.
    /// The controller refreshes it on a timer instead; everything else just
    /// reads the answer.
    private(set) var status = Status()

    /// The process in the foreground of this terminal, for the monitor to
    /// identify off the main thread. This is a `tcgetpgrp` on the pty and takes
    /// no libghostty lock, so it's safe to ask for on every poll.
    var foregroundPID: pid_t {
        guard let surface else { return 0 }
        return pid_t(ghostty_surface_foreground_pid(surface))
    }

    /// The last thing `AgentMonitor` said about this terminal. Held so a
    /// refresh driven by anything else — the bell, focus — doesn't have to
    /// wait for the next poll to know whether an agent is in here.
    private var verdict: AgentVerdict?

    /// Take a fresh reading from the monitor.
    @discardableResult
    func apply(_ verdict: AgentVerdict) -> Bool {
        self.verdict = verdict
        // An agent that has started a turn isn't waiting on you, so whatever
        // rang the bell before it did is stale — very often the shell that was
        // in this terminal before the agent was. Without this, one stray beep
        // would outrank the agent's own account of itself indefinitely.
        if verdict.activity == .working {
            wantsAttention = false
            attentionText = nil
        }
        return refreshStatus()
    }

    /// Recompute `status`. Returns true if it changed, so the caller can skip
    /// redrawing chrome — which is most seconds.
    @discardableResult
    func refreshStatus() -> Bool {
        let resolved = resolveStatus()
        guard resolved.differs(from: status) else { return false }
        // Keep the clock running across re-detections of the same state, so an
        // agent that stays busy doesn't reset its timer every second.
        status = Status(
            activity: resolved.activity,
            detail: resolved.detail,
            since: resolved.activity == status.activity ? status.since : Date())
        return true
    }

    /// What this terminal is doing, from what the agent in it says it's doing.
    ///
    /// Note what this no longer consults: the terminal, and the render clock.
    /// Nothing is inferred here — every state is either something the agent
    /// published or something it sent Rune directly.
    private func resolveStatus() -> Status {
        // No agent in here, nothing to report. This guard comes first on
        // purpose: "your turn" is an agent's word, and a shell doesn't take
        // turns. A shell also rings the bell constantly — zsh does it for an
        // ambiguous tab-completion — and reading that as a request for you
        // left every ordinary terminal claiming to be waiting on you.
        guard let verdict, verdict.agent != nil else { return Status() }

        // An agent that asked for you by name — an OSC 9 notification, or the
        // bell — is your turn immediately, without waiting for the next poll.
        // The message it sent becomes the detail.
        if wantsAttention {
            return Status(activity: .waiting, detail: attentionText)
        }
        return Status(activity: verdict.activity, detail: verdict.detail)
    }

    /// What the terminal said when it asked for you, if it said anything.
    /// Claude Code's is "Claude is waiting for your input"; a hook can send
    /// something far more useful.
    private(set) var attentionText: String?

    /// An OSC 9 / 99 / 777 desktop notification — the agent asking for you
    /// directly. Unlike everything else here this is pushed, not inferred, so
    /// it is both instant and free.
    func notify(title: String?, body: String?) {
        // The body is the message; the title is usually just the app's name.
        let text = [body, title].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        attentionText = text
        wantsAttention = true
        refreshStatus()
        onMetadataChange?()
    }

    /// Both of these push `status` forward themselves rather than waiting for
    /// the controller's next poll: being asked for is the most urgent thing a
    /// terminal can say, and clearing it happens because you just looked at the
    /// thing — a second of stale "your turn" after you've arrived is a second
    /// of lying.
    func ringBell() {
        guard !wantsAttention else { return }
        wantsAttention = true
        refreshStatus()
        onMetadataChange?()
    }

    func clearAttention() {
        guard wantsAttention else { return }
        wantsAttention = false
        attentionText = nil
        refreshStatus()
        onMetadataChange?()
    }

    /// The coding agent running in this terminal, if Rune recognises one.
    ///
    /// Whatever the monitor last found, rather than worked out on demand:
    /// identifying it means a `sysctl` for the process's entire argument
    /// vector, and the monitor already pays for that on its own queue.
    var agent: AgentIcon? { verdict?.agent }

    /// The full label for this surface, used by the ⌘K switcher.
    ///
    /// With any progress spinner taken off the front. Codex animates one there
    /// while it works, and left in it would rename the tab and the ⌘K row
    /// several times a second — a name that flickers is unreadable, and the
    /// fact it was carrying is already shown as the activity indicator.
    var displayTitle: String {
        let name = CodexTitle.withoutSpinner(title)
        return name.isEmpty ? (pwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal") : name
    }

    /// A short label — what the tab strip and ⌘K call this terminal.
    ///
    /// Shells report a title that is really just a path (`user@host:/some/path`
    /// or `…/Workspace/@devfolio/devfolio-frontend`), which is far too wide for
    /// a chip and, worse, makes every workspace look alike. So a path collapses
    /// to its last component the way a zsh prompt does — `devfolio-frontend`.
    /// A title in any other shape was set by a running program and is worth
    /// showing as-is.
    var shortTitle: String {
        let title = displayTitle

        // `user@host:/some/path`
        if let colon = title.firstIndex(of: ":"), title[..<colon].contains("@") {
            return Self.lastComponent(String(title[title.index(after: colon)...]))
        }
        if title.contains("/") { return Self.lastComponent(title) }
        return title
    }

    /// The folder name, with `~` kept as `~` rather than becoming your username.
    static func lastComponent(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "~" || trimmed == NSHomeDirectory() { return "~" }

        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? trimmed : last
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
        //
        // Unconditionally, *not* gated on "am I already first responder": that
        // check assumed AppKit's first responder and the tab's idea of the
        // focused pane can't disagree, and they can. When they had drifted, the
        // clicked pane was already first responder, the request never fired,
        // and clicking a split simply did nothing.
        if state == .press {
            if let onFocusRequest {
                onFocusRequest()
            } else if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
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

        // Deliberately identical to Ghostty's own macOS handler. Scrolling is
        // the one path where "improving" on the reference implementation has
        // only ever made things worse here: libghostty reads the precision bit
        // and converts lines to rows itself, so scaling a non-precise delta on
        // this side double-counts it.
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas

        if precise {
            // A 2x multiplier, matching upstream. Subjective, and theirs.
            x *= 2
            y *= 2
        }

        let momentum: ghostty_input_mouse_momentum_e = switch event.momentumPhase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }

        // Bit 0 marks "precise"; the remaining bits carry the momentum phase.
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(momentum.rawValue) << 1

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Dropping files

    /// Dropping a file on the terminal types its path, which is how you hand a
    /// screenshot to an agent running in it. Registered in `init`; without that
    /// the view isn't a drag destination at all and macOS shows the "no" cursor
    /// no matter what you drop.
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes)
        else { return [] }
        // Copy rather than move, for the "+" cursor: nothing is being taken
        // from wherever it was dragged out of.
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = sender.draggingPasteboard.droppedText, !text.isEmpty else {
            return false
        }
        // Async so AppKit has finished with the drag session before the
        // terminal starts processing what it produced.
        DispatchQueue.main.async { [weak self] in
            self?.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
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

    override func doCommand(by selector: Selector) {
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

extension NSScreen {
    /// The CoreGraphics display ID for this screen, which is what libghostty's
    /// display link wants in order to sync to the right panel.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

extension NSPasteboard {
    /// What a drop should type into the terminal.
    ///
    /// A file becomes its path with shell-sensitive characters backslashed, so
    /// `Screenshot 2026-07-29 at 3.17.28 AM.png` arrives as one argument rather
    /// than six. Anything else is taken as plain text. Multiple items are
    /// separated by spaces, which is what a command line wants.
    var droppedText: String? {
        let parts: [String] = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                return Self.shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Backslash-escape the characters a shell would otherwise act on. This is
    /// for text being typed into a live buffer, where the user may still edit
    /// it, so it escapes rather than wrapping the whole thing in quotes.
    private static func shellEscape(_ path: String) -> String {
        let unsafe = Set(#"\ ()[]{}<>"'`!#$&;|*?"# + "\t")
        var result = ""
        result.reserveCapacity(path.count)
        for character in path {
            if unsafe.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
