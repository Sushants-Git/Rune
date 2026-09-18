import Cocoa

/// The find bar, floating at the top-right of a pane.
///
/// Rune does no searching. libghostty owns the scrollback and searches it on
/// its own thread; this is the box you type into and the count you read back.
/// Everything it knows arrives asynchronously, which is why the count has a
/// "searching…" state rather than sitting at zero until an answer turns up.
@MainActor
final class SearchBar: NSView {
    var onSearch: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()

    static let height: CGFloat = 32
    private static let margin: CGFloat = 10

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        // A find field keeps what you last looked for, and a fresh ⌘F selects
        // it so typing replaces it — the behaviour every other find bar has.
        field.cell?.usesSingleLineMode = true

        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right

        configure(previous, symbol: "chevron.up", action: #selector(goPrevious))
        configure(next, symbol: "chevron.down", action: #selector(goNext))
        configure(close, symbol: "xmark", action: #selector(dismiss))

        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        field.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 150),
            // Fixed, not hugging: the bar must not resize by a few pixels every
            // time the count ticks from 9 to 10 while you type.
            count.widthAnchor.constraint(equalToConstant: 62),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        show(total: nil, selected: nil, searching: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }

    // MARK: - Placement

    /// Pin to the top-right of `pane`, clear of its edges.
    func attach(to pane: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: pane.topAnchor, constant: Self.margin),
            trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Self.margin),
        ])
    }

    /// Painted from the terminal's own background rather than from system
    /// colours, for the same reason the ⌘K panel is: Rune sets the window's
    /// appearance from the theme, so `labelColor` flips to black under a light
    /// colourscheme and a system-coloured bar would go invisible.
    func tint(background: NSColor) {
        let dark = background.isDark
        let raised = background.blended(
            withFraction: dark ? 0.14 : 0.10, of: dark ? .white : .black) ?? background
        layer?.backgroundColor = raised.cgColor
        layer?.borderColor = (dark ? NSColor.white : .black)
            .withAlphaComponent(0.14).cgColor

        let text = dark ? NSColor.white : .black
        field.textColor = text
        for button in [previous, next, close] {
            button.contentTintColor = text.withAlphaComponent(0.75)
        }
        count.textColor = text.withAlphaComponent(0.5)
        applyCountColor()
    }

    // MARK: - State

    private var hasMatches = true

    /// `total` nil while the core is still counting; `selected` is 0-based, so
    /// it is the one number here that gets adjusted before anyone reads it.
    func show(total: Int?, selected: Int?, searching: Bool) {
        guard searching, !field.stringValue.isEmpty else {
            count.stringValue = ""
            hasMatches = true
            applyCountColor()
            previous.isEnabled = false
            next.isEnabled = false
            return
        }

        guard let total else {
            count.stringValue = "…"
            hasMatches = true
            applyCountColor()
            return
        }

        hasMatches = total > 0
        if total == 0 {
            count.stringValue = "none"
        } else if let selected {
            // libghostty counts matches from zero. Nobody reads "0 of 200".
            count.stringValue = "\(selected + 1)/\(total)"
        } else {
            // Matches found, none picked yet. Showing "1/200" here would be a
            // lie about where you are — the core selects nothing until asked.
            count.stringValue = "\(total)"
        }
        applyCountColor()
        previous.isEnabled = total > 0
        next.isEnabled = total > 0
    }

    private func applyCountColor() {
        let base = field.textColor ?? .white
        count.textColor = hasMatches ? base.withAlphaComponent(0.5) : .systemRed
    }

    var needle: String { field.stringValue }

    func setNeedle(_ needle: String) {
        field.stringValue = needle
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - Actions

    /// Return steps forward, Shift-Return back — the way a find bar does.
    ///
    /// The modifier has to come off the current event: `insertNewline:` is sent
    /// for both, and `insertBacktab:` is Shift-Tab, not Shift-Return.
    @objc private func submit() {
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onNavigate?(!backwards)
    }

    @objc private func goNext() { onNavigate?(true) }
    @objc private func goPrevious() { onNavigate?(false) }
    @objc private func dismiss() { onClose?() }
}

extension SearchBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearch?(field.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            onNavigate?(false)
            return true
        default:
            return false
        }
    }
}
