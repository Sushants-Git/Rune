import Cocoa

enum SplitDirection {
    case right, down, left, up

    var isVertical: Bool { self == .right || self == .left }
    /// Whether the new pane goes after the existing one in the split view's
    /// subview order.
    var insertsAfter: Bool { self == .right || self == .down }
}

/// One terminal inside a tab's split layout.
///
/// The surface gets a wrapper rather than sitting in the split view directly:
/// libghostty owns the surface's layer entirely, so anything Rune draws over a
/// terminal needs a view of its own to live on.
@MainActor
final class SplitPane: NSView {
    let surface: GhosttySurfaceView

    /// Only meaningful when the tab actually has more than one pane — a lone
    /// terminal doesn't need to be told anything about focus.
    var showsFocus = false { didSet { syncDim() } }
    var isFocused = false { didSet { syncDim() } }

    /// Laid over the panes you *aren't* typing in. Nothing is ever drawn over
    /// the live one.
    private let wash = PassthroughView()

    /// What that wash is made of. The controller keeps it in step with the
    /// terminal's own background — see `TerminalController.syncChrome`.
    var washColor: NSColor = .black.withAlphaComponent(0.22) { didSet { syncDim() } }

    init(surface: GhosttySurfaceView) {
        self.surface = surface
        super.init(frame: .zero)

        wantsLayer = true

        surface.autoresizingMask = [.width, .height]
        surface.frame = bounds
        addSubview(surface)

        wash.wantsLayer = true
        wash.autoresizingMask = [.width, .height]
        wash.frame = bounds
        wash.isHidden = true
        addSubview(wash, positioned: .above, relativeTo: surface)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        wash.frame = bounds
    }

    private func syncDim() {
        // The live pane shows the terminal exactly as configured — no film, no
        // outline, no shadow. The others get a wash mixed from the terminal's
        // own background, which fades their *text* as well as darkening them.
        //
        // Fading the text matters: on a near-black theme the background can't
        // get any darker, so a plain black wash does nothing visible. And it
        // has to be a wash rather than `alphaValue` — lowering the pane's
        // opacity made it translucent right through the window, so whatever
        // app was behind Rune showed through the idle splits.
        //
        // It is kept deliberately light. The wash only has to answer "which one
        // am I typing in"; anything heavier than that means you can no longer
        // *read* the pane beside the one you're working in, which is most of
        // why you split in the first place.
        let hidden = !(showsFocus && !isFocused)
        wash.isHidden = hidden
        // Skipped while hidden: `washColor` is re-set on every chrome sync and
        // resolving a colour to a CGColor is not free.
        if !hidden { wash.layer?.backgroundColor = washColor.cgColor }
    }
}

/// A view that is drawn but never clicked, so the dimming over an unfocused
/// pane doesn't eat the click that focuses it.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A split view with a hairline divider tinted to the terminal's own colours,
/// so a split reads as a seam rather than as a slab of window chrome.
@MainActor
final class RuneSplitView: NSSplitView, NSSplitViewDelegate {
    /// Set by the controller alongside the rest of the chrome.
    var dividerTint: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    init(vertical: Bool) {
        super.init(frame: .zero)
        isVertical = vertical
        dividerStyle = .thin
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { dividerTint }

    // Panes are equal citizens: nothing should be pinned or collapsed.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(
        _ splitView: NSSplitView,
        shouldAdjustSizeOfSubview view: NSView
    ) -> Bool { true }
}

/// One tab: a tree of terminals split horizontally and vertically.
///
/// The view hierarchy *is* the tree — a `SplitPane` is a leaf and a
/// `RuneSplitView` is a branch — so splitting and closing are local surgery on
/// two or three views rather than a rebuild, and the divider positions you drag
/// survive everything else that happens in the tab.
@MainActor
final class Tab {
    let id = UUID()

    /// Hosts the split hierarchy. The controller shows and hides this.
    let view = NSView()

    private(set) weak var focused: GhosttySurfaceView?

