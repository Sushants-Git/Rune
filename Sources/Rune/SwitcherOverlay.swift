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
/// Something the overlay can float: the ⌘K switcher, or the todo list.
///
/// Both are the same panel showing a different list, so they share the backdrop,
/// the dragging and the remembered position rather than each growing its own.
@MainActor
protocol OverlayPanel where Self: NSView {
    /// What should hold the keyboard right now. Not fixed: the todo list
    /// hands it between its own list and its field as you type.
    var focusView: NSView { get }
    /// Escape, or a click on the backdrop.
    func cancel()
}

@MainActor
final class SwitcherOverlay: NSView {
    let panel: NSView

    /// The switcher, when the panel is one. Nil while the todo list is up,
    /// which is what keeps ⌘W and ⌘P from acting on workspaces that aren't on
    /// screen.
    var palette: SwitcherPalette? { panel as? SwitcherPalette }

    /// What should hold the keyboard while this panel is up, asked afresh each
    /// time: a panel can move it around while it is open.
    var panelFocusView: NSView { panelRef.focusView }

    private let panelRef: any OverlayPanel

    private let onPanelCancel: () -> Void

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

    init(panel: some OverlayPanel) {
        self.panel = panel
        self.panelRef = panel
        self.onPanelCancel = { [weak panel] in panel?.cancel() }
        self.anchor = Self.saved
        super.init(frame: .zero)

        wantsLayer = true
        // Heavier than it was. The panel is opaque black now, so the backdrop
        // has to carry enough of the terminal away for the panel to sit in
        // front of it rather than dissolve into it.
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(Settings.shared.backdropDim).cgColor

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        horizontal = panel.centerXAnchor.constraint(equalTo: centerXAnchor)
        vertical = panel.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([horizontal, vertical])
        applyAnchor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Applied here rather than in `layout()`. `travel` depends on `bounds`, so
    // the first call — during init, before the overlay has been sized — works
    // out to zero and pins the panel to the default. The corrected call then
    // happened *inside* `layout()`, where changing a constraint is too late to
    // be solved in that pass, so the constants were right and the frame was
    // not. A dragged panel came back centred every time.
    //
    // `setFrameSize` lands before subviews are positioned, so by the time the
    // pass runs the constants are already correct.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyAnchor()
    }

    /// The panel's size, without needing it to have been laid out yet.
    ///
    /// Not `panel.frame`. On the first layout pass the panel has no frame, so a
    /// `travel` derived from it is zero — and an anchor multiplied by zero is
    /// the default position. That is the whole reason a dragged panel came back
    /// centred: the saved value was read correctly and then multiplied away.
    /// The width is a constant, and `fittingSize` gives the height without
    /// waiting for anyone.
    private var panelSize: CGSize {
        CGSize(
            width: SwitcherPalette.width,
            height: panel.frame.height > 0 ? panel.frame.height : panel.fittingSize.height)
    }

    /// How far the panel may travel on each axis before it hits the margins.
    private var travel: CGSize {
        let size = panelSize
        return CGSize(
            width: max(0, bounds.width - size.width - Self.margin * 2),
            height: max(0, bounds.height - size.height - Self.margin * 2))
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
        guard panel.frame.contains(point) else {
            onPanelCancel()
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
        let right = left + panelSize.width

        // Either edge, not the centre. A vertical line is something you line a
        // *side* of the panel up against — the centre is invisible, so a guide
        // lighting for it looks like it fired at nothing.
        for guide in verticalGuides {
            let met = abs(left - guide) <= Self.alignment || abs(right - guide) <= Self.alignment
            stroke(
                from: CGPoint(x: guide, y: 0), to: CGPoint(x: guide, y: bounds.height),
                lit: met)
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
