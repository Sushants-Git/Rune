import Cocoa
import GhosttyKit
import OSLog

let log = Logger(subsystem: "com.kterm", category: "kterm")

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

/// Things libghostty asks the host application to do that kterm itself must
/// decide on (window/tab management, quitting, and so on).
@MainActor
protocol GhosttyAppDelegate: AnyObject {
    func ghosttyNewTab(from surface: ghostty_surface_t?)
    func ghosttyNewWindow(from surface: ghostty_surface_t?)
    func ghosttyCloseSurface(_ view: GhosttySurfaceView, processAlive: Bool)
    func ghosttyQuit()
    func ghosttyGotoTab(_ target: ghostty_action_goto_tab_e, from surface: ghostty_surface_t?)
    func ghosttyToggleCommandPalette(from surface: ghostty_surface_t?)
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
        var argv = CommandLine.unsafeArgv
        if ghostty_init(UInt(CommandLine.argc), argv) != GHOSTTY_SUCCESS {
            throw GhosttyError.initFailed
        }
        _ = argv // silence unused-mutation warning; ghostty_init takes char**

        guard let cfg = ghostty_config_new() else { throw GhosttyError.configFailed }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        logConfigDiagnostics(cfg)
        self.config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyApp.wakeup(ud) },
            action_cb: { app, target, action in GhosttyApp.action(app, target, action) },
            read_clipboard_cb: { ud, loc, state in GhosttyApp.readClipboard(ud, loc, state) },
            confirm_read_clipboard_cb: { ud, str, state, req in
                GhosttyApp.confirmReadClipboard(ud, str, state, req)
            },
            write_clipboard_cb: { ud, loc, content, len, confirm in
                GhosttyApp.writeClipboard(ud, loc, content, len, confirm)
            },
            close_surface_cb: { ud, alive in GhosttyApp.closeSurface(ud, alive) }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else { throw GhosttyError.appFailed }
        self.app = app

        ghostty_app_set_focus(app, NSApp.isActive)
    }

    deinit {
        // ghostty_app_free must run on the main thread, and by the time this
        // object dies the app is tearing down anyway.
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
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

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    /// True when libghostty's config binds this key event to an action. kterm
    /// checks its own bindings first, then defers to this.
    func isBinding(_ event: NSEvent) -> Bool {
        guard let config else { return false }
        var key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
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

    // MARK: - Runtime callbacks (called from libghostty, possibly off-main)

    private static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// libghostty needs a tick. This can arrive on any thread, so bounce to main.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let app = from(userdata) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { app.tick() } }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                view.ghosttyApp?.delegate?.ghosttyCloseSurface(view, processAlive: processAlive)
            }
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata else { return false }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
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

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ string: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        // kterm trusts the clipboard; a confirmation UI can come later.
        guard let userdata, let string else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return }
        ghostty_surface_complete_clipboard_request(surface, string, state, true)
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int,
        _ confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }

        // Take the first text/plain entry; that's all kterm writes today.
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

    private static func action(
        _ cApp: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        guard let cApp, let ud = ghostty_app_userdata(cApp) else { return false }
        let app = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
        return MainActor.assumeIsolated { app.handle(target, action) }
    }

    private func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
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

        case GHOSTTY_ACTION_PWD:
            guard let cPwd = action.action.pwd.pwd else { return false }
            view(for: surface)?.setPwd(String(cString: cPwd))
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

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health != GHOSTTY_RENDERER_HEALTH_OK {
                log.error("renderer unhealthy")
            }
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            let size = action.action.initial_size
            view(for: surface)?.applyInitialSize(
                width: Int(size.width), height: Int(size.height))
            return true

        default:
            // Everything else is either unsupported in kterm or a no-op.
            return false
        }
    }
}
