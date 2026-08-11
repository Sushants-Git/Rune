import Cocoa

/// The icons on the settings tabs.
///
/// From [Lucide](https://lucide.dev) (ISC), carried as their SVG source rather
/// than as rasterised assets: they are a few hundred bytes each, they stay
/// legible at any size the tab bar asks for, and keeping the source here means
/// the thing in the repository is the thing Lucide published — no export step
/// in between to go stale or to lose a path.
///
/// Ghostty gets Lucide's ghost rather than Ghostty's own app icon. The icon is
/// a project's identity in a way its MIT-licensed source is not, and Rune is a
/// separate application that merely embeds libghostty — borrowing the mark to
/// label a tab claims more of a relationship than there is.
///
/// Drawn as templates, so AppKit tints them to whatever the tab bar's label
/// colour is and they follow light and dark without a second copy.
@MainActor
enum SettingsIcon {
    case appearance, shortcuts, ghostty

    /// Nil if the platform can't decode the SVG, which is the caller's cue to
    /// fall back. macOS gained `NSImage` SVG decoding partway through the range
    /// of versions Rune supports, and a tab with no icon is a much smaller
    /// problem than one that fails to build a control.
    var image: NSImage? {
        guard let image = NSImage(data: Data(source.utf8)) ?? NSImage(
            systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 15, height: 15)
        return image
    }

    private var fallbackSymbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .shortcuts: "keyboard"
        case .ghostty: "terminal"
        }
    }

    /// Lucide's own path data, verbatim. `currentColor` is the one edit: it
    /// means nothing outside a stylesheet, and a template image needs opaque
    /// ink to tint rather than the nothing an unresolved colour paints.
    private var source: String {
        switch self {
        case .appearance: Self.svg("""
            <path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"/>
            <circle cx="13.5" cy="6.5" r=".5" fill="#000"/>
            <circle cx="17.5" cy="10.5" r=".5" fill="#000"/>
            <circle cx="6.5" cy="12.5" r=".5" fill="#000"/>
            <circle cx="8.5" cy="7.5" r=".5" fill="#000"/>
            """)
        case .shortcuts: Self.svg("""
            <path d="M10 8h.01"/><path d="M12 12h.01"/><path d="M14 8h.01"/>
            <path d="M16 12h.01"/><path d="M18 8h.01"/><path d="M6 8h.01"/>
            <path d="M7 16h10"/><path d="M8 12h.01"/>
            <rect width="20" height="16" x="2" y="4" rx="2"/>
            """)
        case .ghostty: Self.svg("""
            <path d="M9 10h.01"/><path d="M15 10h.01"/>
            <path d="M12 2a8 8 0 0 0-8 8v12l3-3 2.5 2.5L12 19l2.5 2.5L17 19l3 3V10a8 8 0 0 0-8-8z"/>
            """)
        }
    }

    private static func svg(_ body: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
        viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" \
        stroke-linecap="round" stroke-linejoin="round">\(body)</svg>
        """
    }
}
