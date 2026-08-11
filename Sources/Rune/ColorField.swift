import Cocoa

/// A colour well with its hex beside it, editable either way.
///
/// The well on its own can only be read by eye and only be set by pointing at
/// something. That is fine for choosing a colour and useless for the two things
/// people actually do with these: copying the value somewhere else — a config
/// file, a theme, a message to someone — and typing in a value they already
/// have. macOS's own colour panel does carry a hex field, but it is three
/// clicks deep and closes over the window, so the value is not visible at the
/// moment you are looking at the row it belongs to.
///
/// Both halves show the same colour at all times. Picking in the well rewrites
/// the field as you drag; committing the field moves the well.
@MainActor
final class ColorField: NSView {
    /// Fired when the user picks or types a new colour — not when a caller sets
    /// `color` to show what the current state already is.
    var onChange: ((NSColor) -> Void)?

    let well = NSColorWell()
    private let hexField = NSTextField()

    /// What the field last *committed* to, as opposed to whatever half-typed
    /// text is in it right now. Both the "nothing changed" test and the restore
    /// after bad input measure against this, and it is not always a hex — see
    /// `show`.
    private var shownText = ""

    /// The colour both halves are showing.
    var color: NSColor {
        get { well.color }
        set {
            well.color = newValue
            display(Self.hex(newValue))
        }
    }

    private func display(_ text: String) {
        hexField.stringValue = text
        shownText = text
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        well.target = self
        well.action = #selector(wellChanged)
        SettingsWindowController.style(well)

        // Monospaced, because the field's whole job is a fixed-shape token that
        // gets read digit by digit and copied. In a proportional face the same
        // six characters change width as you type them.
        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.controlSize = .small
        hexField.alignment = .center
        hexField.target = self
        hexField.action = #selector(hexCommitted)
        // Committing on focus loss as well as on Return: nobody presses Return
        // in a settings window before clicking the next thing.
        hexField.delegate = self
        hexField.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for `#rrggbb` and for the longest colour *name* Ghostty
        // might have in the file, which the field shows verbatim rather than
        // pretending to be a hex it isn't.
        hexField.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let stack = NSStackView(views: [hexField, well])
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Show a value that may not be a colour Rune can parse.
    ///
    /// Ghostty accepts colours by name — `red`, `cyan` — and those don't round
    /// trip through a well. Rather than print the `#000000` the well falls back
    /// to and state something the file doesn't say, the field shows the file's
    /// own word until someone picks or types over it.
    func show(_ text: String) {
        if let parsed = Self.color(from: text) {
            color = parsed
        } else {
            well.color = .black
            display(text)
        }
    }

    var isEnabled: Bool {
        get { well.isEnabled }
        set {
            well.isEnabled = newValue
            hexField.isEnabled = newValue
        }
    }

    @objc private func wellChanged() {
        display(Self.hex(well.color))
        onChange?(well.color)
    }

    @objc private func hexCommitted() {
        let typedText = hexField.stringValue.trimmingCharacters(in: .whitespaces)
        // Untouched. Tabbing past a field is not an edit, and this is the case
        // that keeps a named colour a name: `cyan` doesn't parse, and without
        // this test merely passing through the row would rewrite the config's
        // own word as the `#000000` the well falls back to.
        guard typedText != shownText else { return }

        guard let typed = Self.color(from: typedText) else {
            // Not a colour. Put back what was there rather than leaving
            // half-typed text sitting where a setting should be.
            hexField.stringValue = shownText
            return
        }
        // The same colour said differently — `#ABC` over `#aabbcc`. Worth
        // normalising on screen, not worth telling anyone about.
        guard Self.hex(typed) != Self.hex(well.color) else {
            display(Self.hex(typed))
            return
        }
        color = typed
        onChange?(typed)
    }

    // MARK: - Values

    /// Ghostty writes colours as `#rrggbb`, and also accepts them bare and by
    /// name. Only hex round-trips through a colour well, so a named colour is
    /// left alone until someone actually picks a new one.
    ///
    /// Three-digit shorthand is accepted on the way in — it is what people have
    /// in their heads for the greys — and normalised to six on the way out.
    static func color(from value: String) -> NSColor? {
        var hex = value.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x",
                      Int(srgb.redComponent * 255 + 0.5),
                      Int(srgb.greenComponent * 255 + 0.5),
                      Int(srgb.blueComponent * 255 + 0.5))
    }
}

extension ColorField: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        hexCommitted()
    }
}
