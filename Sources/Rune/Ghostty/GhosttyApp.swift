import Cocoa
import GhosttyKit
import OSLog

let log = Logger(subsystem: "com.rune", category: "Rune")

/// Errors surfaced while bringing libghostty up.
enum GhosttyError: Error, CustomStringConvertible {
    case initFailed
    case configFailed
    case appFailed
    case surfaceFailed

    var description: String {
        switch self {
        case .initFailed: "ghostty_init failed"
        case .configFailed: "ghostty_config_new failed"
        case .appFailed: "ghostty_app_new failed"
        case .surfaceFailed: "ghostty_surface_new failed"
        }
    }
}

/// Things libghostty asks the host application to do that Rune itself must
/// decide on (window/tab management, quitting, and so on).
@MainActor
protocol GhosttyAppDelegate: AnyObject {
    func ghosttyNewTab(from surface: ghostty_surface_t?)
    func ghosttyNewWindow(from surface: ghostty_surface_t?)
    func ghosttyCloseSurface(_ view: GhosttySurfaceView, processAlive: Bool)
    func ghosttyQuit()
    func ghosttyGotoTab(_ target: ghostty_action_goto_tab_e, from surface: ghostty_surface_t?)
    func ghosttyToggleCommandPalette(from surface: ghostty_surface_t?)
    func ghosttyNewSplit(
        _ direction: ghostty_action_split_direction_e, from surface: ghostty_surface_t?)
    func ghosttyGotoSplit(
        _ target: ghostty_action_goto_split_e, from surface: ghostty_surface_t?)
    func ghosttyResizeSplit(
        _ direction: ghostty_action_resize_split_direction_e,
        amount: UInt16,
        from surface: ghostty_surface_t?)
    func ghosttyEqualizeSplits(from surface: ghostty_surface_t?)
    func ghosttyToggleSplitZoom(from surface: ghostty_surface_t?)
}

/// Owns the single global `ghostty_app_t` and the libghostty runtime callbacks.
@MainActor
final class GhosttyApp {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    weak var delegate: GhosttyAppDelegate?

    /// All live surface views, keyed by the `ghostty_surface_t` pointer, so the
    /// C callbacks can find their way back to a Swift object.
    private var surfaces: [OpaquePointer: GhosttySurfaceView] = [:]

    init() throws {
        // libghostty wants the real argv so it can honor CLI overrides.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            throw GhosttyError.initFailed
        }

