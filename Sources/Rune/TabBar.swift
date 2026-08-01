import Cocoa

/// A compact tab strip that lives *inside* the title bar, to the right of the
/// window controls.
///
/// It deliberately costs no vertical space beyond the title bar Rune already
/// reserves, which is the whole point: the strip is for the handful of tabs you
/// want one click away, and everything else lives in the ⌘K switcher.
///
/// With a single tab there is nothing to switch between, so the strip gets out
/// of the way entirely and the title bar just names what's running, centred.
@MainActor
final class TabBar: NSView {
    /// Height of the strip. Matches the title bar inset so the terminal below
    /// is unaffected by the bar existing.
    static let height: CGFloat = 28

    /// Space reserved for the traffic lights.
    private static let leadingInset: CGFloat = 78
    private static let maxChipWidth: CGFloat = 160

    /// Painted to match the terminal below, so the title bar reads as part of
    /// the same surface rather than as a separate strip of chrome.
    var backgroundColor: NSColor = .clear {
        didSet {
            guard backgroundColor != oldValue else { return }
            layer?.backgroundColor = backgroundColor.cgColor
            // Chips are mixed from this colour, so they have to be re-mixed —
            // but only the colour, not the whole strip. Rebuilding here as well
            // meant every chrome sync built the strip twice.
            for chip in chips { chip.background = backgroundColor }
        }
    }

    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    var onNewTab: (() -> Void)?
    /// The zoom indicator was clicked — put the pane back.
    var onResetZoom: (() -> Void)?

    private let stack = NSStackView()
    private let newButton = NSButton()
    /// What the title bar shows instead of a strip when there's one tab.
    private let titleLabel = NSTextField(labelWithString: "")
    /// Sits at the trailing end and is usually invisible. See `UpdatePill`.
    private let updatePill = UpdatePill()
    /// Shown only while a pane is zoomed. See `update(tabs:...)`.
    private let zoomButton = NSButton()
    /// The trailing end of the bar. A stack rather than pinned views because
    /// both of these are usually absent, and `NSStackView` collapses hidden
    /// arranged subviews for free — which is exactly the behaviour wanted, so
    /// the centred title gets the whole bar back when neither is showing.
    private let trailingCluster = NSStackView()

    private var tabs: [Tab] = []
    private weak var active: Tab?
    private var workspaceName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true

        // Tabs are flush rectangles filling the strip's height, editor-style:
        // the active one is the same colour as the terminal below it, so it
        // reads as attached to what it's showing rather than floating above it.
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        newButton.title = ""
        newButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newButton.imagePosition = .imageOnly
        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.contentTintColor = .tertiaryLabelColor
        newButton.target = self
        newButton.action = #selector(newTabClicked)
        newButton.toolTip = "New Tab (⌘T)"
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newButton)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        // A zoomed pane hides its siblings, and a terminal that is simply
        // missing the other panes looks the same as one that never had them.
        // This is the difference, and it's a button because the thing you want
        // on seeing it is almost always to undo it.
        zoomButton.title = ""
        zoomButton.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: "Pane zoomed")
        zoomButton.imagePosition = .imageOnly
        zoomButton.isBordered = false
        zoomButton.bezelStyle = .inline
        zoomButton.contentTintColor = .controlAccentColor
        zoomButton.target = self
        zoomButton.action = #selector(resetZoomClicked)
        zoomButton.toolTip = "Pane zoomed — click to restore the splits (⌘⇧↵)"
        zoomButton.isHidden = true
        zoomButton.translatesAutoresizingMaskIntoConstraints = false

        trailingCluster.orientation = .horizontal
        trailingCluster.alignment = .centerY
        trailingCluster.spacing = 6
        trailingCluster.setViews([zoomButton, updatePill], in: .leading)
        trailingCluster.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingCluster)

        NSLayoutConstraint.activate([
            trailingCluster.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12),
            trailingCluster.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 20),

            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            newButton.leadingAnchor.constraint(
                equalTo: stack.trailingAnchor, constant: 6),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 20),
            newButton.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingCluster.leadingAnchor, constant: -8),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Clear of the traffic lights on both sides, so a long title
            // truncates rather than sliding under them — and clear of the
            // update pill on the trailing side when there is one.
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Self.leadingInset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.leadingInset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingCluster.leadingAnchor, constant: -8),
        ])
    }

    /// Rebuild the strip from the active workspace's tabs. `workspaceName` is
    /// the ⌘R name, if one is set — it wins over the terminal's own title,
    /// since naming a workspace and then not seeing the name would be odd.
    func update(
        tabs: [Tab], active: Tab?, workspaceName: String? = nil, isZoomed: Bool = false
    ) {
        self.tabs = tabs
        self.active = active
        self.workspaceName = workspaceName
        zoomButton.isHidden = !isZoomed

        // One tab is nothing to choose between: name it and show no chrome.
        let single = tabs.count <= 1
        stack.isHidden = single
        newButton.isHidden = single
        titleLabel.isHidden = !single
        if single {
            let title = workspaceName ?? active?.title ?? ""
            if titleLabel.stringValue != title { titleLabel.stringValue = title }
        }

        // Chips are reused rather than rebuilt. This runs on every status
        // change and every title change, and tearing down a stack view's
        // arranged subviews forces a full constraint solve each time — which,
        // once a second under a busy terminal, you can feel.
        if chips.count > tabs.count {
            for chip in chips[tabs.count...] {
                stack.removeArrangedSubview(chip)
                chip.removeFromSuperview()
            }
            chips.removeLast(chips.count - tabs.count)
        }
        while chips.count < tabs.count {
            let chip = TabChip(maxWidth: Self.maxChipWidth)
            let position = chips.count
            chip.onSelect = { [weak self] in
                guard let self, let tab = self.tabs[safe: position] else { return }
                self.onSelect?(tab)
            }
            chip.onClose = { [weak self] in
                guard let self, let tab = self.tabs[safe: position] else { return }
                self.onClose?(tab)
            }
            chips.append(chip)
            stack.addArrangedSubview(chip)
        }

        for (chip, tab) in zip(chips, tabs) {
            chip.apply(
                title: tab.title,
                isActive: tab === active,
                status: tab.status,
                background: backgroundColor)
        }
    }

    private var chips: [TabChip] = []

    @objc private func newTabClicked() {
        onNewTab?()
    }

    @objc private func resetZoomClicked() {
        onResetZoom?()
    }

    // The strip overlaps the draggable title bar, so let clicks that miss a
    // chip fall through to the window for dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One tab in the strip: a flush rectangle the full height of the bar, with an
