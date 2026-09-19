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
    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            syncDim()
            header.isHidden = !showsFocus
            refreshHeader()
            searchBar?.keepClear(of: headerInset)
            needsLayout = true
        }
    }

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            syncDim()
            header.isFocused = isFocused
        }
    }

    /// The strip naming this pane, and the controls for it. Only on screen once
    /// a tab has been split — a lone terminal has nothing to be told apart from
    /// and no reason to give up a row for a title it already has in the strip
    /// above it.
    private let header = PaneHeader()

    /// Laid over the panes you *aren't* typing in. Nothing is ever drawn over
    /// the live one.
    private let wash = PassthroughView()

    /// What that wash is made of. The controller keeps it in step with the
    /// terminal's own background — see `TerminalController.syncChrome`.
    var washColor: NSColor = .black.withAlphaComponent(0.22) { didSet { syncDim() } }

    /// The find bar, once someone has asked for one. It lives in the pane
    /// rather than in the window so a split carries its own search around with
    /// it — the results belong to this surface's scrollback and nothing else's.
    private(set) var searchBar: SearchBar?
    /// Kept so the bar can be tinted the moment it is created, not only on the
    /// next time the theme changes.
    private var terminalBackground: NSColor = .black

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

        header.isHidden = true
        header.surface = surface
        addSubview(header, positioned: .above, relativeTo: wash)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // The header takes its row off the top of the pane; the terminal gets
        // the rest. Nothing overlaps — a title floating over live text is
        // unreadable the moment the text scrolls under it.
        let top = headerInset
        let content = NSRect(
            x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - top))
        surface.frame = content
        wash.frame = content
        header.frame = NSRect(
            x: 0, y: content.maxY, width: bounds.width, height: top)
    }

    /// How much of the top of the pane the header is holding.
    private var headerInset: CGFloat { header.isHidden ? 0 : PaneHeader.height }

    /// Re-read the pane's title and mark.
    func refreshHeader() {
        guard !header.isHidden else { return }
        header.refresh()
    }

    // MARK: - Search

    /// Show the find bar and put the caret in it. Repeating ⌘F with the bar
    /// already up re-focuses and selects, so the next thing typed replaces the
    /// last needle instead of appending to it.
    func showSearch(needle: String? = nil) {
        let bar = searchBar ?? makeSearchBar()
        if let needle, !needle.isEmpty {
            bar.setNeedle(needle)
            surface.search(for: needle)
        }
        bar.tint(background: terminalBackground)
        bar.focus()
        refreshSearchCount()
    }

    func hideSearch() {
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        surface.endSearch()
        // The terminal is what you were using; give it the keyboard back.
        window?.makeFirstResponder(surface)
    }

    private func makeSearchBar() -> SearchBar {
        let bar = SearchBar()
        bar.attach(to: self, below: headerInset)
        searchBar = bar

        bar.onSearch = { [weak self] needle in
            guard let self else { return }
            self.surface.search(for: needle)
            self.refreshSearchCount()
        }
        bar.onNavigate = { [weak self] next in self?.surface.navigateSearch(next: next) }
        bar.onClose = { [weak self] in self?.hideSearch() }

        surface.onSearchState = { [weak self] in self?.refreshSearchCount() }
        surface.onSearchEnd = { [weak self] in self?.hideSearch() }
        return bar
    }

    private func refreshSearchCount() {
        guard let bar = searchBar else { return }
        bar.show(
            total: surface.searchTotal,
            selected: surface.searchSelected,
            searching: !bar.needle.isEmpty)

        // The core finds the matches but selects none of them; left alone, you
        // would type a needle, see "200", and have to press Return before the
        // terminal moved anywhere. Every find bar jumps to the first hit as you
        // type, so ask for it once results exist and nothing is chosen yet.
        // Selection stays set afterwards, so this cannot run away with itself.
        if !bar.needle.isEmpty, (surface.searchTotal ?? 0) > 0, surface.searchSelected == nil {
            surface.navigateSearch(next: true)
        }
    }

    func applySearchTint(_ background: NSColor) {
        terminalBackground = background
        searchBar?.tint(background: background)
        header.tint(background: background)
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

/// The strip along the top of a pane, once a tab has more than one.
///
/// It answers the question a split layout creates and nothing else answers:
/// *which of these is which*. The tab strip names the tab, not the panes inside
/// it, so two shells side by side used to be told apart only by their prompts.
/// Here each one carries its own mark and title, and the controls that act on
/// it are on it rather than in a menu — split this one, zoom this one, close
/// this one.
///
/// Quiet unless you are near it: the buttons are only drawn for the focused
/// pane or the one under the pointer, so a four-way split isn't sixteen
/// glyphs.
@MainActor
final class PaneHeader: NSView {
    static let height: CGFloat = 24

    weak var surface: GhosttySurfaceView?

    var isFocused = false { didSet { paint() } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let underline = NSView()
    private var hovering = false { didSet { paint() } }
    private var background: NSColor = .black

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        autoresizingMask = [.width, .minYMargin]

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 1
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setViews([
            button("square.split.2x1", "Split Right (⌘D)", #selector(splitRight)),
            button("square.split.1x2", "Split Down (⌘⇧D)", #selector(splitDown)),
            button("arrow.up.left.and.arrow.down.right", "Zoom (⌘⇧↵)", #selector(zoom)),
            button("xmark", "Close (⌘W)", #selector(closePane)),
        ], in: .leading)
        controls.isHidden = true
        addSubview(controls)

        // A hairline at the bottom of the *focused* pane's header, in the
        // accent. The wash says which pane is idle by taking contrast away;
        // this says which one is live by adding a single line of it, which is
        // the part you can find without comparing two panes to each other.
        underline.wantsLayer = true
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: controls.leadingAnchor, constant: -6),

            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),

            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let control = ChromeButton()
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        control.imagePosition = .imageOnly
        control.isBordered = false
        control.bezelStyle = .inline
        control.toolTip = tip
        control.target = self
        control.action = action
        control.wantsLayer = true
        control.layer?.cornerRadius = 4
        control.layer?.cornerCurve = .continuous
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: 18),
            control.heightAnchor.constraint(equalToConstant: 16),
        ])
        return control
    }

    func tint(background: NSColor) {
        self.background = background
        paint()
    }

    /// What this header was last given. Not the same as what is in the image
    /// view: a pane with no mark of its own shows the fallback glyph, so asking
    /// `icon.image` whether anything changed answers "no" on the very first
    /// call and the header comes up with an empty space where a mark goes.
    private var mark: NSImage?

    /// Re-read what the pane is running.
    func refresh() {
        guard let surface else { return }
        let title = surface.shortTitle
        if label.stringValue != title { label.stringValue = title }

        let mark = TerminalController.mark(for: surface)
        if self.mark !== mark || icon.image == nil {
            self.mark = mark
            icon.image = mark ?? NSImage(
                systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
            icon.contentTintColor = mark == nil ? Chrome.ink(over: background)(0.5) : nil
        }
    }

    private func paint() {
        let ink = Chrome.ink(over: background)
        // An opaque plate mixed from the terminal's own colour rather than a
        // translucent film. The pane behind the header is empty — the surface
        // only covers the content below it — so a film here would be tinting
        // the *window ground*, and the header's colour would depend on how far
        // the terminal happened to be from it.
        let lift = background.isDark ? NSColor.white : NSColor.black
        layer?.backgroundColor = (background
            .blended(withFraction: isFocused ? 0.13 : 0.07, of: lift) ?? background).cgColor
        label.textColor = ink(isFocused ? 0.85 : 0.5)
        underline.layer?.backgroundColor = isFocused
            ? Settings.shared.effectiveAccent.withAlphaComponent(0.65).cgColor
            : ink(0.08).cgColor
        controls.isHidden = !(isFocused || hovering)
        for case let control as ChromeButton in controls.arrangedSubviews {
            control.contentTintColor = ink(0.65)
            control.restingBackground = .clear
        }
        if icon.contentTintColor != nil { icon.contentTintColor = ink(0.5) }
    }

    // MARK: - Actions

    private var controller: TerminalController? {
        (window as? TerminalWindow)?.controller
    }

    /// Anything done from this header is done to *this* pane, so it takes the
    /// keyboard first. Otherwise ⌘D-by-mouse would split whichever pane you
    /// last typed in, which is not the one you just clicked on.
    private func take() -> TerminalController? {
        guard let controller, let surface else { return nil }
        controller.focus(surface)
        return controller
    }

    @objc private func splitRight() { take()?.splitActiveSurface(.right) }
    @objc private func splitDown() { take()?.splitActiveSurface(.down) }
    @objc private func zoom() { take()?.toggleSplitZoom() }
    @objc private func closePane() {
        guard let surface else { return }
        controller?.closeSurface(surface)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        controller?.focus(surface)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
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
        view.wantsLayer = true

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
    var directory: String? { focused?.workingDirectory ?? surfaces.first?.workingDirectory }

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

    /// Recolour the card's hairline when the terminal theme changes.
    ///
    /// The shape is set here too, not only in `init`. A view's backing layer
    /// may not exist yet at the moment it is created — the container is
    /// layer-backed and hands one down when the view joins it — so a radius
    /// written in `init` can land on nothing and leave a square card.
    /// Paint the terminal's own colour behind the surface.
    ///
    /// A surface that has not drawn its first frame yet is transparent, and
    /// what shows through is the window's ground — which is lighter than the
    /// terminal. That was the flash when a tab opened: not a redraw, but two
    /// frames of the wrong colour in the shape of the terminal.
    func applyBackground(_ fill: NSColor) {
        guard let layer = view.layer else { return }
        layer.backgroundColor = fill.cgColor
        // The tab is the card: rounded and clipped here rather than per pane,
        // so a split layout gets one outer radius, not four. Set here as well
        // as colour because a view's backing layer may not exist yet when the
        // tab is created.
        layer.cornerRadius = Chrome.cardRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        for pane in panes { pane.layer?.backgroundColor = fill.cgColor }
    }

    /// Re-read each pane's header. Titles and agent marks change constantly;
    /// the headers are only on screen when a tab is split, so this is cheap
    /// exactly when it runs often.
    func refreshPaneHeaders() {
        for pane in panes { pane.refreshHeader() }
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

    /// The find bar paints itself from the terminal's colour, so it has to be
    /// told when that changes along with everything else in the chrome.
    func applySearchTint(_ background: NSColor) {
        for pane in panes { pane.applySearchTint(background) }
    }

    /// The pane you are typing in, which is the one a find bar belongs to.
    var focusedPane: SplitPane? {
        guard let focused else { return nil }
        return panes.first { $0.surface === focused }
    }

    func pane(showing surface: GhosttySurfaceView) -> SplitPane? {
        panes.first { $0.surface === surface }
    }
}

/// The window's content area, which lays its own children out.
///
/// The terminal and the diff panel are siblings sharing one width, and two
/// siblings autoresizing independently both claim all of it. One place decides
/// instead, and it runs on every resize because `layout` does.
@MainActor
final class ContainerView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