        guard let cfg = ghostty_config_new() else { throw GhosttyError.configFailed }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        logConfigDiagnostics(cfg)
        self.config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            // These are passed as bare C function pointers rather than closure
            // literals: a closure written here would inherit this class's
            // @MainActor isolation, and libghostty calls several of them from
            // its own threads.
            wakeup_cb: runeWakeup,
            action_cb: runeAction,
            read_clipboard_cb: runeReadClipboard,
            confirm_read_clipboard_cb: runeConfirmReadClipboard,
            write_clipboard_cb: runeWriteClipboard,
            close_surface_cb: runeCloseSurface
        )

        guard let app = ghostty_app_new(&runtime, cfg) else { throw GhosttyError.appFailed }
        self.app = app

        ghostty_app_set_focus(app, NSApp.isActive)
    }

    /// Posted after the config file has been re-read and pushed to libghostty.
    /// Chrome painted from the terminal's colours has to catch up.
    static let configReloaded = Notification.Name("RuneGhosttyConfigReloaded")

    /// Re-read the config files and hand the result to libghostty.
    ///
    /// A fresh `ghostty_config_t` rather than a mutation of the live one: there
    /// is no C API for unsetting a key, so the only way to see a key that was
    /// *deleted* from the file is to build the config again from nothing.
    ///
    /// The old config is freed last. `ghostty_app_update_config` and its
    /// surface counterpart copy what they need, but freeing first would mean a
    /// window where the app holds a pointer to memory that is already gone.
    @discardableResult
    func reloadConfig() -> Bool {
        guard let app else { return false }
        guard let next = ghostty_config_new() else { return false }
        ghostty_config_load_default_files(next)
        ghostty_config_load_recursive_files(next)
        ghostty_config_finalize(next)
        logConfigDiagnostics(next)

        ghostty_app_update_config(app, next)
        for view in surfaces.values {
            guard let surface = view.surface else { continue }
            ghostty_surface_update_config(surface, next)
        }

        let previous = config
        config = next
        if let previous { ghostty_config_free(previous) }

        // Hand every surface the new background as well.
        //
        // A surface caches this, and the only thing that used to update the
        // cache was libghostty reporting a colour change — which is how a
        // program setting its own background via OSC 11 gets through, and not
        // something a config reload sends. Rune paints its title bar and tab
        // strip from that cache, so a new theme repainted the terminal and left
        // the chrome above it in the old one until the surface was rebuilt.
        // Anything the program sets afterwards still wins; this only resets the
        // starting point to what the config now says.
        let background = backgroundColor
        for view in surfaces.values { view.setBackgroundColor(background) }

        NotificationCenter.default.post(name: Self.configReloaded, object: nil)
        return true
    }

    /// Whether the last reload turned up anything Ghostty could not parse, and
    /// what it said. Shown in the settings window — a config error that only
    /// reaches the system log is a config error nobody sees.
    func configDiagnostics() -> [String] {
        guard let config else { return [] }
        let count = ghostty_config_diagnostics_count(config)
        return (0..<count).compactMap { index in
            guard let message = ghostty_config_get_diagnostic(config, index).message
            else { return nil }
            return String(cString: message)
        }
    }

    /// Release libghostty. Called on app termination — these frees must happen
    /// on the main thread, so this can't live in `deinit`.
    func shutdown() {
        if let app {
            self.app = nil
            ghostty_app_free(app)
        }
        if let config {
            self.config = nil
            ghostty_config_free(config)
        }
    }

    // MARK: - Surface registry

    func register(_ view: GhosttySurfaceView, for surface: ghostty_surface_t) {
        surfaces[OpaquePointer(surface)] = view
    }

    func unregister(_ surface: ghostty_surface_t) {
        surfaces.removeValue(forKey: OpaquePointer(surface))
    }

    func view(for surface: ghostty_surface_t?) -> GhosttySurfaceView? {
        guard let surface else { return nil }
        return surfaces[OpaquePointer(surface)]
    }

    // MARK: - Lifecycle

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    /// The configured terminal background. Rune paints its own chrome with
    /// this so the title bar doesn't sit as a grey band above the terminal.
    var backgroundColor: NSColor {
        guard let config else { return .black }
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return .black }
        return NSColor(ghostty: color)
    }

    /// Any colour the config names, or nil when it does not name one.
    ///
    /// Same shape as `backgroundColor`, but nil-returning: a preview that drew
    /// black text because it asked for a key the theme leaves unset would be
    /// showing something the terminal will never do.
    func color(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(ghostty: value)
    }

    /// The terminal's own font, so the diff can be set in it.
    ///
    /// Strings come back from libghostty as a borrowed `char *`, which is why
    /// this copies rather than holding the pointer: the config owns it and will
    /// free it on the next reload.
    var fontFamily: String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "font-family"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value
        else { return nil }
        let name = String(cString: value)
        return name.isEmpty ? nil : name
    }

    /// `background-opacity`, which the renderer already honours when it draws.
    /// What it cannot do from inside the surface is make the window behind it
    /// stop being opaque, which is the other half of a translucent terminal.
    ///
    /// Read from the config file rather than through `ghostty_config_get`.
    /// Asking libghostty for this key by name kills the process — no message,
    /// no crash report, exit code 6 from inside window creation — so the value
    /// comes from the same file the settings pane reads and writes.
    var backgroundOpacity: Double {
        guard let raw = GhosttyConfigFile(url: GhosttyConfigFile.location)
            .value(for: "background-opacity"),
            let value = Double(raw)
        else { return 1 }
        return max(0, min(1, value))
    }

    /// `font-size` is an `f32` in Ghostty's config, so it is read as one.
    var fontSize: Double? {
        guard let config else { return nil }
        var value: Float = 0
        let key = "font-size"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), value > 0
        else { return nil }
        return Double(value)
    }

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    /// True when libghostty's config binds this key event to an action. Rune
    /// checks its own bindings first, then defers to this.
    func isBinding(_ event: NSEvent) -> Bool {
        guard let config else { return false }
        let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        return ghostty_config_key_is_binding(config, key)
    }

    private func logConfigDiagnostics(_ cfg: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(cfg)
        guard count > 0 else { return }
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            guard let msg = diag.message else { continue }
            log.warning("ghostty config: \(String(cString: msg), privacy: .public)")
        }
    }

    fileprivate func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let surface: ghostty_surface_t? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface
            : nil

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            view(for: surface)?.requestRender()
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let cTitle = action.action.set_title.title else { return false }
            view(for: surface)?.setTitle(String(cString: cTitle))
            return true

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let cTitle = action.action.set_tab_title.title else { return false }
            view(for: surface)?.setTitle(String(cString: cTitle))
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            view(for: surface)?.onSearchStart?(needle)
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            view(for: surface)?.clearSearchState()
            view(for: surface)?.onSearchEnd?()
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            // Negative is the core's "no answer yet", not a count.
            let total = action.action.search_total.total
            view(for: surface)?.setSearchTotal(total < 0 ? nil : Int(total))
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            view(for: surface)?.setSearchSelected(selected < 0 ? nil : Int(selected))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let cPwd = action.action.pwd.pwd else { return false }
            view(for: surface)?.setPwd(String(cString: cPwd))
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            // A program (or a theme) can change the background at runtime, and
            // the title bar is painted to match, so follow it.
            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return true }
            view(for: surface)?.setBackgroundColor(
                NSColor(srgbRed: Double(change.r) / 255,
                        green: Double(change.g) / 255,
                        blue: Double(change.b) / 255,
                        alpha: 1))
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            view(for: surface)?.cellSize = CGSize(
                width: Double(size.width), height: Double(size.height))
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view(for: surface)?.setMouseShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            view(for: surface)?.setMouseVisibility(
                action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            delegate?.ghosttyNewTab(from: surface)
            return true

        case GHOSTTY_ACTION_NEW_WINDOW:
            delegate?.ghosttyNewWindow(from: surface)
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            delegate?.ghosttyGotoTab(action.action.goto_tab, from: surface)
            return true

        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            delegate?.ghosttyToggleCommandPalette(from: surface)
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            delegate?.ghosttyNewSplit(action.action.new_split, from: surface)
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            delegate?.ghosttyGotoSplit(action.action.goto_split, from: surface)
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            delegate?.ghosttyResizeSplit(
                resize.direction, amount: resize.amount, from: surface)
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            delegate?.ghosttyEqualizeSplits(from: surface)
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            delegate?.ghosttyToggleSplitZoom(from: surface)
            return true

        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            if let view = view(for: surface) {
                delegate?.ghosttyCloseSurface(view, processAlive: false)
            }
            return true

        case GHOSTTY_ACTION_QUIT:
            delegate?.ghosttyQuit()
            return true

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            view(for: surface)?.window?.toggleFullScreen(nil)
            return true

        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
            view(for: surface)?.window?.zoom(nil)
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // OSC 9 / 99 / 777. This is the agent *telling* Rune it wants you,
            // rather than Rune working it out — Claude Code emits one when it
            // needs input, and anything with a hook system can be pointed at
            // the same sequence. It costs nothing and it's exact, so it
            // outranks everything Rune infers for itself.
            let notification = action.action.desktop_notification
            view(for: surface)?.notify(
                title: notification.title.map { String(cString: $0) },
                body: notification.body.map { String(cString: $0) })
            return true

        case GHOSTTY_ACTION_RING_BELL:
            // The cruder version of the same thing, for agents that only ring.
            view(for: surface)?.ringBell()
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health != GHOSTTY_RENDERER_HEALTH_HEALTHY {
                log.error("renderer unhealthy")
            }
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            let size = action.action.initial_size
            view(for: surface)?.applyInitialSize(
                width: Int(size.width), height: Int(size.height))
            return true

        default:
            // Everything else is either unsupported in Rune or a no-op.
            return false
        }
    }
}

