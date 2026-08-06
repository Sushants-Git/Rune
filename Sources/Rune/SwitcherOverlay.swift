import Cocoa

/// The dimmed backdrop the ⌘K switcher floats on.
///
/// Workspaces all live in the same window, so the switcher can be an ordinary
/// in-window overlay: previewing swaps the terminal underneath it and the panel
/// stays put on top.
///
/// The panel can also be dragged. Grab it by the search strip along its top —
/// the way you would a title bar, text field included — or by any padding that
/// isn't a row, and three guides appear: two verticals at the thirds, and one
/// horizontal where the panel rests at the top.
///
/// Nothing snaps. The panel goes exactly where it is dropped; a guide only
/// brightens to say you have lined up with it, and stays dashed while it does,
/// so it reads as a hint rather than a thing that has grabbed you.
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
    /// How near counts as lined up. Pixels, so it reads the same in a narrow
    /// window as a wide one.
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

    /// Two verticals, at the thirds.
    private var verticalGuides: [CGFloat] {
        [bounds.width / 3, bounds.width * 2 / 3]
    }

    /// One horizontal, where the panel sits when it hasn't been moved.
    private var horizontalGuides: [CGFloat] {
        [Self.margin]
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
        dragOrigin = point

        // Straight to the pointer. Nothing pulls, nothing corrects — the guides
        // only report.
        let dx = travel.width > 0 ? (point.x - origin.x) / travel.width : 0
        let dy = travel.height > 0 ? (origin.y - point.y) / travel.height : 0
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
        let left = Self.margin + anchor.x * travel.width
        let top = Self.margin + anchor.y * travel.height
        let centreX = left + palette.frame.width / 2

        // Verticals answer "is the panel centred on this third?", the
        // horizontal answers "is its top edge on the line?" — the edge you are
        // actually looking at in each case.
        for guide in verticalGuides {
            stroke(
                from: CGPoint(x: guide, y: 0), to: CGPoint(x: guide, y: bounds.height),
                lit: abs(centreX - guide) <= Self.alignment)
        }
        for guide in horizontalGuides {
            // Flipped: guides are measured from the top, AppKit draws from the
            // bottom.
            let y = bounds.height - guide
            stroke(
                from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y),
                lit: abs(top - guide) <= Self.alignment)
        }
    }

    /// Dashed either way — a lit guide is the same line brighter and heavier,
    /// not a different kind of line. Going solid made it look like the panel
    /// had been captured, which is exactly what does not happen here.
    private func stroke(from: CGPoint, to: CGPoint, lit: Bool) {
        let path = NSBezierPath()
        path.lineWidth = lit ? 2.5 : 1.5
        path.setLineDash([9, 7], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(lit ? 0.65 : 0.14).setStroke()
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }
}
