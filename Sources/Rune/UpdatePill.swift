import Cocoa

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
    /// Width the strip should reserve for it — zero when there's nothing to
    /// show, so the title beside it gets the whole bar back.
    var isShowing: Bool { !isHidden }

    /// Called when the pill appears or disappears, so the strip can re-do the
    /// layout that depends on whether it's taking up room.
    var onVisibilityChange: (() -> Void)?

    private let button = NSButton()

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
        button.layer?.cornerRadius = 5
        button.layer?.cornerCurve = .continuous
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 19),
            heightAnchor.constraint(equalToConstant: 19),
        ])
    }

    @objc private func stateChanged() {
        apply(Updater.shared.state)
    }

    private func apply(_ state: Updater.State) {
        let wasShowing = isShowing

        switch state {
        case .idle:
            isHidden = true
        case .checking:
            show("Checking…", symbol: "arrow.triangle.2.circlepath", tint: .secondaryLabelColor)
        case .available(let release):
            show("Update to \(release.version)",
                 symbol: "arrow.down.circle.fill",
                 tint: .controlAccentColor)
        case .downloading(_, let fraction):
            let text = fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
            show(text, symbol: "arrow.down.circle", tint: .secondaryLabelColor)
        case .readyToInstall:
            show("Restart to Update",
                 symbol: "checkmark.circle.fill",
                 tint: .controlAccentColor)
        case .upToDate:
            show("You're up to date", symbol: "checkmark", tint: .secondaryLabelColor)
        case .failed(let reason):
            // The reason itself when it fits. A pill that only ever says
            // "Update failed" makes every outcome look identical, including the
            // ones that aren't really failures — "No releases visible" is a
            // fact about the repository, not a broken download.
            show(reason.count <= 24 ? reason : "Update failed",
                 symbol: "exclamationmark.triangle", tint: .systemOrange)
            toolTip = reason
        }

        // Only the states you can act on should look like buttons.
        switch state {
        case .available, .readyToInstall, .failed:
            button.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.14).cgColor
        default:
            button.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if isShowing != wasShowing { onVisibilityChange?() }
    }

    private func show(_ text: String, symbol: String, tint: NSColor) {
        isHidden = false
        toolTip = nil
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(
            string: " \(text)",
            attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])
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
