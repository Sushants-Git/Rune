// Drives Rune through a scripted demo and records the window, frame by frame.
//
//   RUNE_FILM=1 Rune.app/Contents/MacOS/Rune    # -> /tmp/promo/film/####.png
//
// Strip CLAUDE* from the environment first if you are recording from inside a
// Claude Code session, or claude prints a transcript warning across the bottom
// of every frame. Strip it in the launching shell — calling `unsetenv` in here
// reallocates `environ` out from under libghostty, and the next surface it
// spawns takes the process down with it.
//
// Two things make this worth the machinery over a mockup. The agents are real:
// the script starts claude, codex and opencode in real projects and asks them
// real questions, then waits for them to get to work before the camera rolls,
// so the status the switcher reports is status Rune actually read. And the
// preview is real: arrowing through ⌘K swaps the workspace behind the panel,
// which is the thing that's hard to write down and obvious in motion.
//
// Beats are paced text-first — a caption lands, the frame holds still long
// enough to read it, and only then does anything move. Reading and watching at
// the same time is work; this way you do them in turn.
//
// scripts/make-promo.sh turns these frames into the video.
import Cocoa

@MainActor
enum PromoFilm {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RUNE_FILM"] != nil }

    private static var frame = 0
    private static var output = URL(fileURLWithPath: "/tmp/promo/film")
    private static var timer: Timer?

    /// When each captured frame happened, in seconds from the first one.
    ///
    /// Capturing a live terminal doesn't keep to a metronome — the tick is
    /// 30fps but the real rate sags well below it. Stamping each frame lets the
    /// compositor resample to real time, so the video runs at the speed the
    /// demo ran at instead of however fast the capture managed.
    private static var times: [Double] = []
    private static var started = Date()

    /// A beat in the script: when it happens, the shortcut that caused it, and
    /// a line about what it did. Recording the timing here means the captions
    /// can't drift out of sync with what's on screen.
    private static var marks: [(time: Double, key: String?, caption: String)] = []

    /// PNG encoding is most of the cost of a frame, and it doesn't need the
    /// main thread — only the capture itself does.
    ///
    /// Concurrent, and with a ceiling on how far behind it may fall. One serial
    /// queue couldn't keep up with a 2560x1440 frame every 40ms: the backlog
    /// grew until the memory it was holding dragged the whole app down, and
    /// capture collapsed to 4fps by the end of a take. Past `maxInFlight` the
    /// tick drops its frame instead of queueing it — a gap the timestamps
    /// already account for, and far cheaper than the alternative.
    private static let encoder = DispatchQueue(
        label: "rune.promo.encode", attributes: .concurrent)
    private static let maxInFlight = 12
    private static var inFlight = 0
    private struct Capture: @unchecked Sendable {
        let rep: NSBitmapImageRep
        let index: Int
    }

    private static let home = NSHomeDirectory()

    static func run(controller: TerminalController) {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 16:9, so the frames drop into a 1920x1080 video without letterboxing,
        // and sized to the exact width the compositor draws the window at so no
        // rescaling ever touches terminal text. See `startRecording` for why the
        // capture is 1:1 rather than at the display's 2x.
        controller.window?.setContentSize(NSSize(width: 1400, height: 787.5))
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)

        var t = 0.0
        func at(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { body() }
        }
        func caption(_ key: String?, _ text: String) {
            marks.append((Date().timeIntervalSince(started), key, text))
        }

        // MARK: Boot — off camera

        // One agent each, in a real project, plus a plain shell: Rune is a
        // terminal that knows about agents, not an agent launcher.
        //
        // RUNE_FILM_QUICK swaps the agents for plain shells — the beats and the
        // framing can be iterated on without waiting on three models or paying
        // for the tokens. It makes a rehearsal, never the finished video.
        let quick = ProcessInfo.processInfo.environment["RUNE_FILM_QUICK"] != nil
        at(0.5) { type(quick ? "ls\n" : "claude\n", into: controller) }
        at(0.6) {
            _ = controller.newWorkspace(workingDirectory: home + "/rune_website")
            type(quick ? "ls\n" : "codex\n", into: controller)
        }
        at(0.6) {
            _ = controller.newWorkspace(workingDirectory: home + "/Workspace/icon-editor")
            type(quick ? "ls\n" : "opencode\n", into: controller)
        }
        at(0.6) {
            _ = controller.newWorkspace(workingDirectory: "/usr/local")
            type("ls\n", into: controller)
        }

