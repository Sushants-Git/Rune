import Cocoa

/// The tab strip across the top of the window, drawn the way Chrome draws one.
///
/// The active tab is the terminal's own colour, with rounded top corners and
/// flared bottom corners that run straight into the terminal card below it, so
/// the tab and what it is showing read as one shape. The strip sits directly on
/// the card's top edge for exactly that reason — any margin between them would
/// cut the tab off from its content. Inactive tabs have no fill at all until
/// you point at one; a hairline divides neighbours and gets out of the way
/// beside the active and the hovered tab, where it would only be a stray line
/// against a shape that already has an edge.
///
/// One tab is nothing to choose between, so a workspace with a single tab
/// shows no tabs at all — just its name, centred where a title would go, the
/// way 0.26 did. A lone Chrome-style tab joined to the terminal was tried, and
/// a single tab sitting in the corner of an otherwise empty strip looked like
/// a stray rather than a design; the tabs appear the moment there is a second
/// one to tell apart from it.
@MainActor
final class TabBar: NSView {
    /// How far down the window the traffic lights are centred. Measured, not
    /// assumed: the compact toolbar `TerminalController` gives the window puts
    /// them here, and every control in the strip hangs off the same line.
    fileprivate static let controlCentre: CGFloat = 20

    /// A tab's body, top edge to where it meets the card. Deep enough for a
    /// 16pt mark and a title with room around both — at 24 the tabs read as a
    /// row of labels rather than tabs. Not deeper: since the body's middle is
    /// pinned to the lights, every extra point of depth also pushes its top a
    /// point closer to the window's edge, and 28 leaves six.
    fileprivate static let tabDepth: CGFloat = 28

    /// Where a tab's body begins, measured down from the top of the strip.
    fileprivate static var tabTop: CGFloat { controlCentre - tabDepth / 2 }

    /// Height of the strip. The terminal card begins exactly where this ends.
    static var height: CGFloat { controlCentre + tabDepth / 2 }

    /// Where the tab row starts: the traffic lights end 66pt in, plus the same
    /// breathing room they keep between each other.
    private static let leadingInset: CGFloat = 76
    /// Chrome's standard tab width (`kTabWidth` in Chromium's `tab_style.cc`).
    /// Tabs sit at this width until the strip runs out of room, and only then
    /// start to narrow.
    private static let maxChipWidth: CGFloat = 232
    /// How narrow a tab you are *not* using may get: its icon and padding.
    private static let inactiveFloor: CGFloat = 40
    /// How narrow the tab you *are* using may get: still wide enough for its
    /// icon, a few characters of title and its close button. Chromium keeps a
    /// separate, larger minimum for the active tab for the same reason — when
    /// the strip is crowded, the others give up their width first, so the one
    /// you are looking at stays readable.
    private static let activeFloor: CGFloat = 120

    /// How long a tab takes to open or close, and how long a hover takes to
    /// come up. Short enough that it never stands between you and the tab —
    /// the point is that the strip doesn't jump, not that anything is on show.
    static let duration: TimeInterval = 0.16
    static let hoverDuration: TimeInterval = 0.1

    /// The terminal's own colour. The strip itself is painted on the ground the
    /// terminal card sits on — a shade of this — but the chips are mixed from
    /// *this*, so the active one comes out the same colour as the card it flows
    /// into.
    var backgroundColor: NSColor = .clear {
        didSet {
            guard backgroundColor != oldValue else { return }
            let ground = Chrome.ground(for: backgroundColor)
            layer?.backgroundColor = ground.cgColor
            for chip in chips { chip.background = backgroundColor }
            let ink = Chrome.ink(over: ground)
            newButton.paint(tint: ink(0.7), resting: .clear, hover: ink(0.12))
            titleLabel.textColor = ink(0.7)
            titleDot.layer?.borderColor = ground.cgColor
            if titleMark == nil || titleMark?.isTemplate == true {
                titleIcon.contentTintColor = ink(0.6)
            }
            zoomButton.paint(tint: ink(0.7), resting: ink(0.08), hover: ink(0.15))
        }
    }

    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    var onNewTab: (() -> Void)?
    /// The zoom indicator was clicked — put the pane back.
    var onResetZoom: (() -> Void)?

    private let stack = NSStackView()
    /// What the strip shows instead of tabs when there is only one: the tab's
    /// mark, with its status badge, and its name.
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleIcon = NSImageView()
    private let titleDot = NSView()
    private let titleRow = NSStackView()
    private var titleMark: NSImage?
    private var titleActivity: Activity = .idle
    /// Holds the row and masks it. With enough tabs the row is wider than the
    /// space it has even after every tab has shrunk as far as it can, and
    /// something has to give: it is cut off here rather than drawn off the side
    /// of the window, which is what it used to do. `⌥1`–`⌥9`, `⌘⇧[` / `⌘⇧]`
    /// and ⌘K all still reach a tab the row has no room to show.
    private let clip = NSView()
    /// Every button beside the tabs is shorter than a tab is deep.
    ///
    /// A tab has to reach the terminal — that join is the whole shape — but a
    /// button that reaches it too has its bottom edge sitting on the terminal's
    /// top edge, and reads as stuck to it. This leaves three points of strip
    /// above and below each one.
    private static let buttonSide: CGFloat = 18

