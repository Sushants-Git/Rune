// Renders the pickers on their own, for the promo video, for screenshots, and
// for looking at a panel without having to drive the app to get to it.
//
//   RUNE_PROMO=1        Rune.app/Contents/MacOS/Rune   # -> /tmp/promo/switcher.png
//   RUNE_PROMO=windows  …                              # -> /tmp/promo/windows.png
//   RUNE_PROMO=sessions …                              # -> /tmp/promo/sessions.png
//   RUNE_PROMO=all      …                              # all three
//
// Kept because scripts/make-promo.sh needs it, because a picture of the
// switcher is the one thing that explains Rune faster than a paragraph does,
// and because a panel is much easier to get right when you can render it on
// demand instead of opening it, arranging the state it needs, and squinting.
// The rows are fabricated — a real one would show whatever happened to be
// running — but the views are the real views, so the pixels can't drift from
// the product the way a mockup would.
import Cocoa

@MainActor
enum PromoShot {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNE_PROMO"] != nil
    }

    static func run() {
        let requested = ProcessInfo.processInfo.environment["RUNE_PROMO"] ?? "1"
        let panels: [String]
        switch requested {
        case "1", "switcher": panels = ["switcher"]
        case "all": panels = ["switcher", "windows", "sessions"]
        default: panels = [requested]
        }

        for panel in panels where panel != "sessions" {
            switch panel {
            case "switcher": write(switcher(), to: "switcher")
            case "windows": write(windows(), to: "windows")
            default: FileHandle.standardError.write("unknown panel \(panel)\n".data(using: .utf8)!)
            }
        }

        guard panels.contains("sessions") else {
            print("=== DONE ===")
            exit(0)
        }
        // Sessions are discovered off the main actor and the panel fills in
        // when they land, so this one has to be given a moment or the shot is
        // of an empty list saying "Looking…".
        let palette = sessions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            MainActor.assumeIsolated {
                write(palette, to: "sessions")
                print("=== DONE ===")
                exit(0)
            }
        }
    }

    // MARK: - The panels

    private static func switcher() -> NSView {
        // Fabricated rows, but every field is what the real thing shows — the
        // point of the shot is the one question the switcher answers.
        let items: [PaletteItem] = [
            row("rune", "~/", .claude, Status(activity: .waiting, detail: "answer it",
                                              since: Date().addingTimeInterval(-42)),
                pinned: true),
            row("devfolio-api", "~/Workspace", .codex,
                Status(activity: .working, detail: "Running a command",
                       since: Date().addingTimeInterval(-83)),
                notifies: true),
            row("rune-website", "~/", .openCode,
                Status(activity: .working, detail: "Running bash",
                       since: Date().addingTimeInterval(-14))),
            row("notes", "~/Documents", nil, Status(), current: true),
        ]
        return SwitcherPalette(
            items: { items }, onPreview: { _ in }, onCommit: { _ in }, onCancel: {})
    }

    private static func windows() -> NSView {
        let items: [WindowPalette.Item] = [
            WindowPalette.Item(
                number: 1, title: "Window 1",
                workspaces: ["rune", "rune-website"], isCurrent: true,
                icon: AgentIcon.claude.image(onDark: true),
                entries: [
                    WindowPalette.Entry(title: "rune", subtitle: "tab 1 · claude",
                                        isCurrent: true, icon: AgentIcon.claude.image(onDark: true)),
                    WindowPalette.Entry(title: "rune", subtitle: "tab 2 · zsh",
                                        isCurrent: false, icon: nil),
                    WindowPalette.Entry(title: "rune-website", subtitle: "~/Workspace",
                                        isCurrent: false, icon: AgentIcon.openCode.image(onDark: true)),
                ]),
            WindowPalette.Item(
                number: 2, title: "Window 2",
                workspaces: ["devfolio-api"], isCurrent: false,
                icon: AgentIcon.codex.image(onDark: true),
                entries: [
                    WindowPalette.Entry(title: "devfolio-api", subtitle: "~/Workspace",
                                        isCurrent: true, icon: AgentIcon.codex.image(onDark: true)),
                ]),
        ]
        return WindowPalette(
            items: items, onPreview: { _, _ in }, onCommit: { _, _ in }, onCancel: {})
    }

    private static func sessions() -> NSView {
        let live: [AgentHistory.Session] = [
            .live(target: UUID(), title: "Revamp the pickers",
                  directory: NSHomeDirectory() + "/Rune", agent: .claude),
            .live(target: UUID(), title: "zsh", directory: NSHomeDirectory()),
        ]
        return SessionPalette(sessions: live, onSelect: { _ in }, onCancel: {})
    }

    // MARK: - Rendering

    private static func write(_ view: NSView, to name: String) {
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        // Rendered at 2x: the video scales these panels up to fill most of a
        // 1920 frame, and a 1x capture turns to mush on the way.
        func bitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = size
            return rep
        }
        guard let panel = bitmap(), let sheet = bitmap() else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: panel)

        // On a plate, because a panel is glass: its backdrop samples a window
        // that isn't there when it's rendered on its own, so a bare capture
        // comes out as a scrim over nothing and tells you nothing about
        // contrast. This stands in for the terminal underneath.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        panel.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = sheet.representation(using: .png, properties: [:]) else { exit(1) }
        let out = URL(fileURLWithPath: "/tmp/promo/\(name).png")
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: out)
        print("\(name) \(Int(size.width))x\(Int(size.height)) -> \(out.path)")
    }

    private static func row(
        _ title: String, _ subtitle: String, _ agent: AgentIcon?, _ status: Status,
        current: Bool = false, pinned: Bool = false, zoomed: Bool = false,
        notifies: Bool = false
    ) -> PaletteItem {
        PaletteItem(
            title: title, subtitle: subtitle, badge: nil,
            isCurrent: current, isPinned: pinned, isZoomed: zoomed,
            icon: agent?.image(onDark: true), status: status,
            searchText: title, editableName: "", automaticTitle: title,
            bell: notifies ? .once : .off)
    }
}