    init(first surface: GhosttySurfaceView) {
        view.autoresizingMask = [.width, .height]

        let pane = SplitPane(surface: surface)
        pane.frame = view.bounds
        pane.autoresizingMask = [.width, .height]
        view.addSubview(pane)

        focus(surface)
    }

    // MARK: - Contents

    /// Every pane in the tab, in layout order (left-to-right, top-to-bottom).
    ///
    /// Cached. The tree only changes when `split` or `remove` says so, and this
    /// is read a dozen times per chrome sync — walking the view hierarchy that
    /// often to answer a question whose answer hasn't changed is pure waste.
    var panes: [SplitPane] {
        if let cachedPanes { return cachedPanes }
        var result: [SplitPane] = []
        func walk(_ node: NSView) {
            if let pane = node as? SplitPane {
                result.append(pane)
            } else {
                node.subviews.forEach(walk)
            }
        }
        view.subviews.forEach(walk)
        cachedPanes = result
        return result
    }

    private var cachedPanes: [SplitPane]?

    /// Called by every structural change. Nothing else may mutate the tree.
    private func invalidatePanes() { cachedPanes = nil }

    var surfaces: [GhosttySurfaceView] { panes.map(\.surface) }

    var isEmpty: Bool { panes.isEmpty }

    func contains(_ surface: GhosttySurfaceView) -> Bool {
        panes.contains { $0.surface === surface }
    }

    private func pane(for surface: GhosttySurfaceView) -> SplitPane? {
        panes.first { $0.surface === surface }
    }

    /// The loudest thing any pane in this tab is doing.
    var status: Status { Status.loudest(of: surfaces.map(\.status)) }

    /// What the strip and ⌘K call this tab.
    var title: String { focused?.shortTitle ?? surfaces.first?.shortTitle ?? "Terminal" }
    var directory: String? { focused?.pwd ?? surfaces.first?.pwd }

    // MARK: - Focus

    func focus(_ surface: GhosttySurfaceView) {
        guard contains(surface) else { return }
        // Moving to another pane ends the zoom: the one you're going to is
        // behind the zoomed one, and focusing something you can't see is worse
        // than losing the zoom.
        if let zoom, zoom.pane.surface !== surface { unzoom() }
        focused = surface
        syncFocusBorders()
    }

    /// Keep the outline on the right pane, and drop it entirely once a tab is
    /// back down to one terminal.
    func syncFocusBorders() {
        let panes = self.panes
        let showsFocus = panes.count > 1
        for pane in panes {
            pane.showsFocus = showsFocus
            pane.isFocused = pane.surface === focused
        }
    }

