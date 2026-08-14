import Cocoa

/// The colours a diff is drawn in.
///
/// Separated from the view because they are the part with taste in them. The
/// defaults are tuned for a dark panel, and the alternatives exist because
/// "which green" is not a question with one answer — some people read a diff
/// by the bands, some by the text, and one palette cannot serve both.
enum DiffTheme: String, CaseIterable {
    /// Quiet bands, coloured syntax. What Rune ships with.
    case rune
    /// Stronger bands and plain text, the way `git diff` in a terminal reads:
    /// the line's colour *is* the information.
    case terminal
    /// Pale washes and dark text, close to a review page in a browser.
    case paper
    /// No colour on the code at all, only the bands. For anyone who finds
    /// highlighting in a diff more noise than signal.
    case plain
    /// An editor's palette rather than a Mac window's: One Dark, the colours
    /// Zed and half the editors on the machine already use. The default,
    /// because a diff sitting beside a terminal is a coding surface and reads
    /// better in a coding surface's colours than in the system's.
    case zed

    var title: String {
        switch self {
        case .rune: "Rune"
        case .terminal: "Terminal"
        case .paper: "Paper"
        case .plain: "No highlighting"
        case .zed: "Editor"
        }
    }

    /// Whether the code gets syntax colours at all.
    var highlightsSyntax: Bool {
        switch self {
        case .rune, .paper, .zed: true
        case .terminal, .plain: false
        }
    }

    @MainActor var addedBackground: NSColor {
        switch self {
        case .rune: NSColor.systemGreen.withAlphaComponent(0.14)
        case .terminal: NSColor.systemGreen.withAlphaComponent(0.24)
        case .paper: NSColor.systemGreen.withAlphaComponent(0.18)
        case .plain: NSColor.systemGreen.withAlphaComponent(0.16)
        case .zed: NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 0.16)
        }
    }

    @MainActor var removedBackground: NSColor {
        switch self {
        case .rune: NSColor.systemRed.withAlphaComponent(0.14)
        case .terminal: NSColor.systemRed.withAlphaComponent(0.24)
        case .paper: NSColor.systemRed.withAlphaComponent(0.18)
        case .plain: NSColor.systemRed.withAlphaComponent(0.16)
        case .zed: NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 0.16)
        }
    }

    /// A staged line's band: its own colour pulled most of the way towards
    /// blue.
    ///
    /// Not blue outright, and not green-or-red outright. Outright blue loses
    /// which side the line is on at a glance; leaving it green says nothing
    /// about whether it is in the index. Pulled three quarters of the way, an
    /// added line still reads warmer than a removed one and both read as
    /// obviously not the colour of the unstaged lines around them.
    @MainActor func stagedBackground(added: Bool) -> NSColor {
        let base = added ? NSColor.systemGreen : NSColor.systemRed
        let alpha = (added ? addedBackground : removedBackground).alphaComponent
        return Self.mix(base, into: .systemBlue, by: 0.75).withAlphaComponent(alpha + 0.04)
    }

    /// The nib at the panel's edge on a staged line.
    @MainActor var stagedStripe: NSColor { .systemBlue }

    /// Blended through sRGB by hand. The system colours are dynamic catalogue
    /// entries, and `blended(withFraction:of:)` returns nil whenever two of
    /// those cannot be brought into a common space — which is exactly the case
    /// here, and a nil there would silently drop the distinction.
    @MainActor private static func mix(
        _ colour: NSColor, into other: NSColor, by fraction: CGFloat
    ) -> NSColor {
        guard let a = colour.usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return other
        }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
            alpha: 1)
    }

    /// The colour of code that has not been touched.
    @MainActor var contextText: NSColor {
        switch self {
        case .zed: NSColor(srgbRed: 0.671, green: 0.698, blue: 0.749, alpha: 1)
        default: NSColor.secondaryLabelColor
        }
    }

    /// Added and removed text. `terminal` tints the text itself, since that is
    /// the whole idea of it.
    @MainActor func changedText(added: Bool) -> NSColor {
        switch self {
        case .terminal: added ? NSColor.systemGreen : NSColor.systemRed
        case .zed: NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1)
        default: NSColor.labelColor
        }
    }

    @MainActor var syntax: (keyword: NSColor, string: NSColor, comment: NSColor,
                            number: NSColor, type: NSColor) {
        switch self {
        case .paper:
            (.systemPurple, .systemRed, .tertiaryLabelColor, .systemBlue, .systemIndigo)
        case .zed:
            (NSColor(srgbRed: 0.776, green: 0.471, blue: 0.867, alpha: 1),   // keyword
             NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1),   // string
             NSColor(srgbRed: 0.361, green: 0.388, blue: 0.439, alpha: 1),   // comment
             NSColor(srgbRed: 0.820, green: 0.604, blue: 0.400, alpha: 1),   // number
             NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 1))   // type
        default:
            (.systemPink, .systemOrange, .tertiaryLabelColor, .systemTeal, .systemPurple)
        }
    }

    @MainActor static var current: DiffTheme {
        DiffTheme(rawValue: Settings.shared.diffTheme) ?? .rune
    }
}
