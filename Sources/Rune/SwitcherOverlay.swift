import Cocoa

/// The dimmed backdrop the ⌘K switcher floats on.
///
/// Workspaces all live in the same window, so the switcher can be an ordinary
/// in-window overlay: previewing swaps the terminal underneath it and the panel
/// stays put on top.
///
/// The panel can also be dragged. Grab it anywhere that isn't a row or the
/// search field — its padding, the hint bar — and a grid appears; let go and it
/// snaps to the nearest intersection and stays there for good. Nine positions
/// rather than free placement, because the useful thing is "put it where it
/// isn't covering what I'm reading", not pixel-level arrangement, and a panel
/// that lands somewhere slightly different each time is worse than one that
/// lands in the same nine places.
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
    /// Three by three. Enough to get out of the way, few enough to be muscle
    /// memory.
    private static let stops: [CGFloat] = [0, 0.5, 1]

    private var horizontal: NSLayoutConstraint!
    private var vertical: NSLayoutConstraint!

    /// Set while a drag is in flight, which is the only time the grid shows.
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
        // Follow the pointer, unsnapped — the snap happens on release, so the
        // panel doesn't jump about underneath the cursor while you aim.
        let dx = travel.width > 0 ? (point.x - origin.x) / travel.width : 0
        let dy = travel.height > 0 ? (origin.y - point.y) / travel.height : 0
        let free = CGPoint(
            x: min(max(anchor.x + dx, 0), 1),
            y: min(max(anchor.y + dy, 0), 1))
        dragOrigin = point
        anchor = free
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            isDragging = false
        }
        guard isDragging else { return }
        anchor = CGPoint(x: Self.nearestStop(anchor.x), y: Self.nearestStop(anchor.y))
    }

    private static func nearestStop(_ value: CGFloat) -> CGFloat {
        stops.min { abs($0 - value) < abs($1 - value) } ?? 0.5
    }

    // MARK: - The grid

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDragging else { return }

        let travel = self.travel
        let panel = palette.frame.size
        NSColor.white.withAlphaComponent(0.28).setStroke()

        // Lines through where the panel's *centre* would land, which is what
        // it snaps to — a grid drawn anywhere else would be a grid you can't
        // actually hit.
        for stop in Self.stops {
            let x = Self.margin + panel.width / 2 + stop * travel.width
            let line = NSBezierPath()
            line.lineWidth = 1
            line.setLineDash([4, 5], count: 2, phase: 0)
            line.move(to: CGPoint(x: x, y: 0))
            line.line(to: CGPoint(x: x, y: bounds.height))
            line.stroke()

            let y = bounds.height - (Self.margin + panel.height / 2 + stop * travel.height)
            let across = NSBezierPath()
            across.lineWidth = 1
            across.setLineDash([4, 5], count: 2, phase: 0)
            across.move(to: CGPoint(x: 0, y: y))
            across.line(to: CGPoint(x: bounds.width, y: y))
            across.stroke()
        }

        // The nine places it can land, so the targets are visible rather than
        // inferred from where the lines cross.
        NSColor.white.withAlphaComponent(0.5).setFill()
        for column in Self.stops {
            for row in Self.stops {
                let x = Self.margin + panel.width / 2 + column * travel.width
                let y = bounds.height - (Self.margin + panel.height / 2 + row * travel.height)
                let dot = NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