    private let newButton = StripButton(
        symbol: "plus", pointSize: 11, weight: .regular,
        side: buttonSide, radius: buttonSide / 2, label: "New Tab (⌘T)")
    /// Shown only while a pane is zoomed. See `update(tabs:...)`.
    private let zoomButton = StripButton(
        symbol: "arrow.down.right.and.arrow.up.left", pointSize: 10, weight: .semibold,
        side: buttonSide, radius: 6, label: "Pane zoomed. Click to restore the splits (⌘⇧↵)")
    /// Sits at the trailing end and is usually invisible. See `UpdatePill`.
    private let updatePill = UpdatePill()
    /// The trailing end of the bar. A stack rather than pinned views because
    /// both of these are usually absent, and `NSStackView` collapses hidden
    /// arranged subviews for free.
    private let trailingCluster = NSStackView()

    private var tabs: [Tab] = []
    private weak var active: Tab?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true
        // The active tab's flares and its last point of depth reach just past
        // the strip, over the card's top hairline, so the join has no seam.
        layer?.masksToBounds = false

        NotificationCenter.default.addObserver(
            forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chips.forEach { $0.refresh() } }
            }

        newButton.action = { [weak self] in self?.onNewTab?() }
        zoomButton.action = { [weak self] in self?.onResetZoom?() }
        zoomButton.isHidden = true

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.wantsLayer = true

        trailingCluster.orientation = .horizontal
        trailingCluster.alignment = .centerY
        trailingCluster.spacing = 6
        trailingCluster.setViews([zoomButton, updatePill], in: .leading)

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleIcon.imageScaling = .scaleProportionallyUpOrDown
        titleDot.wantsLayer = true
        titleDot.layer?.cornerRadius = 4
        titleDot.layer?.borderWidth = 1.5
        titleDot.isHidden = true
        titleDot.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.setViews([titleIcon, titleLabel], in: .leading)
        titleRow.addSubview(titleDot)
        NSLayoutConstraint.activate([
            titleIcon.widthAnchor.constraint(equalToConstant: 16),
            titleIcon.heightAnchor.constraint(equalToConstant: 16),
            titleDot.centerXAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: -1),
            titleDot.centerYAnchor.constraint(equalTo: titleIcon.bottomAnchor, constant: -1),
            titleDot.widthAnchor.constraint(equalToConstant: 8),
            titleDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        for view in [clip, newButton, trailingCluster, titleRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // Positive is downwards: Auto Layout does its y arithmetic as though y
        // grew down, even on macOS.
        let onControlLine = { (view: NSView) in
            view.centerYAnchor.constraint(equalTo: self.topAnchor, constant: Self.controlCentre)
        }
        // The clip is a flare wider than the row on each side. The active tab's
        // flares reach past its own edges, and with the clip hugging the row
        // exactly, the first and last tabs had their outer flare cut off.
        let fit = stack.trailingAnchor.constraint(
            lessThanOrEqualTo: clip.trailingAnchor, constant: -TabChip.flare)
        fit.priority = .init(999)
        let width = clip.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: TabChip.flare * 2)
        width.priority = .init(998)
        let follow = newButton.leadingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: TabChip.flare)
        follow.priority = .init(999)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights; the row itself starts a flare in, so
            // the first tab's flare has somewhere to be drawn.
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: TabChip.flare),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            // Preferred, not required: the row keeps itself inside the clip by
            // narrowing its tabs, and gives up — and gets masked — only once
            // they have nothing left to give.
            fit,
            width,

            // `+` follows the row, but never past where the row is allowed to
            // end, so a full strip doesn't push it under the update pill.
            follow,
            newButton.leadingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            onControlLine(newButton),
            newButton.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingCluster.leadingAnchor, constant: -8),

            trailingCluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            onControlLine(trailingCluster),

            // Centred in the window, on the traffic lights' line, and clear of
            // them and of anything at the trailing end, so a long name
            // truncates instead of sliding underneath.
            titleRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            onControlLine(titleRow),
            titleRow.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Self.leadingInset),
            titleRow.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.leadingInset),
            titleRow.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingCluster.leadingAnchor, constant: -8),
        ])
    }

    /// Rebuild the strip from the active workspace's tabs. `workspaceName` is
    /// the ⌘R name, if one is set.
    ///
    /// Chips are keyed by the tab they belong to rather than by position, which
    /// is what lets a tab that opens or closes be *the thing* that animates:
    /// with chips addressed by index, closing the second of three tabs removes
    /// the third chip and renames the rest, and there is nothing left to
    /// animate away.
    func update(
        tabs: [Tab], active: Tab?, workspaceName: String? = nil, isZoomed: Bool = false
    ) {
        let before = Set(chipForTab.keys)
        let now = tabs.map(ObjectIdentifier.init)
        // Only a strip that is changing *within* the workspace it is already
        // showing animates. Switching workspace replaces every tab at once, and
        // is asked for with a keystroke: it should land, not play.
        let animated = window?.isVisible == true
            && !before.isEmpty
            && !before.isDisjoint(with: Set(now))
            && before != Set(now)

        self.tabs = tabs
        self.active = active
        zoomButton.isHidden = !isZoomed

        // One tab: its name, centred, and no strip. The `+` goes with the
        // strip, as it did in 0.26 — ⌘T is how the second tab gets made.
        let single = tabs.count <= 1
        clip.isHidden = single
        newButton.isHidden = single
        titleRow.isHidden = !single
        if single {
            let title = workspaceName ?? active?.title ?? ""
            if titleLabel.stringValue != title { titleLabel.stringValue = title }
            syncTitleMark(for: active)
        }

        var leaving: [TabChip] = []
        for (id, chip) in chipForTab where !now.contains(id) {
            chipForTab[id] = nil
            chip.isLeaving = true
            // A closing tab is let go of its frozen width, or the shrink it is
            // about to be pinned to would contradict it.
            frozen.removeValue(forKey: ObjectIdentifier(chip))?.isActive = false
            leaving.append(chip)
        }
        // Anything but a close ends closing mode: a new tab, or a different
        // workspace's tabs entirely, has nothing to do with the widths that
        // were being held still for your pointer.
        if before.isDisjoint(with: Set(now)) || now.contains(where: { !before.contains($0) }) {
            thaw(animated: false)
        }

        var entering: [TabChip] = []
        for (index, tab) in tabs.enumerated() where chipForTab[ObjectIdentifier(tab)] == nil {
            let chip = makeChip(for: tab)
            chipForTab[ObjectIdentifier(tab)] = chip
            // In beside the tab it was opened after, not at the end: ⌘T appends
            // today, but the strip should not depend on that staying true.
            let previous = index > 0 ? chipForTab[ObjectIdentifier(tabs[index - 1])] : nil
            let at = previous.flatMap { stack.arrangedSubviews.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            stack.insertArrangedSubview(chip, at: min(at, stack.arrangedSubviews.count))
            constrain(chip)
            if animated { chip.prepareToEnter() }
            entering.append(chip)
        }

        chips = stack.arrangedSubviews.compactMap { $0 as? TabChip }

        // The ⌘R name belongs to the workspace, not to any one tab, so it only
        // stands in for a title when there is a single tab for it to mean.
        let lone = tabs.count == 1
        for tab in tabs {
            chipForTab[ObjectIdentifier(tab)]?.apply(
                title: lone ? (workspaceName ?? tab.title) : tab.title,
                icon: TerminalController.icon(for: tab),
                isActive: tab === active,
                status: tab.status,
                background: backgroundColor)
        }
        syncWidths()
        syncDividers()

        guard animated else {
            for chip in leaving { discard(chip) }
            return
        }

        // Settle the new sizes *before* animating: an entering chip is pinned
        // to no width and a leaving one to the width it already has, so the
        // only thing the animation has to do is move them off those pins.
        for chip in leaving { chip.prepareToLeave() }
        layoutSubtreeIfNeeded()

        // Two phases, because a tab should open *in its own place*: the tabs
        // already on the strip make room first, and only then does the new one
        // grow into the gap they left. Done in one pass, the new tab's left
        // edge travels as its neighbours shrink — it grows and slides at the
        // same time, which looks like it came sweeping in from further up the
        // strip rather than opening where it belongs. Closing runs the same
        // two steps in the other order: the tab shrinks away where it is, then
        // the rest spread back out.
        let closing = !leaving.isEmpty
        run(closing ? { for chip in leaving { chip.leave() } } : {}) { [weak self] in
            guard let self else { return }
            self.run({
                for chip in entering { chip.enter() }
                if closing { for chip in leaving { chip.collapse() } }
            }) { [weak self, leaving] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for chip in leaving { self.discard(chip) }
                    self.chips = self.stack.arrangedSubviews.compactMap { $0 as? TabChip }
                    self.syncWidths()
                    self.syncDividers()
                    for chip in entering { chip.settle() }
                }
            }
        }
    }

    /// The lone tab's mark and badge, the same ones its tab would carry.
    private func syncTitleMark(for tab: Tab?) {
        let mark = tab.flatMap(TerminalController.icon(for:))
        if titleMark !== mark || titleIcon.image == nil {
            titleMark = mark
            titleIcon.image = mark ?? NSImage(
                systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            titleIcon.contentTintColor = (mark == nil || mark?.isTemplate == true)
                ? Chrome.ink(over: Chrome.ground(for: backgroundColor))(0.6) : nil
        }
        let activity = tab?.status.activity ?? .idle
        guard activity != titleActivity else { return }
        titleActivity = activity
        if let color = activity.color {
            titleDot.isHidden = false
            titleDot.layer?.backgroundColor = color.cgColor
            if activity.pulses { Pulse.apply(to: titleDot.layer) } else { Pulse.remove(from: titleDot.layer) }
        } else {
            titleDot.isHidden = true
            Pulse.remove(from: titleDot.layer)
        }
    }

    /// One half of the two-step: apply `changes`, animate the layout they imply,
    /// then run `next` once it has landed.
    private func run(_ changes: () -> Void, then next: @escaping @MainActor @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration / 2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            changes()
            layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated { next() }
        }
    }

    private func makeChip(for tab: Tab) -> TabChip {
        let chip = TabChip()
        chip.onSelect = { [weak self, weak tab] in
            guard let tab else { return }
            self?.onSelect?(tab)
        }
        chip.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            // Only the close *button* does this, not ⌘W: a close by mouse means
            // the pointer is on the strip, and quite possibly about to close
            // the next tab too.
            self.freezeWidths()
            self.onClose?(tab)
        }
        chip.onHover = { [weak self] in self?.syncDividers() }
        return chip
    }

    private func constrain(_ chip: TabChip) {
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalTo: stack.heightAnchor),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxChipWidth),
        ])
        let floor = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.inactiveFloor)
        // Breakable, and below the row's promise to stay inside the strip: past
        // a handful of tabs something has to give, and it should be the tabs
        // narrowing, not `+` sliding under the update pill.
        floor.priority = .defaultHigh
        floor.isActive = true
        // Wide by preference, the way Chrome's are, until there's no room.
        let wide = chip.widthAnchor.constraint(equalToConstant: Self.maxChipWidth)
        wide.priority = .defaultLow
        wide.isActive = true
    }

    private func discard(_ chip: TabChip) {
        stack.removeArrangedSubview(chip)
        chip.removeFromSuperview()
    }

    private var chips: [TabChip] = []
    /// The chip showing each tab, so an opening or closing tab can be found
    /// again rather than inferred from a position that has already shifted.
    private var chipForTab: [ObjectIdentifier: TabChip] = [:]
    /// The rules tying tab widths to each other, rebuilt whenever the tabs or
    /// the active one change.
    private var widthRules: [NSLayoutConstraint] = []

    /// Chromium's two layout domains, as constraints.
    ///
    /// With room to spare, every tab is the same width, up to the standard
    /// one — `tab_strip_layout.cc` calls this the domain above the crossover.
    /// Below it, when the strip is crowded, the active tab keeps a larger
    /// minimum and the inactive ones go on narrowing without it, so the tab you
    /// are in stays readable while the rest become icons.
    ///
    /// This used to be a single rule — every tab the width of the first — so
    /// the tab you were using was squeezed exactly as hard as every other, and
    /// each ⌘T took a slice off the one you were looking at.
    private func syncWidths() {
        NSLayoutConstraint.deactivate(widthRules)
        widthRules.removeAll()
        // A chip on its way in or out is a width of its own for as long as the
        // animation lasts, so it is not held to the others'.
        let settled = chips.filter { !$0.isLeaving }
        let inactive = settled.filter { !$0.isCurrent }

        func rule(_ constraint: NSLayoutConstraint, _ priority: Float) {
            constraint.priority = .init(priority)
            widthRules.append(constraint)
        }

        // The inactive tabs move together: position is the only thing that
        // should vary along the row, since it is the thing you navigate by.
        if let first = inactive.first {
            for chip in inactive.dropFirst() {
                rule(chip.widthAnchor.constraint(equalTo: first.widthAnchor), 997)
            }
        }
        if let current = settled.first(where: \.isCurrent) {
            // Held just under the row's promise to fit, and just over the
            // inactive tabs' agreement to match: a crowded strip takes width
            // from them first.
            rule(current.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.activeFloor), 998)
            if let peer = inactive.first {
                // Never narrower than the others, and the same as them for as
                // long as there is room for that.
                rule(current.widthAnchor.constraint(greaterThanOrEqualTo: peer.widthAnchor), 997)
                rule(current.widthAnchor.constraint(equalTo: peer.widthAnchor), 500)
            }
        }
        NSLayoutConstraint.activate(widthRules)
    }

    // MARK: - Closing mode

    /// Widths held still while you close tabs with the mouse, keyed by chip.
    private var frozen: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var stripTracking: NSTrackingArea?

    /// Close a tab with its button and the others do not grow to fill the gap
    /// until the pointer leaves the strip.
    ///
    /// Chromium's `EnterTabClosingMode`, and the reason for it is the same: the
    /// tabs to the right slide one place left, so the next tab's close button
    /// lands exactly where the pointer already is, and a run of tabs can be
    /// closed without chasing a button that moves after every click. Let the
    /// survivors widen straight away and each click lands somewhere new.
    private func freezeWidths() {
        guard frozen.isEmpty else { return }
        for chip in chips where !chip.isLeaving {
            let hold = chip.widthAnchor.constraint(equalToConstant: chip.frame.width)
            hold.isActive = true
            frozen[ObjectIdentifier(chip)] = hold
        }
    }

    /// Let the tabs settle back to their natural widths.
    private func thaw(animated: Bool) {
        guard !frozen.isEmpty else { return }
        NSLayoutConstraint.deactivate(Array(frozen.values))
        frozen.removeAll()
        guard animated, window?.isVisible == true else {
            needsLayout = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let stripTracking { removeTrackingArea(stripTracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        stripTracking = area
    }

    /// The pointer has left the strip: you are done closing tabs.
    override func mouseExited(with event: NSEvent) {
        thaw(animated: true)
    }

    /// A divider sits after a tab only where both tabs either side of it are
    /// flat: not beside the active one, not beside the one under the pointer,
    /// and not after the last.
    private func syncDividers() {
        let settled = chips.filter { !$0.isLeaving }
        for (index, chip) in settled.enumerated() {
            let next = settled[safe: index + 1]
            chip.showsDivider = next != nil
                && !chip.isRaised && !(next?.isRaised ?? false)
        }
    }

    // MARK: - Standing in for a title bar

    // The strip is drawn *over* the title bar, so every title-bar gesture in
    // the space it covers is now its job: nothing underneath ever sees the
    // click. Empty strip, and the gaps in the tab row, come to us.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === stack || hit === clip ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            doubleClick()
            return
        }
        // Drag the window by the strip, the way a title bar does. This used to
        // happen by itself, by returning nil from `hitTest` and letting the
        // event find the title bar — which it never did, because the title bar
        // is behind us rather than above us. Asking for the drag outright also
        // gets the window snapping and the Space edges for free.
        window?.performDrag(with: event)
    }

    /// Double-clicking a title bar does whatever System Settings ▸ Desktop &
    /// Dock says it does, so this reads the same preference rather than
    /// assuming: zoom is the default, but somebody who set it to minimise
    /// means it here too.
    private func doubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.miniaturize(nil)
        case "None": break
        default: window?.zoom(nil)
        }
    }
}