/// accent edge along the top of the active one.
///
/// Built once and reconfigured with `apply`. The strip is refreshed whenever
/// anything about a tab changes, which is often, and the view hierarchy and
/// constraints are identical every time — so they're set up here and only the
/// values move.
@MainActor
private final class TabChip: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let accent = NSView()
    private let separator = NSView()
    private let dot = NSView()
    private var dotWidth: NSLayoutConstraint!
    /// Closes up when there is no dot, so a quiet tab's title doesn't sit in a
    /// gap where one used to be.
    private var labelGap: NSLayoutConstraint!

    private var isActive = false
    private var hovering = false
    private var activity: Activity = .idle

    /// Re-mixed when the terminal theme changes.
    var background: NSColor = .clear {
        didSet {
            guard background != oldValue else { return }
            updateBackground()
        }
    }

    init(maxWidth: CGFloat) {
        super.init(frame: .zero)

        wantsLayer = true

        // A 2pt bar along the top edge marks the active tab. It sits on the
        // boundary rather than around the tab, so nothing boxes in the title.
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        accent.isHidden = true
        accent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accent)

        // A hairline between neighbours, since there is no gap to separate them.
        // Its colour is mixed in `updateBackground` rather than taken from
        // `labelColor`: a CGColor on a layer is resolved once and stays
        // resolved, and chips are no longer rebuilt when the theme flips.
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // The dot goes ahead of the name, where the eye lands first when
        // scanning the strip. It's always in the hierarchy and collapses to
        // zero width when there's nothing to say, so the layout never changes
        // shape underneath a tab that merely went quiet.
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // Matching the `isActive = false` this starts in. `apply` only touches
        // these when active-ness *changes*, so the resting state has to be
        // correct from the outset.
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // Revealed on hover so idle tabs stay quiet.
        closeButton.isHidden = true
        addSubview(closeButton)

        dotWidth = dot.widthAnchor.constraint(equalToConstant: 0)
        labelGap = label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),

            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.trailingAnchor.constraint(equalTo: trailingAnchor),
            accent.heightAnchor.constraint(equalToConstant: 2),

            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dotWidth,

            labelGap,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Point this chip at a tab. Every write is guarded, because most calls
    /// change nothing and an unguarded `stringValue` or `backgroundColor` is a
    /// redisplay whether the value moved or not.
    func apply(title: String, isActive: Bool, status: Status, background: NSColor) {
        if label.stringValue != title { label.stringValue = title }

        let activeChanged = self.isActive != isActive
        if activeChanged {
            self.isActive = isActive
            accent.isHidden = !isActive
            label.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
            label.textColor = isActive ? .labelColor : .secondaryLabelColor
            closeButton.isHidden = !isActive && !hovering
        }

        if activity != status.activity {
            activity = status.activity
            if let color = status.activity.color {
                dot.isHidden = false
                dot.layer?.backgroundColor = color.cgColor
                dotWidth.constant = 6
                labelGap.constant = 6
                if status.activity.pulses {
                    Pulse.apply(to: dot.layer)
                } else {
                    Pulse.remove(from: dot.layer)
                }
            } else {
                dot.isHidden = true
                Pulse.remove(from: dot.layer)
                dotWidth.constant = 0
                labelGap.constant = 0
            }
        }

        // The tooltip is where the detail goes: there is no room for words in
        // a chip this size, and ⌘K is the place that spells it out.
        let tip = [status.activity.label, status.detail].compactMap { $0 }
        toolTip = tip.isEmpty ? nil : tip.joined(separator: " — ")

        let backgroundChanged = self.background != background
        self.background = background
        // The chip's fill depends on which tab is active as well as on the
        // theme, and `background`'s own guard only catches the theme half.
        if activeChanged && !backgroundChanged { updateBackground() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        closeButton.isHidden = false
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        closeButton.isHidden = !isActive
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// The active tab is the terminal's own colour, so it reads as continuous
    /// with the content below it; the rest are sunk behind it. Blending toward
    /// black rather than overlaying a translucent black keeps the strip opaque,
    /// which matters because the title bar is transparent.
    private func updateBackground() {
        let sink: CGFloat = isActive ? 0 : (hovering ? 0.10 : 0.20)
        let color = background.blended(withFraction: sink, of: .black) ?? background
        layer?.backgroundColor = color.cgColor
        separator.layer?.backgroundColor = (background.isDark ? NSColor.white : .black)
            .withAlphaComponent(0.10).cgColor
    }
}