        // Long enough for three TUIs to finish drawing themselves.
        //
        // The order below is picked around two constraints that fight. Claude's
        // welcome banner carries the signed-in account's email address and has
        // to be gone before the camera rolls; and an agent streaming output
        // during the take drops the capture from 26fps to 5, because every
        // frame makes AppKit read all four Metal surfaces back. So claude and
        // codex are asked early and given time to finish, claude's screen is
        // cleared outright rather than scrolled, and only opencode — the
        // slowest of the three — is still going when recording starts.
        at(quick ? 0.5 : 12.0) {
            guard !quick else { return }
            ask(controller, workspace: 0,
                "in three paragraphs why is running several coding agents at once hard")
        }
        at(quick ? 0 : 1.0) {
            guard !quick else { return }
            ask(controller, workspace: 1, "list the pages in this site")
        }

        // Ctrl-L, once the answer is in: claude clears its screen and the
        // banner goes with it. Scrolling it off by asking for more output very
        // nearly worked, which is worse than not working — it left the email
        // sitting on the last visible row.
        at(quick ? 0 : 40.0) {
            guard !quick else { return }
            controller.selectWorkspace(at: 0)
            if let surface = controller.activeSurface { control("l", into: surface) }
        }
        at(quick ? 0 : 2.0) {
            guard !quick else { return }
            ask(controller, workspace: 0, "and which of those is hardest to fix")
        }

        // Opencode is left with a fresh session and no question. The account
        // behind it is out of API credits, and asking puts a billing error on
        // screen; idle, the row still proves Rune reads opencode's state.
        //
        // Codex gets a second question instead, close enough to the take that
        // it is still answering — so one row reads "working" rather than the
        // whole list saying "your turn".
        at(quick ? 0 : 20.0) {
            guard !quick else { return }
            ask(controller, workspace: 1, "and which section matters most")
        }

        at(quick ? 1.0 : 7.0) {
            controller.selectWorkspace(at: 0)
            startRecording(controller)
        }

        // MARK: The demo

        at(0.4) { caption(nil, "A terminal. Three more you can't see.") }

        at(1.6) { caption("⌘K", "every workspace, in one list") }
        at(0.45) { controller.showSwitcher() }

        at(1.9) { caption(nil, "Each row says what its agent is doing.") }

        at(2.0) { caption("↓", "the terminal behind it changes") }
        at(0.6) { controller.overlay?.palette.moveSelection(by: 1) }
        at(0.9) { controller.overlay?.palette.moveSelection(by: 1) }
        // And back up one, which is the honest way to use it: look at a couple,
        // then land on the one you meant.
        at(0.9) { controller.overlay?.palette.moveSelection(by: -1) }

        at(1.1) { caption("⏎", "jump there") }
        at(0.45) { controller.overlay?.palette.commit() }

        // Held on to so the zoom can go back to the pane with the agent in it.
        // Zooming the shell we just opened is technically the same feature and
        // looks like nothing happened — a bigger empty rectangle.
        var agentPane: GhosttySurfaceView?

        at(1.4) { caption("⌘D", "split the pane") }
        at(0.45) {
            agentPane = controller.activeSurface
            controller.splitActiveSurface(.right)
            type("ls\n", into: controller)
        }

        at(1.4) { caption("⌘⇧↵", "zoom one pane full") }
        at(0.45) {
            if let agentPane { controller.focus(agentPane) }
            controller.toggleSplitZoom()
        }
        at(1.4) { controller.toggleSplitZoom() }

