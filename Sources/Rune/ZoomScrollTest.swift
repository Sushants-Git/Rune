// Temporary diagnostic harness: RUNE_TEST_ZOOM=1 scripts the app through
// split → output → zoom → synthetic scroll and prints what happened, so the
// zoomed-pane scroll bug can be reproduced without synthetic system input
// (which needs accessibility permissions). Delete when the bug is fixed.

import Cocoa
import GhosttyKit

@MainActor
enum ZoomScrollTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNE_TEST_ZOOM"] != nil
    }

    static func run(controller: TerminalController) {
        var t: TimeInterval = 2.0
        func step(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { body() }
        }

        step(0) {
            feed(controller.activeSurface, "seq 1 300")
        }
        step(1.0) {
            controller.splitActiveSurface(.right)
        }
        step(1.0) {
            feed(controller.activeSurface, "seq 400 700")
        }
        step(1.5) {
            print("=== START PAGER ===")
            feed(controller.activeSurface, "seq 400 700 | less --mouse")
        }
        step(1.5) {
            print("=== PAGER IN SPLIT ===")
            report(controller)
            mouseMove(controller)
            scroll(controller)
        }
        step(1.0) {
            print("=== PAGER IN SPLIT, AFTER SCROLL ===")
            report(controller)
            controller.toggleSplitZoom()
        }
        step(1.0) {
            print("=== PAGER ZOOMED ===")
            report(controller)
            mouseMove(controller)
            scroll(controller)
        }
        step(1.0) {
            print("=== PAGER ZOOMED, AFTER SCROLL ===")
            report(controller)
            exit(0)
        }
    }

    private static func feed(_ surface: GhosttySurfaceView?, _ text: String) {
        guard let handle = surface?.surface else {
            print("feed: no surface")
            return
        }
        text.withCString { ptr in
            ghostty_surface_text(handle, ptr, UInt(strlen(ptr)))
        }
        // Text input arrives as a paste, which the shell's line editor holds in
        // the buffer without running — press Return as a real key.
        "\r".withCString { ptr in
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.keycode = 36  // kVK_Return
            key.text = ptr
            key.unshifted_codepoint = 13
            _ = ghostty_surface_key(handle, key)
        }
    }

    /// Tell ghostty the mouse is at the centre of the focused pane, the way
    /// mouseMoved would.
    private static func mouseMove(_ controller: TerminalController) {
        guard let surface = controller.activeSurface, let handle = surface.surface else { return }
        ghostty_surface_mouse_pos(
            handle, Double(surface.bounds.midX), Double(surface.bounds.midY),
            ghostty_input_mods_e(0))
    }

    /// Send a precise scroll-wheel event the way AppKit would: hit-test the
    /// window at the centre of the focused pane, and hand the event to
    /// whatever view that finds.
    private static func scroll(_ controller: TerminalController) {
        guard let window = controller.window,
              let content = window.contentView,
              let surface = controller.activeSurface
        else {
            print("scroll: missing window/surface")
            return
        }

        let centerInContent = content.convert(
            NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), from: surface)
        let hit = content.hitTest(centerInContent)
        print("hitTest at \(centerInContent) -> \(hit.map { String(describing: type(of: $0)) } ?? "nil") (surface? \(hit === surface))")

        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -120, wheel2: 0, wheel3: 0),
            let event = NSEvent(cgEvent: cg)
        else {
            print("scroll: could not build event")
            return
        }
        print("delivering scrollingDeltaY=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas)")
        (hit ?? surface).scrollWheel(with: event)
    }

    /// Frames of every pane in the active tab, plus hit tests across the
    /// window, to see what a scroll at each spot would land on.
    private static func reportAll(_ controller: TerminalController) {
        guard let tab = controller.activeTab, let content = controller.window?.contentView else {
            return
        }
        print("tab.view frame=\(tab.view.frame)")
        for (i, pane) in tab.panes.enumerated() {
            let inTab = tab.view.convert(pane.bounds, from: pane)
            print("pane[\(i)] frame=\(pane.frame) inTab=\(inTab) focused=\(pane.isFocused)")
        }
        for frac in [0.25, 0.5, 0.75, 0.9] {
            let p = NSPoint(x: content.bounds.width * frac, y: content.bounds.height * 0.5)
            let hit = content.hitTest(p)
            print("hitTest x=\(frac) -> \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }

    private static func report(_ controller: TerminalController) {
        guard let surface = controller.activeSurface else {
            print("report: no active surface")
            return
        }
        let pane = surface.superview
        if let window = controller.window {
            print("window frame=\(window.frame) fullscreen=\(window.styleMask.contains(.fullScreen))")
        }
        print("surface frame=\(surface.frame) backing=\(surface.convertToBacking(surface.frame.size)) renders=\(surface.renderCount)")
        print("pane frame=\(pane?.frame ?? .zero) superview=\(pane?.superview.map { String(describing: type(of: $0)) } ?? "nil")")
        let lines = viewportText(surface).split(separator: "\n")
        print("viewport first=\(lines.first.map(String.init) ?? "<empty>") last=\(lines.last.map(String.init) ?? "<empty>") count=\(lines.count)")
    }

    private static func viewportText(_ surface: GhosttySurfaceView) -> String {
        guard let handle = surface.surface else { return "" }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(handle, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(handle, &text) }
        guard let ptr = text.text else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)),
            as: UTF8.self)
    }
}
