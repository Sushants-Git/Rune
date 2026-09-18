import Cocoa

/// Shared metrics for the small controls at the trailing end of the title bar.
///
/// There are only two of them and they sit side by side, so they have to agree
/// on height and corner radius or they read as two unrelated things that
/// happen to be next to each other — which is exactly how they used to look.
@MainActor
enum Chrome {
    static let controlHeight: CGFloat = 19
    static let cornerRadius: CGFloat = 5

    // The terminal fills the window under the strip: no margin, no corners of
    // its own, no hairline. It was inset by 8pt with a rounded, hairlined edge
    // for a while — a card on the window's ground — and the strip was built on
    // top of that. The margin turned out to be three strips of wasted window,
    // and the hairline read as a stray white line across the top of the
    // terminal. What the card was for survives without it: the ground still
    // shows *behind the strip*, which is all the active tab needs to look like
    // it grew out of the terminal rather than sitting on it.

    /// Ink of the right polarity for whatever it is being drawn over: white
    /// over a dark terminal theme, black over a light one.
    ///
    /// The chrome takes its colours from the terminal, and the terminal can be
    /// any colour at all — so nothing up here may name a fixed grey. Returns a
    /// function so a caller mixes several weights from one decision.
    static func ink(over background: NSColor) -> (CGFloat) -> NSColor {
        let dark = background.isDark
        return { alpha in
            dark
                ? NSColor(white: 1, alpha: alpha)
                // Black reads heavier than white at the same alpha, so a light
                // theme gets a little less of it.
                : NSColor(white: 0, alpha: alpha * 0.85)
        }
    }

    /// What the tab strip is painted on: a lighter shade of the terminal's own
    /// colour on a dark theme, a slightly deeper one on a light theme, so an
    /// inactive tab has something to be inactive *against*.
    ///
    /// A *shade*, moved in brightness with the hue and saturation held, not a
    /// mix toward white. Mixing toward white also washes the colour out, so a
    /// blue-black terminal sat under a flat grey strip that looked like it
    /// belonged to some other app. Held to a small step for the same reason:
    /// the strip should read as the terminal's own surroundings.
    static func ground(for terminal: NSColor) -> NSColor {
        guard let rgb = terminal.usingColorSpace(.sRGB) else { return terminal }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = terminal.isDark ? min(1, brightness + 0.06) : max(0, brightness - 0.05)
        return NSColor(hue: hue, saturation: saturation, brightness: shifted, alpha: alpha)
    }
}

/// A title-bar control that lifts slightly under the pointer.
///
/// Neither of these looked clickable — one was a bare glyph and the other a
/// flat tint — and in a title bar, where most of what you see is decoration,
/// something has to say "this responds". A brightening on hover is the
/// cheapest version of that and the one every other Mac control uses.
@MainActor
final class ChromeButton: NSButton {
    /// The resting fill. Hover mixes upwards from it, so a caller only has to
    /// set this one colour.
    var restingBackground: NSColor = .clear {
        didSet { applyBackground() }
    }

    /// Breathing room either side of the content, on top of what the cell asks
    /// for.
    ///
    /// An `.inline` button sizes itself to its content almost exactly, which is
    /// fine while the background is clear and wrong the moment it isn't: the
    /// glyph ends up against the left edge of the tint and the last letter
    /// against the right, so the fill reads as a box cropped around the words
    /// rather than a pill they sit inside.
    var horizontalPadding: CGFloat = 0 {
        didSet {
            guard horizontalPadding != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard size.width != NSView.noIntrinsicMetric else { return size }
        size.width += horizontalPadding * 2
        return size
    }

    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyBackground()
    }

    private func applyBackground() {
        // Transparent controls stay transparent at rest — "Checking…" and
        // "You're up to date" are notices, not buttons — but they still take a
        // faint wash on hover, because they do have a right-click menu.
        let colour = hovering
            ? restingBackground.blended(withFraction: 0.5, of: .white)?
                .withAlphaComponent(max(restingBackground.alphaComponent, 0.10) + 0.08)
                ?? restingBackground
            : restingBackground
        layer?.backgroundColor = colour.cgColor
    }
}

/// The one piece of UI the updater has: a small pill at the trailing end of the
/// title bar that appears when there's something to say and disappears again
/// when there isn't.
///
/// It's a button, and the thing it does is always the obvious next step —
/// "Update to 0.2.0" downloads, "Restart to Update" installs. A pill that
/// merely announced an update and made you go find the real control would be
/// two steps where the whole point is one.
///
/// Nothing about it is modal. An update is never urgent enough to interrupt what
/// you're typing into a terminal, so it waits in the chrome until you're
/// interested, and a right-click offers the release notes for when you are.
@MainActor
final class UpdatePill: NSView {
    private let button = ChromeButton()

    /// Fills the pill left-to-right as the download runs.
    ///
    /// The percentage is already in the label, so this isn't telling you
    /// anything new — but a number that changes every few hundred milliseconds
    /// is something you have to read, and a bar is something you can see from
    /// the corner of your eye. That is the whole job of a download indicator in
    /// a title bar.
    private let progressLayer = CALayer()
    private var progress: Double?

