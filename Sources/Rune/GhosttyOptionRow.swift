import Cocoa

/// One line of the Ghostty pane: a label, a control, and a way back to the
/// default.
///
/// The control shows what the config file says. When the file says nothing it
/// shows Ghostty's default, but *as a default* — greyed placeholder text, an
/// unlit revert button — because a settings window that renders "unset" and
/// "set to the same value" identically is a settings window that cannot tell
/// you what your config actually contains.
@MainActor
final class GhosttyOptionRow: NSStackView {
    let option: GhosttyOption
    /// nil means "take this key out of the file".
    var onChange: ((String?) -> Void)?

    private var control: NSView!
    private let revert = NSButton()
    private let valueLabel = NSTextField(labelWithString: "")

    /// Set while `show` is writing into the controls, so the actions they fire
    /// in response are not mistaken for the user having typed something.
    private var loading = false

    init(option: GhosttyOption) {
        self.option = option
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: option.title)
        label.font = .systemFont(ofSize: 12)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(label)

        control = makeControl()
        addArrangedSubview(control)

        // A glyph rather than a word: it repeats down the whole pane, and
        // twenty buttons saying "Default" would read as the loudest thing on
        // screen instead of the quietest.
        revert.title = "\u{21BA}"
        revert.bezelStyle = .rounded
        revert.font = .systemFont(ofSize: 11)
        revert.target = self
        revert.action = #selector(revertToDefault)
        revert.toolTip = "Remove this from the config file and use Ghostty's default"
        revert.translatesAutoresizingMaskIntoConstraints = false
        revert.widthAnchor.constraint(equalToConstant: 28).isActive = true
        addArrangedSubview(revert)

        return
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Controls

    private let text = NSTextField()
    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let popUp = NSPopUpButton()
    private let well = NSColorWell()
    private let slider = NSSlider()

    private func makeControl() -> NSView {
        switch option.kind {
        case .text(let placeholder):
            text.placeholderString = placeholder
            return configuredText(width: 190)

        case .number:
            text.placeholderString = option.default
            return configuredText(width: 90)

        case .toggle:
            toggle.target = self
            toggle.action = #selector(changed)
            return toggle

        case .choice(let values):
            popUp.removeAllItems()
            // An empty option means "let Ghostty decide", which needs a word
            // rather than a blank line in the menu.
            popUp.addItems(withTitles: values.map { $0.isEmpty ? "Default" : $0 })
            popUp.target = self
            popUp.action = #selector(changed)
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return popUp

        case .color:
            well.target = self
            well.action = #selector(changed)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return well

        case .slider(let min, let max):
            slider.minValue = min
            slider.maxValue = max
            slider.target = self
            slider.action = #selector(changed)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            valueLabel.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [slider, valueLabel])
            stack.spacing = 6
            return stack
        }
    }

    private func configuredText(width: CGFloat) -> NSView {
        text.font = .systemFont(ofSize: 12)
        text.target = self
        text.action = #selector(changed)
        // Commit when focus leaves as well as on Return — nobody presses Return
        // in a settings window before clicking the next field.
        text.delegate = self
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: width).isActive = true
        return text
    }

    // MARK: - Showing

    /// Point the row at what the file currently says. `nil` means the file does
    /// not mention this key.
    func show(_ value: String?) {
        loading = true
        defer { loading = false }

        revert.isEnabled = value != nil
        revert.alphaValue = value != nil ? 1 : 0.25

        let effective = value ?? option.default
        switch option.kind {
        case .text, .number:
            text.stringValue = value ?? ""
            text.placeholderString = option.default.isEmpty
                ? Self.placeholder(for: option) : option.default

        case .toggle:
            toggle.state = Self.isTrue(effective) ? .on : .off

        case .choice(let values):
            let index = values.firstIndex(of: effective) ?? 0
            popUp.selectItem(at: index)

        case .color:
            well.color = Self.color(from: effective) ?? .black
            // An unset colour has no colour to show; dimming the well says so
            // without inventing one.
            well.alphaValue = value == nil ? 0.45 : 1

        case .slider:
            let number = Double(effective) ?? slider.minValue
            slider.doubleValue = number
            valueLabel.stringValue = String(format: "%.2f", number)
        }
    }

    private static func placeholder(for option: GhosttyOption) -> String {
        if case .text(let placeholder) = option.kind { return placeholder }
        return ""
    }

    // MARK: - Editing

    @objc private func changed() {
        guard !loading else { return }

        switch option.kind {
        case .text, .number:
            let typed = text.stringValue.trimmingCharacters(in: .whitespaces)
            // Clearing the field is how you say "I don't want this key" without
            // hunting for the revert button.
            onChange?(typed.isEmpty ? nil : typed)

        case .toggle:
            onChange?(toggle.state == .on ? "true" : "false")

        case .choice(let values):
            let picked = values[popUp.indexOfSelectedItem]
            // The empty choice is the absence of the key, not a key set to "".
            onChange?(picked.isEmpty ? nil : picked)

        case .color:
            onChange?(Self.hex(well.color))

        case .slider:
            valueLabel.stringValue = String(format: "%.2f", slider.doubleValue)
            onChange?(String(format: "%.2f", slider.doubleValue))
        }
    }

    @objc private func revertToDefault() {
        onChange?(nil)
    }

    // MARK: - Values

    static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "1", "on"].contains(value.lowercased())
    }

    /// Ghostty writes colours as `#rrggbb`, and also accepts them bare and by
    /// name. Only hex round-trips through a colour well, so a named colour is
    /// left alone until someone actually picks a new one.
    static func color(from value: String) -> NSColor? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
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

extension GhosttyOptionRow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        changed()
    }
}