    /// The pane nearest `surface` in `direction`, by screen geometry — which is
    /// what you mean when you press ⌘⌥→, regardless of how the tree is nested.
    func neighbor(
        of surface: GhosttySurfaceView,
        direction: SplitDirection
    ) -> GhosttySurfaceView? {
        guard let from = pane(for: surface) else { return nil }
        let origin = view.convert(from.bounds, from: from)

        var best: (pane: SplitPane, distance: CGFloat)?
        for candidate in panes where candidate !== from {
            let frame = view.convert(candidate.bounds, from: candidate)

            // Must lie in the requested direction, and overlap on the other
            // axis, so ⌘⌥→ can't jump to something stacked above.
            let inDirection: Bool
            let overlaps: Bool
            switch direction {
            case .right:
                inDirection = frame.minX >= origin.maxX - 1
                overlaps = frame.maxY > origin.minY && frame.minY < origin.maxY
            case .left:
                inDirection = frame.maxX <= origin.minX + 1
                overlaps = frame.maxY > origin.minY && frame.minY < origin.maxY
            case .up:
                // The container is not flipped, so "up" is larger Y.
                inDirection = frame.minY >= origin.maxY - 1
                overlaps = frame.maxX > origin.minX && frame.minX < origin.maxX
            case .down:
                inDirection = frame.maxY <= origin.minY + 1
                overlaps = frame.maxX > origin.minX && frame.minX < origin.maxX
            }
            guard inDirection, overlaps else { continue }

            let distance = hypot(frame.midX - origin.midX, frame.midY - origin.midY)
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.pane.surface
    }

    /// Cycle through panes in layout order, for ⌘⌥[ / ⌘⌥].
    func relativeSurface(from surface: GhosttySurfaceView, offset: Int) -> GhosttySurfaceView? {
        let panes = self.panes
        guard panes.count > 1,
              let current = panes.firstIndex(where: { $0.surface === surface })
        else { return nil }
        let next = (current + offset % panes.count + panes.count) % panes.count
        return panes[next].surface
    }

    // MARK: - Structure

    /// Split the pane showing `surface`, putting `new` beside it.
    func split(
        _ surface: GhosttySurfaceView,
        with new: GhosttySurfaceView,
        direction: SplitDirection
    ) {
        // Dividing a zoomed pane means putting the new one somewhere you can't
        // see, so come back to the whole layout first.
        unzoom()
        guard let pane = pane(for: surface), let parent = pane.superview else { return }

        let newPane = SplitPane(surface: new)
        let split = RuneSplitView(vertical: direction.isVertical)
        if let sibling = parent as? RuneSplitView { split.dividerTint = sibling.dividerTint }
        split.frame = pane.frame
        split.autoresizingMask = pane.autoresizingMask

        // Swap the split view in where the pane was, then hang both panes off
        // it — the rest of the tree never moves.
        parent.replaceSubview(pane, with: split)
        pane.autoresizingMask = [.width, .height]
        newPane.autoresizingMask = [.width, .height]
        if direction.insertsAfter {
            split.addSubview(pane)
            split.addSubview(newPane)
        } else {
            split.addSubview(newPane)
            split.addSubview(pane)
        }
        // Before anything reads `panes` again — `focus` below does.
        invalidatePanes()

        split.adjustSubviews()
        // Even halves. adjustSubviews alone leaves the second pane at zero when
        // the split view has only just been sized.
        let extent = direction.isVertical ? split.bounds.width : split.bounds.height
        if extent > 0 {
            split.setPosition((extent - split.dividerThickness) / 2, ofDividerAt: 0)
        }

        focus(new)
    }

    /// Remove `surface`'s pane, collapsing its split view into the sibling.
    /// Returns the surface that should take focus, if the tab still has one.
    @discardableResult
    func remove(_ surface: GhosttySurfaceView) -> GhosttySurfaceView? {
        // Put the tree back before taking anything out of it, so the removal
        // happens against the real structure.
        unzoom()
        guard let pane = pane(for: surface) else { return nil }

        guard let split = pane.superview as? NSSplitView else {
            // Last pane in the tab.
            pane.removeFromSuperview()
            invalidatePanes()
            focused = nil
            return nil
        }

        let survivor = split.subviews.first { $0 !== pane }
        pane.removeFromSuperview()
        invalidatePanes()

        if let survivor, let grandparent = split.superview {
            survivor.frame = split.frame
            survivor.autoresizingMask = split.autoresizingMask
            grandparent.replaceSubview(split, with: survivor)
            (grandparent as? NSSplitView)?.adjustSubviews()
        }

        // Prefer whatever is now nearest where the closed pane was.
        let next = panes.first(where: { $0.surface === focused })?.surface ?? panes.first?.surface
        if focused === surface { focused = next }
        syncFocusBorders()
        return next
    }

    // MARK: - Zoom

    /// Where a zoomed pane came from, so it can be put back exactly.
    ///
    /// The frames matter. Pulling a pane out of an `NSSplitView` makes the
    /// split re-lay-out whatever is left, which silently destroys the divider
    /// positions you dragged. Recording them here and restoring them on the way
    /// back means zooming is genuinely a view, not an edit.
    private struct Zoom {
        let pane: SplitPane
        let parent: NSSplitView
        let index: Int
        let siblingFrames: [CGRect]
        let autoresizing: NSView.AutoresizingMask
    }

    private var zoom: Zoom?

    /// Whether one pane is currently filling the tab.
    var isZoomed: Bool { zoom != nil }

    /// ⌘⇧↵: blow the focused pane up to fill the tab, or put it back.
    ///
    /// The rest of the tree stays exactly as it was, hidden behind it. Nothing
    /// is resized, no process is told anything changed except the one pane that
    /// actually got bigger.
    func toggleZoom() {
        if zoom != nil {
            unzoom()
        } else if let pane = panes.first(where: { $0.surface === focused }) {
            zoomIn(pane)
        }
    }

    private func zoomIn(_ pane: SplitPane) {
        // A tab with one pane is already zoomed, by definition.
        guard let parent = pane.superview as? NSSplitView,
              let index = parent.subviews.firstIndex(of: pane),
              let root = view.subviews.first
        else { return }

        zoom = Zoom(
            pane: pane,
            parent: parent,
            index: index,
            siblingFrames: parent.subviews.map(\.frame),
            autoresizing: pane.autoresizingMask)

        pane.removeFromSuperview()
        root.isHidden = true

        pane.autoresizingMask = [.width, .height]
        pane.frame = view.bounds
        view.addSubview(pane)

        invalidatePanes()
        syncFocusBorders()
    }

    private func unzoom() {
        guard let zoom, let root = view.subviews.first(where: { $0 !== zoom.pane }) else {
            return
        }
        self.zoom = nil

        zoom.pane.removeFromSuperview()
        zoom.pane.autoresizingMask = zoom.autoresizing
        root.isHidden = false

        // Back in at the same index, so left stays left.
        if zoom.index < zoom.parent.subviews.count {
            zoom.parent.addSubview(
                zoom.pane, positioned: .below, relativeTo: zoom.parent.subviews[zoom.index])
        } else {
            zoom.parent.addSubview(zoom.pane)
        }

        // Then the frames, which is what actually restores the dividers. Set
        // after insertion because adding a subview re-lays the split out.
        for (view, frame) in zip(zoom.parent.subviews, zoom.siblingFrames) {
            view.frame = frame
        }

        invalidatePanes()
        syncFocusBorders()
    }

    /// Give every pane an equal share of its parent, for ⌘⌥=.
    func equalize() {
        func walk(_ node: NSView) {
            if let split = node as? NSSplitView {
                split.adjustSubviews()
                let extent = split.isVertical ? split.bounds.width : split.bounds.height
                let count = CGFloat(split.subviews.count)
                if extent > 0, count > 1 {
                    for i in 0..<Int(count - 1) {
                        split.setPosition(extent * CGFloat(i + 1) / count, ofDividerAt: i)
                    }
                }
            }
            node.subviews.forEach(walk)
        }
        view.subviews.forEach(walk)
    }

    /// Nudge the divider that `surface` sits against.
    func resize(_ surface: GhosttySurfaceView, direction: SplitDirection, amount: CGFloat) {
        guard let pane = pane(for: surface),
              let split = pane.superview as? NSSplitView,
              split.isVertical == direction.isVertical,
              let index = split.subviews.firstIndex(of: pane)
        else { return }

        // Dragging the divider *after* this pane grows it; the one before
        // shrinks it, so flip the sign when the pane is on the far side.
        let divider = index == 0 ? 0 : index - 1
        let sign: CGFloat = index == 0 ? 1 : -1
        let grow = direction == .right || direction == .down
        let current = split.isVertical
            ? split.subviews[divider].frame.maxX
            : split.subviews[divider].frame.maxY
        split.setPosition(current + sign * amount * (grow ? 1 : -1), ofDividerAt: divider)
    }

    /// Recolour dividers when the terminal theme changes.
    func applyDividerTint(_ color: NSColor) {
        func walk(_ node: NSView) {
            (node as? RuneSplitView)?.dividerTint = color
            node.subviews.forEach(walk)
        }
        view.subviews.forEach(walk)
    }

    /// Re-mix the idle-pane wash when the terminal theme changes.
    func applyInactiveWash(_ color: NSColor) {
        for pane in panes { pane.washColor = color }
    }
}