/// A small control in the strip that draws exactly one shape on hover.
///
/// Not an `NSButton`. On macOS 26 a borderless inline button paints a hover
/// background of its own, and a rounded fill drawn on its layer as well gave
/// two overlapping shapes that were never quite the same size — which is what
/// made the tab's close button look like a lopsided circle.
@MainActor
private final class StripButton: NSView {
    var action: (() -> Void)?

    private let image = NSImageView()
    /// The hover shape, as a layer rather than something drawn in `draw`, so it
    /// can fade. Its own sublayer, not the view's backing layer, because a
    /// backing layer refuses implicit animations.
    private let fill = CALayer()
    private let radius: CGFloat
    private var resting: NSColor = .clear
    private var hover: NSColor = .clear
    private var hovering = false { didSet { paint() } }
    private var pressing = false { didSet { paint() } }

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight,
         side: CGFloat, radius: CGFloat, label: String) {
        self.radius = radius
        super.init(frame: .zero)

        wantsLayer = true
        fill.cornerRadius = radius
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)

        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func paint(tint: NSColor, resting: NSColor, hover: NSColor) {
        image.contentTintColor = tint
        self.resting = resting
        self.hover = hover
        paint()
    }

    private func paint() {
        let colour = pressing
            ? hover.withAlphaComponent(min(1, hover.alphaComponent * 1.6))
            : (hovering ? hover : resting)
        CATransaction.begin()
        // A press should read instantly; only the hover is worth easing.
        CATransaction.setAnimationDuration(pressing ? 0 : TabBar.hoverDuration)
        fill.backgroundColor = colour.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self, userInfo: nil))
        // Tracking areas are rebuilt when the view moves, which is exactly when
        // a hover can go stale: a new tab slides `+` out from under a pointer
        // that never moved, and no exit event is ever sent for that. Ask where
        // the pointer actually is instead of trusting the last event.
        hovering = pointerIsInside
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressing = true }

    override func mouseUp(with event: NSEvent) {
        pressing = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

/// One tab.
///
/// The shape is a layer path rather than a rounded rectangle, because the
/// thing that makes a tab read as Chrome's is its bottom corners: they curve
/// *outwards*, into the surface the tab sits on, so the tab grows out of the
/// content instead of being a box parked on top of it.
///
/// Built once and reconfigured with `apply`. The strip is refreshed whenever
/// anything about a tab changes, which is often, and the view hierarchy and
/// constraints are identical every time.
@MainActor
private final class TabChip: NSView {
    /// The radius of the outward curve at the bottom corners of the active
    /// tab, which is also how far it reaches past the tab's own edges.
    /// Chromium's radii: 10 at the top, 12 at the bottom.
    static let flare: CGFloat = 12
    private static let cornerRadius: CGFloat = 10

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: (() -> Void)?

    /// Active or pointed at: the tabs a divider has no business touching.
    var isRaised: Bool { isActive || hovering }

    /// Whether this is the tab on screen.
    var isCurrent: Bool { isActive }

    /// On its way out: still on the strip, still shrinking, no longer standing
    /// for a tab that exists.
    var isLeaving = false

    /// The width a chip pins itself to while it opens or closes. Required, so
    /// it wins over the equal-width constraints tying the settled chips
    /// together — a tab can be zero wide while its neighbours are not.
    private var pin: NSLayoutConstraint?

    private func pinWidth(_ width: CGFloat) {
        pin?.isActive = false
        let pin = widthAnchor.constraint(equalToConstant: width)
        pin.priority = .required
        pin.isActive = true
        self.pin = pin
    }

    /// Opens from nothing: no width, and no contents on show — a title and an
    /// icon inside a tab that is two points wide are unreadable smears, so
    /// they wait until the tab is the size they were laid out for.
    func prepareToEnter() {
        pinWidth(0)
        showContents(false)
    }

    /// Grow into the space the other tabs have already made.
    func enter() {
        pin?.isActive = false
        pin = nil
    }

    /// Fully open: now the contents can appear.
    func settle() {
        showContents(true)
    }

    private func showContents(_ visible: Bool) {
        for view in [icon, label, closeButton, dot] as [NSView] {
            if visible {
                view.animator().alphaValue = 1
            } else {
                view.alphaValue = 0
            }
        }
    }

    /// Closes to nothing, from exactly the width it has now — measured rather
    /// than recomputed, since it has already been let out of the equal-width
    /// group and would otherwise jump to its natural width first.
    func prepareToLeave() {
        pinWidth(frame.width)
        showsDivider = false
    }

    /// Shrink away where it stands, before the others take the space back.
    func leave() {
        pinWidth(0)
        showContents(false)
        animator().alphaValue = 0
    }

    /// Already gone; here so the second phase has something to ask of it.
    func collapse() {}

    var showsDivider = false {
        didSet {
            guard showsDivider != oldValue else { return }
            divider.isHidden = !showsDivider
        }
    }

    private let shape = CAShapeLayer()
    private let icon = NSImageView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    /// How far the hover shape is held inside the tab's body, and — two points
    /// further in — where the close button's own circle sits. Both come from
    /// here so the circle is evenly inside the hover rather than close to one
    /// edge and clear of the other.
    private static let hoverInset: CGFloat = 3
    private static let closeSide: CGFloat = 16

    private let closeButton = StripButton(
        symbol: "xmark", pointSize: 8, weight: .bold,
        side: closeSide, radius: closeSide / 2, label: "Close Tab (⌘W)")
    private let divider = NSView()

    /// A tab wide enough for a title. Below this it gives the title up, and an
    /// inactive tab its close button, the way Chrome's do — otherwise the row's
    /// smallest possible width is set by contents nobody can read anyway, and
    /// a dozen tabs push the strip past the edge of the window.
    private static let titleFloor: CGFloat = 78

    private var isActive = false
    /// What the shape was last painted as, so `refresh` can tell a hover
    /// (which fades) from a selection (which does not).
    private var paintedActive = false
    /// Set when this tab has just stopped being the active one, so its shape
    /// changes without being animated into its new form. A tab that has just
    /// been deselected is a full-size, terminal-coloured shape turning into a
    /// small transparent one, and morphing it reads as the terminal sliding
    /// out of one tab and into another — which is what made opening a tab look
    /// like it came from somewhere else on the strip.
    private var dropsPathAnimation = false
    /// Whether the close button currently has a slot in the layout at all.
    private var showsClose = true
    /// Pinning the title's trailing edge to the close button, and to the tab's
    /// own edge for when there is no close button to pin it to.
    private var titleToClose: NSLayoutConstraint!
    private var titleToEdge: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var iconCentred: NSLayoutConstraint!
    /// The close button's place in the row, dropped when the tab is too narrow
    /// to hold one. Hiding it is not enough: a hidden view keeps its
    /// constraints, so the space would stay reserved.
    private var closeSlot: [NSLayoutConstraint] = []
    private var hovering = false
    private var activity: Activity = .idle
    private var mark: NSImage?
    private var paintedWeight: NSFont.Weight = .regular

    /// Re-mixed when the terminal theme changes.
    var background: NSColor = .clear {
        didSet {
            guard background != oldValue else { return }
            refresh()
        }
    }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shape)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        // What the tab is doing, as a badge on its icon rather than a dot of
        // its own: Chrome's tabs have exactly one mark before the title, and a
        // second one pushed every title along for a state most tabs aren't in.
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.borderWidth = 1.5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.action = { [weak self] in self?.onClose?() }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        divider.wantsLayer = true
        divider.isHidden = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // Content hangs off the control line, which is the middle of the body,
        // expressed as an offset from the chip's own middle. Positive is down.
        let line = TabBar.controlCentre - TabBar.height / 2
        NSLayoutConstraint.activate([
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: line),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            dot.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -1),
            dot.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -1),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: line),

            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: line),
            divider.widthAnchor.constraint(equalToConstant: 1),
            // Chromium's separator height.
            divider.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Measured to the circle rather than to the glyph, and inset from the
        // hover shape rather than from the tab, so the two are concentric.
        // A tab too narrow for its title is just its mark, and a lone mark
        // pinned to the leading edge looked like a tab with its title cut off
        // rather than one meant to be an icon — so it moves to the middle.
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        iconCentred = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        iconLeading.isActive = true

        closeSlot = [
            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(Self.hoverInset + 2)),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: line),
        ]
        titleToClose = label.trailingAnchor.constraint(
            lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4)
        titleToEdge = label.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -8)
        NSLayoutConstraint.activate(closeSlot + [titleToClose])
    }

    /// Give up the title, then the close button, as the tab narrows.
    ///
    /// The tab you are in keeps its close button at any width, so the tab you
    /// are most likely to want to close always has one.
    private func syncContents() {
        let width = bounds.width
        // Only on the tab you are in and the one under the pointer. A × on
        // every tab was a row of targets nobody was aiming at, and the one
        // strong mark on the strip should be the tab you are in.
        let close = isRaised && width >= (isActive ? 0 : Self.titleFloor)
        let title = width >= Self.titleFloor

        if close != showsClose {
            showsClose = close
            closeButton.isHidden = !close
            titleToClose.isActive = false
            titleToEdge.isActive = false
            NSLayoutConstraint.deactivate(closeSlot)
            if close {
                NSLayoutConstraint.activate(closeSlot)
                titleToClose.isActive = true
            } else {
                titleToEdge.isActive = true
            }
        }
        if label.isHidden != !title { label.isHidden = !title }
        // Centred only when it is alone in the tab: with a close button beside
        // it, a centred mark would sit under the button's hover.
        let centred = !title && !close
        if iconCentred.isActive != centred {
            iconLeading.isActive = false
            iconCentred.isActive = false
            (centred ? iconCentred : iconLeading).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Point this chip at a tab. Every write is guarded, because most calls
    /// change nothing and an unguarded write is a redisplay whether the value
    /// moved or not.
    func apply(
        title: String, icon artwork: NSImage?, isActive: Bool, status: Status,
        background: NSColor
    ) {
        if label.stringValue != title { label.stringValue = title }

        if mark !== artwork || icon.image == nil {
            mark = artwork
            icon.image = artwork ?? NSImage(
                systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }

        if activity != status.activity {
            activity = status.activity
            if let color = status.activity.color {
                dot.isHidden = false
                dot.layer?.backgroundColor = color.cgColor
                if status.activity.pulses {
                    Pulse.apply(to: dot.layer)
                } else {
                    Pulse.remove(from: dot.layer)
                }
            } else {
                dot.isHidden = true
                Pulse.remove(from: dot.layer)
            }
        }

        // The tooltip is where the detail goes: there is no room for words in
        // a tab, and ⌘K is the place that spells it out.
        let tip = [title, status.activity.label, status.detail].compactMap { $0 }
        toolTip = tip.joined(separator: " · ")

        let activeChanged = self.isActive != isActive
        self.isActive = isActive
        let backgroundChanged = self.background != background
        self.background = background
        if activeChanged && !backgroundChanged { refresh() }
    }

    override func layout() {
        // Before `super`, so the constraints it swaps are the ones this pass
        // lays out. After it, a tab that had just become active kept its
        // close button wherever it was last put until something else happened
        // to lay the tab out again — which could be never.
        syncContents()
        super.layout()
        let path = isActive ? activePath() : hoverPath()

        // A tab's shape is a path, not a rounded rectangle, so it does not come
        // along for free when the view's frame animates: without this the
        // opening tab's outline snaps to full width while the tab itself is
        // still sliding open.
        let context = NSAnimationContext.current
        let morphs = !dropsPathAnimation
        dropsPathAnimation = false
        if morphs, context.allowsImplicitAnimation, context.duration > 0,
           let from = shape.presentation()?.path ?? shape.path {
            let slide = CABasicAnimation(keyPath: "path")
            slide.fromValue = from
            slide.toValue = path
            slide.duration = context.duration
            slide.timingFunction = context.timingFunction
            shape.add(slide, forKey: "path")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }

    /// Rounded top, flared bottom. One point deeper than the chip, so it covers
    /// the card's top hairline where the two meet and the join has no seam.
    private func activePath() -> CGPath {
        let w = bounds.width
        let bottom: CGFloat = -1
        let top = bounds.height - TabBar.tabTop
        let r = Self.cornerRadius
        let f = Self.flare
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -f, y: bottom))
        path.addArc(center: CGPoint(x: -f, y: bottom + f), radius: f,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: top - r))
        path.addArc(center: CGPoint(x: r, y: top - r), radius: r,
                    startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: w - r, y: top))
        path.addArc(center: CGPoint(x: w - r, y: top - r), radius: r,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: w, y: bottom + f))
        path.addArc(center: CGPoint(x: w + f, y: bottom + f), radius: f,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// An inactive tab lifts as a plain rounded shape, held just clear of the
    /// card: only the active tab is joined to the content. Always drawn, and
    /// only filled while the pointer is on it, so the hover can fade in and
    /// out rather than appear.
    private func hoverPath() -> CGPath {
        // Held well inside the tab's own edges. Tabs abut — the hairline
        // between them is the only thing separating two flat ones — so a hover
        // inset by a point ran right up against the tab beside it and the two
        // read as one wide shape. Three points leaves six between neighbours.
        //
        // Inset by the same amount top and bottom, which is what puts its
        // middle on the row of content: it used to be held off the bottom only,
        // so the shape sat a point and a half above the icon, title and close
        // button it was meant to be around.
        let inset = Self.hoverInset
        let body = NSRect(
            x: inset, y: inset,
            width: bounds.width - inset * 2,
            height: bounds.height - TabBar.tabTop - inset * 2)
        return CGPath(roundedRect: body, cornerWidth: 7, cornerHeight: 7, transform: nil)
    }

    /// Repaint from the current state.
    func refresh() {
        let ground = Chrome.ground(for: background)
        let surface = isActive ? background : ground
        let ink = Chrome.ink(over: surface)

        // A hover fades; becoming the active tab does not. Selecting a tab is
        // instant everywhere else in the strip — the terminal below it has
        // already changed — and left to itself Core Animation faded this, so a
        // tab you had just clicked spent a quarter of a second as a grey ghost
        // of the one you clicked off. That was the flicker on every tab switch.
        let switched = paintedActive != isActive
        if switched, !isActive { dropsPathAnimation = true }
        paintedActive = isActive
        CATransaction.begin()
        CATransaction.setDisableActions(switched)
        if !switched { CATransaction.setAnimationDuration(TabBar.hoverDuration) }
        shape.fillColor = isActive
            ? background.cgColor
            : Chrome.ink(over: ground)(hovering ? 0.07 : 0).cgColor
        CATransaction.commit()
        label.textColor = ink(isActive ? 0.92 : (hovering ? 0.8 : 0.62))
        // The tab you are in is set a weight heavier, the way the one you are
        // on reads in any list: colour alone was a subtle difference on a
        // strip where every other tab is the same grey.
        let weight: NSFont.Weight = isActive ? .medium : .regular
        if paintedWeight != weight {
            paintedWeight = weight
            label.font = .systemFont(ofSize: 12.5, weight: weight)
        }
        closeButton.paint(tint: ink(isActive ? 0.7 : 0.5), resting: .clear, hover: ink(0.14))
        icon.contentTintColor = (mark == nil || mark?.isTemplate == true)
            ? ink(isActive ? 0.7 : 0.5) : nil
        // Ringed in the colour behind it, so the badge reads as sitting on the
        // icon rather than as a blot touching it.
        dot.layer?.borderColor = surface.cgColor
        divider.layer?.backgroundColor = Chrome.ink(over: ground)(0.16).cgColor
        // The active tab's flares reach over its neighbours' edges, so it has
        // to be drawn above them.
        layer?.zPosition = isActive ? 1 : 0
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self,
            userInfo: nil))
        // Same reason as `StripButton`: tabs reflow under a still pointer when
        // one opens or closes, and nothing tells the tab that moved away.
        let inside = window.map {
            bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        if inside != hovering {
            hovering = inside
            refresh()
            onHover?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
        syncContents()
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
        syncContents()
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    /// Middle-click closes, as it does on every browser tab.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        onClose?()
    }
}
