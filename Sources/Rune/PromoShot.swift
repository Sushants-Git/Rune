// Renders the ⌘K panel on its own, for the promo video and for screenshots.
//
//   RUNE_PROMO=1 Rune.app/Contents/MacOS/Rune   # -> /tmp/promo/switcher.png
//
// Kept because scripts/make-promo.sh needs it, and because a picture of the
// switcher is the one thing that explains Rune faster than a paragraph does.
// The rows are fabricated — a real one would show whatever happened to be
// running — but the view is the real view, so the pixels can't drift from the
// product the way a mockup would.
import Cocoa

@MainActor
enum PromoShot {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNE_PROMO"] != nil
    }

    static func run() {
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

        let palette = SwitcherPalette(
            items: { items }, onPreview: { _ in }, onCommit: { _ in }, onCancel: {})
        palette.frame = NSRect(x: 0, y: 0, width: SwitcherPalette.width, height: 400)
        palette.layoutSubtreeIfNeeded()

        let size = palette.fittingSize
        palette.frame = NSRect(origin: .zero, size: size)
        palette.layoutSubtreeIfNeeded()

        // Rendered at 2x: the video scales this panel up to fill most of a
        // 1920 frame, and a 1x capture turns to mush on the way.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { exit(1) }
        rep.size = size
        palette.cacheDisplay(in: palette.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        let out = URL(fileURLWithPath: "/tmp/promo/switcher.png")
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: out)
        print("switcher \(Int(size.width))x\(Int(size.height)) -> \(out.path)")
        print("=== DONE ===")
        exit(0)
    }

    private static func row(
        _ title: String, _ subtitle: String, _ agent: AgentIcon?, _ status: Status,
        current: Bool = false, pinned: Bool = false, zoomed: Bool = false,
        notifies: Bool = false
    ) -> PaletteItem {
        PaletteItem(
            title: title, subtitle: subtitle, badge: nil,
            isCurrent: current, isPinned: pinned, isZoomed: zoomed,
            icon: agent?.image, status: status,
            searchText: title, editableName: "", automaticTitle: title,
            bell: notifies ? .once : .off)
    }
}
