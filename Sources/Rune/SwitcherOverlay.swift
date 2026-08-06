import Cocoa

/// The dimmed backdrop the ⌘K switcher floats on.
///
/// Workspaces all live in the same window, so the switcher can be an ordinary
/// in-window overlay: previewing swaps the terminal underneath it and the panel
/// stays put on top.
///
/// The panel can also be dragged. Grab it anywhere that isn't a row or the
/// search field — its padding, the hint bar — and guides appear. It goes
/// wherever you drop it; the guides are only there to *tell* you when you have
/// lined it up, brightening as the panel meets one. Nothing pulls it, because
/// a magnet that fires when you didn't want it is worse than no magnet, and
/// the position is remembered across launches either way.
@MainActor
final class SwitcherOverlay: NSView {
    let palette: SwitcherPalette

    /// Where the panel sits, as a fraction of the room it has to move in.
    /// (0, 0) is top-left, (1, 1) bottom-right, (0.5, 0) the default.
    private var anchor: CGPoint {
        didSet {
            guard anchor != oldValue else { return }
            Self.saved = anchor
            applyAnchor()
        }
    }

    /// Distance from the window's edges the panel will not cross.
    private static let margin: CGFloat = 96
    /// Where the guides sit: the edges and the middle of the panel's travel.
    private static let guides: [CGFloat] = [0, 0.5, 1]
    /// How close the panel has to be for a guide to count as met. Pixels, not
    /// a fraction of the travel, so it feels the same in a small window as a
    /// wide one.
    private static let alignment: CGFloat = 4

    private var horizontal: NSLayoutConstraint!
    private var vertical: NSLayoutConstraint!

    /// Set while a drag is in flight, which is the only time the guides show.
    private var dragOrigin: CGPoint?
    private var isDragging = false { didSet { needsDisplay = true } }

    // MARK: - Remembered position

    private static let anchorKey = "RuneSwitcherAnchor"

    private static var saved: CGPoint {
        get {
            guard let pair = UserDefaults.standard.array(forKey: anchorKey) as? [Double],
                  pair.count == 2
            else { return CGPoint(x: 0.5, y: 0) }
            return CGPoint(x: pair[0], y: pair[1])
        }
        set {
            UserDefaults.standard.set([newValue.x, newValue.y], forKey: anchorKey)
        }
    }

    init(palette: SwitcherPalette) {
        self.palette = palette
        self.anchor = Self.saved
        super.init(frame: .zero)

        wantsLayer = true
        // Heavier than it was. The panel is opaque black now, so the backdrop
        // has to carry enough of the terminal away for the panel to sit in
        // front of it rather than dissolve into it.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        palette.translatesAutoresizingMaskIntoConstraints = false
        addSubview(palette)
        horizontal = palette.centerXAnchor.constraint(equalTo: centerXAnchor)
        vertical = palette.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([horizontal, vertical])
        applyAnchor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        applyAnchor()
    }

    /// How far the panel may travel on each axis before it hits the margins.
    private var travel: CGSize {
        CGSize(
            width: max(0, bounds.width - palette.frame.width - Self.margin * 2),
            height: max(0, bounds.height - palette.frame.height - Self.margin * 2))
    }

    private func applyAnchor() {
        let travel = self.travel
        horizontal.constant = (anchor.x - 0.5) * travel.width
        vertical.constant = Self.margin + anchor.y * travel.height
    }

    // MARK: - Dragging

    // Clicks land here rather than on the panel because the panel's background
    // is inert — rows and the search field handle their own, and everything
    // else falls through to the overlay. So this is both "dismiss" and "drag"
    // without either having to know about the other.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard palette.frame.contains(point) else {
            palette.cancel()
            return
        }
        dragOrigin = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        // A few pixels of slack, so a click that trembles is still a click.
        if !isDragging, hypot(point.x - origin.x, point.y - origin.y) < 4 { return }
        isDragging = true

        let travel = self.travel
        guard travel.width > 0 || travel.height > 0 else { return }
        // Straight to the pointer, and it stays where it is let go. The guides
        // report alignment; they do not cause it.
        let dx = travel.width > 0 ? (point.x - origin.x) / travel.width : 0
        let dy = travel.height > 0 ? (origin.y - point.y) / travel.height : 0
        dragOrigin = point
        anchor = CGPoint(
            x: min(max(anchor.x + dx, 0), 1),
            y: min(max(anchor.y + dy, 0), 1))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        isDragging = false
    }

    // MARK: - The grid

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDragging else { return }

        let travel = self.travel
        let panel = palette.frame.size
        // Where the panel's centre is right now, which is what the guides are
        // measured against.
        let centre = CGPoint(
            x: Self.margin + panel.width / 2 + anchor.x * travel.width,
            y: Self.margin + panel.height / 2 + anchor.y * travel.height)

        for guide in Self.guides {
            let x = Self.margin + panel.width / 2 + guide * travel.width
            let y = Self.margin + panel.height / 2 + guide * travel.height
            // Flipped for drawing: `anchor.y` grows downwards, AppKit's y does not.
            let drawnY = bounds.height - y

            stroke(
                from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: bounds.height),
                lit: abs(centre.x - x) <= Self.alignment)
            stroke(
                from: CGPoint(x: 0, y: drawnY), to: CGPoint(x: bounds.width, y: drawnY),
                lit: abs(centre.y - y) <= Self.alignment)
        }
    }

    /// A guide the panel has met is drawn solid and bright; the rest stay faint
    /// and dashed. That difference is the entire feature — it is the only way
    /// the panel tells you it is lined up, since nothing pulls it there.
    private func stroke(from: CGPoint, to: CGPoint, lit: Bool) {
        let path = NSBezierPath()
        path.lineWidth = lit ? 2.5 : 1.5
        if !lit { path.setLineDash([9, 7], count: 2, phase: 0) }
        NSColor.white.withAlphaComponent(lit ? 0.6 : 0.14).setStroke()
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }
}