        at(0.8) { caption("⌘T", "tabs live in the title bar") }
        at(0.45) { _ = controller.newTab(workingDirectory: "/usr/share") }
        // The shell needs a moment before it will take input; typing with the
        // tab is how the last take ended on an empty terminal.
        at(0.6) { type("ls\n", into: controller) }

        at(1.6) { finish() }
    }

    /// Puts a question to the agent in a given workspace. Selecting first,
    /// because `type` goes to whatever surface is focused.
    ///
    /// The Return goes in a later turn of the run loop, and to the surface
    /// directly rather than to whatever is focused by then. A TUI that reads
    /// the whole paste in one go treats a trailing Return as part of the text
    /// and leaves the question sitting in the box unsent — which is exactly
    /// what claude did, on about half of the takes.
    private static func ask(_ controller: TerminalController, workspace: Int, _ prompt: String) {
        controller.selectWorkspace(at: workspace)
        guard let surface = controller.activeSurface else { return }
        type(prompt, into: surface)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            MainActor.assumeIsolated { type("\n", into: surface) }
        }
    }

    // MARK: - Recording

    private static func startRecording(_ controller: TerminalController) {
        guard let content = controller.window?.contentView else { return }
        started = Date()
        // 1:1, not the display's 2x. `cacheDisplay` reads every Metal surface
        // in the window back into a bitmap, and at 2x that costs four times as
        // much for pixels the 1080p output throws away — with three agents
        // streaming output it dragged the capture down to 4fps. The window is
        // already sized to the width the video draws it at, so this is the
        // resolution the frame actually needs.
        let pixels = content.bounds.size
        // Asking for more than we'll get: the tick is the ceiling, and the
        // stamps record what actually happened.
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard inFlight < maxInFlight else { return }
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return }
                rep.size = pixels
                content.cacheDisplay(in: content.bounds, to: rep)
                times.append(Date().timeIntervalSince(started))
                let capture = Capture(rep: rep, index: frame)
                // Named here rather than on the encoder queue: `output` belongs
                // to the main actor, and the frame it goes with is already known.
                let destination = output.appendingPathComponent(
                    String(format: "%04d.png", frame))
                frame += 1
                inFlight += 1
                encoder.async {
                    if let png = capture.rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: destination)
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { inFlight -= 1 } }
                }
            }
        }
    }

    private static func finish() {
        timer?.invalidate()
        encoder.sync(flags: .barrier) {}  // let the last frames land before anyone reads them
        // The compositor reads this rather than being told the timings twice.
        let script = marks.map {
            ["time": $0.time, "key": $0.key as Any, "caption": $0.caption] as [String: Any]
        }
        let payload: [String: Any] = [
            "duration": times.last ?? 0, "times": times, "marks": script,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: output.appendingPathComponent("script.json"))
        }
        let rate = Double(frame) / max(times.last ?? 1, 0.001)
        print(String(format: "captured %d frames over %.1fs (%.0ffps) -> %@",
                     frame, times.last ?? 0, rate, output.path))
        print("=== DONE ===")
        exit(0)
    }

    // MARK: - Typing

    /// Keycodes for the characters the script types. libghostty translates a
    /// *physical* key, so a character alone isn't enough.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        " ": 49, "\n": 36, ".": 47, "/": 44, "-": 27,
    ]

    private static func type(_ string: String, into controller: TerminalController) {
        guard let surface = controller.activeSurface else { return }
        type(string, into: surface)
    }

    /// A control chord — Ctrl-L and friends. The terminal wants the C0 code,
    /// which is the letter with its top three bits cleared.
    private static func control(_ character: Character, into surface: GhosttySurfaceView) {
        guard let code = keyCodes[character],
              let ascii = character.asciiValue,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: surface.window?.windowNumber ?? 0, context: nil,
                characters: String(UnicodeScalar(ascii & 0x1f)),
                charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: code)
        else { return }
        surface.keyDown(with: event)
    }

    private static func type(_ string: String, into surface: GhosttySurfaceView) {
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
