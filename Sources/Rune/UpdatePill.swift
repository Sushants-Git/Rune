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
                 tint: .controlAccentColor, actionable: true)
        case .downloading(_, let fraction):
            let text = fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
            show(text, symbol: "arrow.down.circle", tint: .secondaryLabelColor,
                 progress: fraction)
        case .readyToInstall:
            show("Restart to update", symbol: "checkmark.circle.fill",
                 tint: .controlAccentColor, actionable: true)
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