    /// One configuration for every symbol here, so a filled circle and a bare
    /// checkmark come out the same optical size beside 11pt text. Left to
    /// themselves they don't — SF Symbols are sized by their own bounding box,
    /// and `checkmark` has far less of one than `arrow.down.circle.fill`.
    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 11, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        // Selector-based rather than block-based: NotificationCenter holds this
        // one weakly and drops it when the pill goes away, so a closed window's
        // pill doesn't need unregistering from a `deinit` that can't touch it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: Updater.stateChanged, object: nil)
        // The pill is tinted with the accent, so a change in Settings has to
        // repaint it — `apply` is idempotent and rebuilds from the same state.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: Settings.changed, object: nil)
        apply(Updater.shared.state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(clicked)
        button.font = .systemFont(ofSize: 11, weight: .medium)
        // Enough that the tinted states read as a pill rather than as a
        // highlight sitting directly on the text. The zoom button beside it
        // keeps its fixed 24pt square, so it wants none of this.
        button.horizontalPadding = 7
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Chrome.cornerRadius
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = true
        addSubview(button)

        progressLayer.cornerCurve = .continuous
        button.layer?.insertSublayer(progressLayer, at: 0)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
            heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
        ])
    }

    override func layout() {
        super.layout()
        layoutProgress()
    }

    private func layoutProgress() {
        guard let progress else {
            progressLayer.isHidden = true
            return
        }
        progressLayer.isHidden = false
        // Implicit animation off: the fraction arrives every time a chunk
        // lands, and Core Animation's default quarter-second crossfade turns a
        // steady climb into a bar that lurches and lags behind the number.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = CGRect(
            x: 0, y: 0,
            width: button.bounds.width * max(0, min(1, progress)),
            height: button.bounds.height)
        CATransaction.commit()
    }

    @objc private func stateChanged() {
        apply(Updater.shared.state)
    }

    private func apply(_ state: Updater.State) {
        // Sentence case throughout. "Restart to Update" was the odd one out,
        // and a title-cased phrase beside "You're up to date" reads as a
        // proper noun rather than an instruction.
        //
        // The symbols are one family too: a download arrow while there is
        // downloading to do, a check when there isn't, and the same circle
        // around both. Filled marks the two states worth acting on.
        switch state {
        case .idle:
            isHidden = true
            progress = nil
        case .checking:
            show("Checking…", symbol: "arrow.triangle.2.circlepath",
                 tint: .secondaryLabelColor)
        case .available(let release):
            show("Update to \(release.version)", symbol: "arrow.down.circle.fill",
                 tint: Settings.shared.effectiveAccent, actionable: true)
        case .downloading(_, let fraction):
            let text = fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
            show(text, symbol: "arrow.down.circle", tint: .secondaryLabelColor,
                 progress: fraction)
        case .readyToInstall:
            show("Restart to update", symbol: "checkmark.circle.fill",
                 tint: Settings.shared.effectiveAccent, actionable: true)
        case .upToDate:
            show("You're up to date", symbol: "checkmark.circle", tint: .secondaryLabelColor)
        case .failed(let reason):
            // The reason itself when it fits. A pill that only ever said
            // "Update failed" would make every outcome look identical,
            // including the ones that aren't really failures — "No releases
            // visible" is a fact about the repository, not a broken download.
            show(reason.count <= 24 ? reason : "Update failed",
                 symbol: "exclamationmark.triangle.fill", tint: .systemOrange,
                 actionable: true)
            toolTip = reason
        }
    }

    /// - Parameters:
    ///   - actionable: draws the pill as a button. The background is mixed from
    ///     `tint` rather than always being the accent colour, which is what put
    ///     orange warning text on a blue button.
    ///   - progress: fills the pill behind the label as it climbs.
    private func show(
        _ text: String, symbol: String, tint: NSColor,
        actionable: Bool = false, progress: Double? = nil
    ) {
        isHidden = false
        toolTip = nil
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration)
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(
            string: " \(text)",
            attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])

        button.restingBackground = actionable
            ? tint.withAlphaComponent(0.15)
            : (progress == nil ? .clear
                               : NSColor.secondaryLabelColor.withAlphaComponent(0.10))
        progressLayer.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.16).cgColor

        self.progress = progress
        layoutProgress()
    }

    @objc private func clicked() {
        switch Updater.shared.state {
        case .available: Updater.shared.download()
        case .readyToInstall: Updater.shared.install()
        case .failed: NSWorkspace.shared.open(Updater.releasesPage)
        default: break
        }
    }

    /// Right-click goes to the release notes. The pill's own click is reserved
    /// for the action, so this is where "what's actually in it" lives.
    override func menu(for event: NSEvent) -> NSMenu? {
        let release: Updater.Release?
        switch Updater.shared.state {
        case .available(let value), .downloading(let value, _), .readyToInstall(let value):
            release = value
        default:
            release = nil
        }
        guard let release else { return nil }

        let menu = NSMenu()
        let item = NSMenuItem(
            title: "What's New in \(release.version)…",
            action: #selector(openNotes), keyEquivalent: "")
        item.target = self
        item.representedObject = release.page
        menu.addItem(item)
        return menu
    }

    @objc private func openNotes(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(page)
    }
}
