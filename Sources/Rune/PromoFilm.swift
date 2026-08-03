// Drives Rune through a scripted demo and records the window, frame by frame.
//
//   RUNE_FILM=1 Rune.app/Contents/MacOS/Rune    # -> /tmp/promo/film/####.png
//
// Captured from the running app rather than mocked up, so what the video shows
// is what the product does — including the thing that's hard to describe in
// words and obvious in motion: arrowing through ⌘K swaps the workspace behind
// the panel, so you see where you're going before you commit.
//
// scripts/make-promo.sh turns these frames into the video.
import Cocoa

@MainActor
enum PromoFilm {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RUNE_FILM"] != nil }

    private static let fps = 30.0
    private static var frame = 0
    private static var output = URL(fileURLWithPath: "/tmp/promo/film")
    private static var timer: Timer?

    /// A beat in the script: when it happens, and a label the compositor turns
    /// into a caption. Recording the timing here means the captions can't drift
    /// out of sync with what's on screen.
    private static var marks: [(frame: Int, caption: String)] = []

    static func run(controller: TerminalController) {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 16:9, so the frames drop into a 1920x1080 video without letterboxing.
        controller.window?.setContentSize(NSSize(width: 1280, height: 720))
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)

        var t = 0.0
        func at(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { body() }
        }
        func caption(_ text: String) { marks.append((frame, text)) }

        // Four workspaces, each somewhere with a different listing, so the
        // preview visibly changes rather than swapping one bare prompt for
        // another.
        at(0.6) {
            for directory in ["/usr/local", "/etc"] {
                controller.newWorkspace(workingDirectory: directory)
                type("ls\n", into: controller)
            }
            controller.newWorkspace(workingDirectory: NSHomeDirectory() + "/Rune")
            type("ls\n", into: controller)
        }

        at(1.4) { startRecording(controller) }
        at(0.4) { caption("A terminal, and three more you can't see.") }

        at(2.0) {
            caption("⌘K")
            controller.showSwitcher()
        }
        at(1.1) { caption("Arrow down — the terminal behind it changes.") }

        // The preview, which is the whole point.
        for _ in 0..<3 {
            at(0.85) { controller.overlay?.palette.moveSelection(by: 1) }
        }

        at(0.9) {
            caption("⏎ keeps it. ⎋ puts you back.")
            controller.overlay?.palette.commit()
        }

        at(1.3) {
            caption("⌘D splits it.")
            controller.splitActiveSurface(.right)
            type("ls\n", into: controller)
        }
        at(1.6) {
            caption("⌘⇧↵ zooms one pane full.")
            controller.toggleSplitZoom()
        }
        at(1.5) { controller.toggleSplitZoom() }

        at(1.2) {
            caption("⌘T for a tab, in the title bar.")
            controller.newTab(workingDirectory: "/usr/share")
            type("ls\n", into: controller)
        }

        at(1.8) {
            caption("Every row says what its agent is doing.")
            controller.showSwitcher()
        }
        at(2.2) { finish() }
    }

    // MARK: - Recording

    private static func startRecording(_ controller: TerminalController) {
        guard let content = controller.window?.contentView else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                else { return }
                content.cacheDisplay(in: content.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: output.appendingPathComponent(
                    String(format: "%04d.png", frame)))
                frame += 1
            }
        }
    }

    private static func finish() {
        timer?.invalidate()
        // The compositor reads this rather than being told the timings twice.
        let script = marks.map { ["frame": $0.frame, "caption": $0.caption] as [String: Any] }
        let payload: [String: Any] = ["fps": fps, "frames": frame, "marks": script]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: output.appendingPathComponent("script.json"))
        }
        print("captured \(frame) frames at \(Int(fps))fps -> \(output.path)")
        print("=== DONE ===")
        exit(0)
    }

    // MARK: - Typing

    /// Keycodes for the handful of characters the script types. libghostty
    /// translates a *physical* key, so a character alone isn't enough.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        " ": 49, "\n": 36, ".": 47, "/": 44, "-": 27,
    ]

    private static func type(_ string: String, into controller: TerminalController) {
        guard let surface = controller.activeSurface else { return }
        for character in string {
            guard let code = keyCodes[character] else { continue }
            let characters = character == "\n" ? "\r" : String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: surface.window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)
            else { continue }
            surface.keyDown(with: event)
        }
    }
}
