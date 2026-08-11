import Cocoa

/// One line of a settings pane: what it is on the left, what changes it on the
/// right.
///
/// This replaces a right-aligned label column. A trailing column lines the
/// labels up against the controls, which sounds tidy and reads badly — short
/// labels get pushed into the middle of the window and the left margin becomes
/// a band of nothing. Reading starts at the left edge, so the label starts
/// there too, and the control goes to the far side where every row's control
/// can share an edge without dragging the text around with it.
@MainActor
final class SettingsRow: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(wrappingLabelWithString: "")

    /// Sits after the control — the Ghostty pane's revert button.
    private let accessory: NSView?

    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9

    init(title: String, caption: String?, control: NSView, accessory: NSView? = nil) {
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        if let caption, !caption.isEmpty {
            captionLabel.stringValue = caption
            captionLabel.font = .systemFont(ofSize: 11)
            captionLabel.textColor = .secondaryLabelColor
            // Wrapping under the label rather than beside it: a caption is a
            // second line about the same thing, not a second column.
            captionLabel.preferredMaxLayoutWidth = 300
            captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(captionLabel)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            text.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.horizontalPadding),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),

            control.leadingAnchor.constraint(
                greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor, constant: Self.verticalPadding - 2),
        ]

        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(accessory)
            constraints += [
                accessory.leadingAnchor.constraint(equalTo: control.trailingAnchor, constant: 8),
                accessory.centerYAnchor.constraint(equalTo: control.centerYAnchor),
                accessory.widthAnchor.constraint(equalToConstant: 16),
                accessory.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            ]
        } else {
            constraints.append(control.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.horizontalPadding))
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A group of rows in a rounded card, the way macOS settings have grouped them
/// since Ventura.
///
/// The card is what makes a long pane readable: it draws a boundary round
/// things that belong together, so the eye can skip a whole group instead of
/// reading twenty rows to find where one section stops.
@MainActor
final class SettingsCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            // A hairline between rows, run the full width of the card. Inset to
            // the text it stopped short of both edges, which left every rule
            // looking like it had failed to finish rather than like a deliberate
            // indent — the card's own rounded corners already say where the
            // group stops, so the separator has nothing to prove.
            guard index < rows.count - 1 else { continue }
            let divider = NSView()
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
            dividers.append(divider)
            stack.addArrangedSubview(divider)
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        applyColors()
    }

    private var dividers: [NSView] = []

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Semantic colours, resolved on each appearance change. This window follows
    // the system appearance rather than the terminal's, so unlike the ⌘K panel
    // it can use them — but a CGColor is a resolved value, not a dynamic one,
    // so it has to be recomputed rather than set once.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            // Lighter still than the quiet edge this started as. On a dark pane
            // a grey outline round a dark fill is the brightest thing in the
            // group, so the card reads as a raised plate — which is backwards,
            // because the fill is already doing the work of saying where the
            // group is. The border is only here to keep that fill from bleeding
            // into a background of nearly its own colour.
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
            for divider in dividers {
                divider.layer?.backgroundColor = NSColor.separatorColor
                    .withAlphaComponent(0.22).cgColor
            }
        }
    }
}

/// A view that takes focus away from whatever has it when you click the space
/// around the controls.
///
/// The other half of not focusing a text field on arrival: once you *have*
/// clicked into one there is otherwise no way out of it but Tab, because a
/// settings pane is all inert background and none of it wants first responder.
/// Clicking off a field is how every other window on the Mac ends an edit.
@MainActor
final class FocusReleasingView: NSView {
    override func mouseDown(with event: NSEvent) {
        // Reaches here only when nothing nearer the click wanted it: AppKit
        // walks up from the deepest view, and rows, cards and labels all
        // decline. A click on a control never gets this far.
        window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
}

/// A document view that lays out from the top down.
///
/// `NSView`'s origin is bottom-left, and a scroll view over an unflipped
/// document opens showing the *bottom* of it — so a settings pane started 85
/// points below its first heading, with the top of the list hidden under the
/// header. Flipping the document is the whole fix: top-left origin, and the
/// scroll view opens where the content starts.
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
