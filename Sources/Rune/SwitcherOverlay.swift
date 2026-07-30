import Cocoa

/// The dimmed backdrop the ⌘K switcher floats on.
///
/// Workspaces all live in the same window, so the switcher can be an ordinary
/// in-window overlay: previewing swaps the terminal underneath it and the panel
/// stays put on top.
@MainActor
final class SwitcherOverlay: NSView {
    let palette: SwitcherPalette

    init(palette: SwitcherPalette) {
        self.palette = palette
        super.init(frame: .zero)

        wantsLayer = true
        // Heavier than it was. The panel is opaque black now, so the backdrop
        // has to carry enough of the terminal away for the panel to sit in
        // front of it rather than dissolve into it.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        palette.translatesAutoresizingMaskIntoConstraints = false
        addSubview(palette)
        NSLayoutConstraint.activate([
            palette.centerXAnchor.constraint(equalTo: centerXAnchor),
            // A little above centre, where the eye already is.
            palette.topAnchor.constraint(equalTo: topAnchor, constant: 96),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Clicking the backdrop dismisses without selecting.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !palette.frame.contains(point) { palette.cancel() }
    }
}
