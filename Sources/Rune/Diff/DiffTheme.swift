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

    var title: String {
        switch self {
        case .rune: "Rune"
        case .terminal: "Terminal"
        case .paper: "Paper"
        case .plain: "No highlighting"
        }
    }

    /// Whether the code gets syntax colours at all.
    var highlightsSyntax: Bool {
        switch self {
        case .rune, .paper: true
        case .terminal, .plain: false
        }
    }

    @MainActor var addedBackground: NSColor {
        switch self {
        case .rune: NSColor.systemGreen.withAlphaComponent(0.14)
        case .terminal: NSColor.systemGreen.withAlphaComponent(0.24)
        case .paper: NSColor.systemGreen.withAlphaComponent(0.18)
        case .plain: NSColor.systemGreen.withAlphaComponent(0.16)
        }
    }

    @MainActor var removedBackground: NSColor {
        switch self {
        case .rune: NSColor.systemRed.withAlphaComponent(0.14)
        case .terminal: NSColor.systemRed.withAlphaComponent(0.24)
        case .paper: NSColor.systemRed.withAlphaComponent(0.18)
        case .plain: NSColor.systemRed.withAlphaComponent(0.16)
        }
    }

    /// The colour of code that has not been touched.
    @MainActor var contextText: NSColor {
        switch self {
        case .terminal: NSColor.secondaryLabelColor
        default: NSColor.secondaryLabelColor
        }
    }

    /// Added and removed text. `terminal` tints the text itself, since that is
    /// the whole idea of it.
    @MainActor func changedText(added: Bool) -> NSColor {
        switch self {
        case .terminal: added ? NSColor.systemGreen : NSColor.systemRed
        default: NSColor.labelColor
        }
    }

    @MainActor var syntax: (keyword: NSColor, string: NSColor, comment: NSColor,
                            number: NSColor, type: NSColor) {
        switch self {
        case .paper:
            (.systemPurple, .systemRed, .tertiaryLabelColor, .systemBlue, .systemIndigo)
        default:
            (.systemPink, .systemOrange, .tertiaryLabelColor, .systemTeal, .systemPurple)
        }
    }

    @MainActor static var current: DiffTheme {
        DiffTheme(rawValue: Settings.shared.diffTheme) ?? .rune
    }
}
