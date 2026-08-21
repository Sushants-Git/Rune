import Cocoa

/// A few lines of terminal, drawn the way your config says they will look.
///
/// The Ghostty pane is a list of key-value rows, and a colour or a font size is
/// the kind of setting nobody can evaluate as a number. Reading `background =
/// #1a1b26` tells you nothing about whether you want it; four lines of prompt
/// in it tells you immediately.
///
/// Everything here comes from the live config after a reload, so it is not a
/// mock-up of the settings — it is the same values the terminal itself is about
/// to use.
@MainActor
final class GhosttyPreview: NSView {
    private let canvas = NSTextView()
    private let scale: CGFloat = 0.9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        canvas.isEditable = false
        canvas.isSelectable = false
        canvas.drawsBackground = false
        canvas.textContainerInset = NSSize(width: 12, height: 10)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 118),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Redraw from whatever the config currently says.
    func refresh() {
        let ghostty = NSApp.ghosttyApp
        let background = ghostty?.backgroundColor ?? .black
        let foreground = ghostty?.color("foreground") ?? (background.isLight ? .black : .white)
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        // Scaled down a little: the point is the colours and the shape of the
        // face, and a preview set at 18pt would be a preview of two words.
        let size = max(9, (ghostty?.fontSize ?? 13) * scale)
        let family = ghostty?.fontFamily ?? ""
        let font = (family.isEmpty ? nil : NSFont(name: family, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)

        let green = ghostty?.color("palette:2") ?? .systemGreen
        let blue = ghostty?.color("palette:4") ?? .systemBlue
        let yellow = ghostty?.color("palette:3") ?? .systemYellow
        let dim = foreground.withAlphaComponent(0.55)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byClipping

        let text = NSMutableAttributedString()
        func line(_ parts: [(String, NSColor)]) {
            for (body, colour) in parts {
                text.append(NSAttributedString(string: body, attributes: [
                    .font: font, .foregroundColor: colour, .paragraphStyle: paragraph,
                ]))
            }
            text.append(NSAttributedString(string: "\n", attributes: [
                .font: font, .paragraphStyle: paragraph,
            ]))
        }

        line([("~/code/rune ", blue), ("main", yellow)])
        line([("❯ ", green), ("swift build", foreground)])
        line([("  Compiling rune v0.1.0", dim)])
        line([("   Finished ", dim), ("release", green), (" in 4.21s", dim)])

        canvas.textStorage?.setAttributedString(text)
        // No smart substitution: this is a picture of terminal output, and a
        // text view that helpfully turns two hyphens into a dash would be
        // showing something the terminal never would.
        canvas.isAutomaticTextReplacementEnabled = false
        canvas.isAutomaticDashSubstitutionEnabled = false
        canvas.isAutomaticQuoteSubstitutionEnabled = false
    }
}