// MARK: - Colors

extension NSColor {
    convenience init(ghostty color: ghostty_config_color_s) {
        self.init(
            srgbRed: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255,
            alpha: 1)
    }

    /// Whether chrome drawn against this colour needs light-on-dark treatment.
    /// Perceived luminance, not raw brightness.
    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        let luminance =
            0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5
    }
}

// MARK: - Runtime callbacks
//
// libghostty invokes these from its own threads, so they live at file scope
// where they carry no actor isolation. Anything touching app or view state
// hops to the main actor first.

private func runeApp(_ userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
}

/// libghostty needs a tick. This can arrive on any thread, so bounce to main.
private func runeWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let app = runeApp(userdata) else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { app.tick() } }
}

private func runeCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            view.ghosttyApp?.delegate?.ghosttyCloseSurface(view, processAlive: processAlive)
        }
    }
}

private func runeReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    // libghostty's request token: opaque to us, never read or written through
    // here, and handed straight back to the call that completes the request.
    // Carrying it onto the main actor is safe in a way the compiler can't see.
    nonisolated(unsafe) let state = state
    // Answered inline rather than dispatched: libghostty wants the clipboard
    // handed back before this returns, and it asks on the thread driving the
    // surface — the main one. Same bargain as runeAction below.
    return MainActor.assumeIsolated {
        guard let surface = view.surface else { return false }

        let pasteboard: NSPasteboard = location == GHOSTTY_CLIPBOARD_STANDARD
            ? .general
            : .init(name: .find)
        let str = pasteboard.string(forType: .string) ?? ""

        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }
}

private func runeConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    // Rune trusts the clipboard; a confirmation UI can come later.
    guard let userdata, let string else { return }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    // Both belong to libghostty and outlive this call; see runeReadClipboard.
    nonisolated(unsafe) let token = state
    nonisolated(unsafe) let text = string
    MainActor.assumeIsolated {
        guard let surface = view.surface else { return }
        ghostty_surface_complete_clipboard_request(surface, text, token, true)
    }
}

private func runeWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard let content, len > 0 else { return }
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }

    // Take the first text/plain entry; that's all Rune writes today.
    var text: String?
    for i in 0..<len {
        let item = content[i]
        guard let data = item.data else { continue }
        let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
        if mime.hasPrefix("text/plain") {
            text = String(cString: data)
            break
        }
    }
    guard let text else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(text, forType: .string)
}

private func runeAction(
    _ cApp: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let cApp, let ud = ghostty_app_userdata(cApp) else { return false }
    let app = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
    return MainActor.assumeIsolated { app.handle(target, action) }
}
