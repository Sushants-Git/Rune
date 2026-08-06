import Cocoa

/// The dimmed backdrop the ⌘K switcher floats on.
///
/// Workspaces all live in the same window, so the switcher can be an ordinary
/// in-window overlay: previewing swaps the terminal underneath it and the panel
/// stays put on top.
///
/// The panel can also be dragged. Grab it anywhere that isn't a row or the
/// search field — its padding, the hint bar — and guides appear. It floats
/// freely, except near a guide, where it takes hold: bring an edge within a
/// few pixels of one and the panel snaps flush to it and the guide lights.
/// Move away and it is loose again.
///
/// The guides are matched against the panel's *edges*, not its centre — a
/// horizontal guide catches the top or bottom, a vertical guide the left or
/// right — because lining a panel up means lining up the side you can see,
/// not a midpoint you have to imagine. Centres are matched too, for the middle
/// of the window.
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
    /// How near an edge has to come before the guide takes hold. Pixels, so it
    /// feels the same in a narrow window as a wide one.
    private static let magnet: CGFloat = 10

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

    /// Vertical guides, as distances from the left edge.
    private var verticalGuides: [CGFloat] {
        [Self.margin, bounds.width / 2, bounds.width - Self.margin]
    }

    /// Horizontal guides, as distances from the top edge.
    private var horizontalGuides: [CGFloat] {
        [Self.margin, bounds.height / 2, bounds.height - Self.margin]
    }

    /// The panel's left edge, centre and right edge — the three things a
    /// vertical guide can catch.
    private func columnEdges(left: CGFloat) -> [CGFloat] {
        [left, left + palette.frame.width / 2, left + palette.frame.width]
    }

    /// Top, centre, bottom.
    private func rowEdges(top: CGFloat) -> [CGFloat] {
        [top, top + palette.frame.height / 2, top + palette.frame.height]
    }

    /// The smallest nudge that would bring one of `edges` flush to a guide, or
    /// nil when none is close enough to take hold.
    private func pull(_ edges: [CGFloat], to guides: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        for edge in edges {
            for guide in guides {
                let delta = guide - edge
                if abs(delta) <= Self.magnet, abs(delta) < abs(best ?? .greatestFiniteMagnitude) {
                    best = delta
                }
            }
        }
        return best
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

        // Work in pixels here. The magnet is a distance on screen, and doing
        // it in fractions of the travel would make it grabbier in a narrow
        // window than a wide one.
        var left = Self.margin + anchor.x * travel.width + (point.x - origin.x)
        var top = Self.margin + anchor.y * travel.height + (origin.y - point.y)

        // Near a guide it takes hold; away from one it is loose.
        if let nudge = pull(columnEdges(left: left), to: verticalGuides) { left += nudge }
        if let nudge = pull(rowEdges(top: top), to: horizontalGuides) { top += nudge }

        anchor = CGPoint(
            x: travel.width > 0 ? min(max((left - Self.margin) / travel.width, 0), 1) : 0,
            y: travel.height > 0 ? min(max((top - Self.margin) / travel.height, 0), 1) : 0)
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
        let columns = columnEdges(left: left)
        let rows = rowEdges(top: top)

        // A guide is lit when the panel is actually flush against it, which
        // after the magnet has fired means within a pixel — so the light is a
        // statement that it *has* caught, not that it is nearly there.
        for guide in verticalGuides {
            let held = columns.contains { abs($0 - guide) <= 1 }
            stroke(
                from: CGPoint(x: guide, y: 0), to: CGPoint(x: guide, y: bounds.height),
                lit: held)
        }
        for guide in horizontalGuides {
            let held = rows.contains { abs($0 - guide) <= 1 }
            // Flipped: guides are measured from the top, AppKit draws from the
            // bottom.
            let y = bounds.height - guide
            stroke(from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y), lit: held)
        }
    }

    /// A guide the panel has caught is drawn solid and bright; the rest stay
    /// faint and dashed.
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
