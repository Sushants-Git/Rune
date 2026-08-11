import Cocoa

/// The controls for one Ghostty setting: a label, something to change it with,
/// and a way back to the default.
///
/// Not a view. The three pieces are handed to an `NSGridView` separately so
/// that every label lines up in one column and every control in the next —
/// which is the whole difference between a settings pane and a pile of widgets.
///
/// A control shows what the config *file* says. When the file says nothing it
/// shows Ghostty's default as placeholder text with an unlit revert button,
/// because a pane that renders "unset" and "set to the same value" identically
/// cannot tell you what your config contains.
@MainActor
final class GhosttyOptionControl: NSObject {
    let option: GhosttyOption
    /// nil means "take this key out of the file".
    var onChange: ((String?) -> Void)?

    private(set) var control: NSView!
    let revert = NSButton()
    /// The row this option occupies. Built here so the control, its caption and
    /// its revert button stay one thing.
    private(set) var row: SettingsRow!

    /// Set while `show` is writing into the controls, so the actions they fire
    /// in response are not mistaken for the user having typed something.
    private var loading = false

    init(option: GhosttyOption) {
        self.option = option
        super.init()

        control = makeControl()

        // A glyph rather than a word: it repeats down the whole pane, and
        // twenty buttons saying "Default" would be the loudest thing on screen
        // instead of the quietest.
        revert.image = NSImage(
            systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reset")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        revert.isBordered = false
        revert.bezelStyle = .inline
        revert.contentTintColor = .secondaryLabelColor
        revert.target = self
        revert.action = #selector(revertToDefault)
        revert.toolTip = "Remove this from the config file and use Ghostty's default"
        revert.setContentHuggingPriority(.required, for: .horizontal)

        row = SettingsRow(
            title: option.title, caption: option.note, control: control, accessory: revert)
    }

    // MARK: - Controls

    private let text = NSTextField()
    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let popUp = NSPopUpButton()
    private let colorField = ColorField()
    private let slider = NSSlider()
    private let sliderValue = NSTextField(labelWithString: "")

    private func makeControl() -> NSView {
        switch option.kind {
        case .text(let placeholder):
            text.placeholderString = placeholder
            return configuredText(width: 200)

        case .number:
            text.placeholderString = option.default
            return configuredText(width: 84)

        case .toggle:
            toggle.target = self
            toggle.action = #selector(changed)
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            return toggle

        case .choice(let values):
            popUp.removeAllItems()
            // An empty option means "let Ghostty decide", which needs a word
            // rather than a blank line in the menu.
            popUp.addItems(withTitles: values.map { $0.isEmpty ? "Default" : $0 })
            popUp.target = self
            popUp.action = #selector(changed)
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 12)
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return popUp

        case .color:
            colorField.onChange = { [weak self] color in
                guard let self, !self.loading else { return }
                self.onChange?(ColorField.hex(color))
            }
            return colorField

        case .slider(let min, let max):
            slider.minValue = min
            slider.maxValue = max
            slider.controlSize = .small
            slider.target = self
            slider.action = #selector(changed)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 140).isActive = true

            sliderValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            sliderValue.textColor = .secondaryLabelColor
            sliderValue.alignment = .right
            sliderValue.translatesAutoresizingMaskIntoConstraints = false
            // Fixed, so the row does not twitch as the number changes width.
            sliderValue.widthAnchor.constraint(equalToConstant: 34).isActive = true

            let stack = NSStackView(views: [slider, sliderValue])
            stack.spacing = 8
            stack.alignment = .centerY
            return stack
        }
    }

    private func configuredText(width: CGFloat) -> NSView {
        text.font = .systemFont(ofSize: 12)
        text.controlSize = .small
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

        let isSet = value != nil
        revert.isEnabled = isSet
        // Hidden, not dimmed. Twenty ghost buttons down the right-hand side
        // read as a column of damage; a revert that appears only where there is
        // something to revert also shows at a glance what the file sets.
        revert.isHidden = !isSet
        // A key the file sets is the interesting one on the page; the rest are
        // Ghostty's defaults sitting quietly.
        row.titleLabel.textColor = isSet ? .labelColor : .secondaryLabelColor

        let effective = value ?? option.default
        switch option.kind {
        case .text, .number:
            text.stringValue = value ?? ""
            if option.default.isEmpty {
                if case .text(let placeholder) = option.kind { text.placeholderString = placeholder }
            } else {
                text.placeholderString = option.default
            }

        case .toggle:
            toggle.state = Self.isTrue(effective) ? .on : .off

        case .choice(let values):
            popUp.selectItem(at: values.firstIndex(of: effective) ?? 0)

        case .color:
            // The raw string, not a parsed colour: Ghostty takes names as well
            // as hex, and the field says so rather than rounding `red` down to
            // the black the well falls back to.
            colorField.show(effective)
            // An unset colour has no colour to show; dimming says so without
            // inventing one.
            colorField.alphaValue = isSet ? 1 : 0.4

        case .slider:
            let number = Double(effective) ?? slider.minValue
            slider.doubleValue = number
            sliderValue.stringValue = Self.trim(number)
        }
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
            // Handled by the field's own callback, which knows whether the
            // colour came from the well or from someone typing a hex.
            break

        case .slider:
            sliderValue.stringValue = Self.trim(slider.doubleValue)
            onChange?(Self.trim(slider.doubleValue))
        }
    }

    @objc private func revertToDefault() {
        onChange?(nil)
    }

    // MARK: - Values

    /// `1` rather than `1.00`, `0.7` rather than `0.70`. A config file is read
    /// by people, and trailing zeros are noise Ghostty does not need.
    static func trim(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "1", "on"].contains(value.lowercased())
    }

}

extension GhosttyOptionControl: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        changed()
    }
}
