import Cocoa

/// A compact tab strip that lives *inside* the title bar, to the right of the
/// window controls.
///
/// It deliberately costs no vertical space beyond the title bar kterm already
/// reserves, which is the whole point: the strip is for the handful of tabs you
/// want one click away, and everything else lives in the ⌘K switcher.
@MainActor
final class TabBar: NSView {
    /// Height of the strip. Matches the title bar inset so the terminal below
    /// is unaffected by the bar existing.
    static let height: CGFloat = 28

    /// Space reserved for the traffic lights.
    private static let leadingInset: CGFloat = 78
    private static let chipSpacing: CGFloat = 4
    private static let maxChipWidth: CGFloat = 120

    var onSelect: ((GhosttySurfaceView) -> Void)?
    var onClose: ((GhosttySurfaceView) -> Void)?
    var onNewTab: (() -> Void)?

    private let stack = NSStackView()
    private let newButton = NSButton()
    /// Shown only when the active surface is a ⌘N terminal, which by design has
    /// no chip of its own — without this you'd have no idea where you are.
    private let elsewhereLabel = NSTextField(labelWithString: "")

    private var tabs: [GhosttySurfaceView] = []
    private weak var active: GhosttySurfaceView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        stack.orientation = .horizontal
        stack.spacing = Self.chipSpacing
        stack.alignment = .centerY
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

        elsewhereLabel.font = .systemFont(ofSize: 11)
        elsewhereLabel.textColor = .tertiaryLabelColor
        elsewhereLabel.lineBreakMode = .byTruncatingTail
        elsewhereLabel.translatesAutoresizingMaskIntoConstraints = false
        elsewhereLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(elsewhereLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            newButton.leadingAnchor.constraint(
                equalTo: stack.trailingAnchor, constant: Self.chipSpacing),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 20),

            elsewhereLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: newButton.trailingAnchor, constant: 8),
            elsewhereLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12),
            elsewhereLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Rebuild the strip. `tabs` is the bar's own list; `active` may be a
    /// surface that isn't in it (a ⌘N terminal).
    func update(tabs: [GhosttySurfaceView], active: GhosttySurfaceView?) {
        self.tabs = tabs
        self.active = active

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for tab in tabs {
            let chip = TabChip(
                title: tab.shortTitle,
                isActive: tab === active,
                maxWidth: Self.maxChipWidth)
            chip.onSelect = { [weak self, weak tab] in
                guard let tab else { return }
                self?.onSelect?(tab)
            }
            chip.onClose = { [weak self, weak tab] in
                guard let tab else { return }
                self?.onClose?(tab)
            }
            stack.addArrangedSubview(chip)
        }

        if let active, active.kind == .background {
            elsewhereLabel.stringValue = "⌘K · \(active.shortTitle)"
            elsewhereLabel.isHidden = false
        } else {
            elsewhereLabel.isHidden = true
        }
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }

    // The strip overlaps the draggable title bar, so let clicks that miss a
    // chip fall through to the window for dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One tab in the strip.
@MainActor
private final class TabChip: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private var hovering = false

    init(title: String, isActive: Bool, maxWidth: CGFloat) {
        self.isActive = isActive
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5

        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // Revealed on hover so idle tabs stay quiet.
        closeButton.isHidden = true
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
        ])

        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        closeButton.isHidden = true
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func updateBackground() {
        let color: NSColor = if isActive {
            .quaternaryLabelColor
        } else if hovering {
            .quaternaryLabelColor.withAlphaComponent(0.5)
        } else {
            .clear
        }
        layer?.backgroundColor = color.cgColor
    }
}
