import Cocoa

/// A miniature ⌘K panel, drawn with the settings currently chosen.
///
/// The alternative is captions: "the ⌘K panel's background", "how much of the
/// terminal the backdrop carries away". Nobody can picture a backdrop from a
/// percentage, and nobody should have to close the window and press ⌘K to find
/// out what they just did. It is the same panel code's colours, so what is
/// shown here is what appears.
@MainActor
final class SwitcherPreview: NSView {
    private let terminal = NSTextField(labelWithString: "")
    private let panel = NSView()
    private let scrim = NSView()
    private let rows = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        // Something behind the panel, so the backdrop has something to dim.
        terminal.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        terminal.stringValue = "› npm run dev\n  ready in 320 ms\n› git status\n  nothing to commit"
        terminal.maximumNumberOfLines = 0
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)

        scrim.wantsLayer = true
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        panel.wantsLayer = true
        panel.layer?.cornerRadius = 6
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 116),

            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62),

            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Redraw from the settings as they stand.
    func refresh() {
        let background = NSApp.ghosttyApp?.backgroundColor ?? .black
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        terminal.textColor = (background.isLight ? NSColor.black : .white)
            .withAlphaComponent(0.45)

        // The backdrop, at whatever fraction the slider says.
        scrim.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(Settings.shared.backdropDim * 0.85).cgColor

        panel.layer?.backgroundColor = PaletteStyle.background.cgColor
        panel.layer?.borderColor = PaletteStyle.border.cgColor

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, name) in ["rune", "api", "docs"].enumerated() {
            rows.addArrangedSubview(row(name, selected: index == 1))
        }
    }

    /// One row of the fake list: a tile, a name, and the accent on the one
    /// that is highlighted, since that is what the accent is for.
    private func row(_ name: String, selected: Bool) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 2
        tile.layer?.backgroundColor = PaletteStyle.markPlate.cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = PaletteStyle.primaryText

        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 3
        let accent = Settings.shared.accent ?? .controlAccentColor
        holder.layer?.backgroundColor = selected
            ? accent.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        holder.translatesAutoresizingMaskIntoConstraints = false

        let line = NSStackView(views: [tile, label])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 5
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 10),
            tile.heightAnchor.constraint(equalToConstant: 10),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 5),
            line.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3),
            line.trailingAnchor.constraint(
                lessThanOrEqualTo: holder.trailingAnchor, constant: -5),
        ])
        return holder
    }
}
