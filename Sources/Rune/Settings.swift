import Cocoa

/// Everything the settings window can change, and the one place that reads it.
///
/// Values are stored as *overrides*: a key that has never been set is absent
/// rather than holding a copy of the default, so "reset" is a delete and the
/// defaults stay free to move between releases. A colour someone never touched
/// tracks whatever Rune ships next; one they chose stays chosen.
@MainActor
final class Settings {
    static let shared = Settings()

    /// Posted after any change, with a `Kind` as its object. Chrome that is
    /// long-lived — the tab strip, the menu bar — listens; the ⌘K panel is
    /// built fresh on every open and just reads the current value.
    ///
    /// The kind matters because the menu bar is rebuilt wholesale to pick up a
    /// rebound key, and dragging the dim slider posts on every tick — without
    /// it, nudging a colour would rebuild the menu bar sixty times.
    static let changed = Notification.Name("RuneSettingsChanged")

    enum Kind { case appearance, shortcuts }

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Appearance

    /// The colour Rune uses to mark the active thing: the bar over the current
    /// tab, the update pill, the switcher's focus ring.
    ///
    /// Nil means follow the system accent, which is the default and the right
    /// default — most people set that once in System Settings and expect apps
    /// to honour it.
    var accent: NSColor? {
        get { color(forKey: Keys.accent) }
        set { setColor(newValue, forKey: Keys.accent) }
    }

    /// Resolved for drawing. Callers want a colour, not a decision.
    var effectiveAccent: NSColor { accent ?? .controlAccentColor }

    /// The ⌘K panel's own background.
    ///
    /// Near-black by default and deliberately not semantic: Rune sets the
    /// window's appearance from the terminal's background, so a light
    /// colourscheme flips `labelColor` to black and the panel would go
    /// black-on-black. See `PaletteStyle`.
    var panelBackground: NSColor {
        get { color(forKey: Keys.panelBackground) ?? Defaults.panelBackground }
        set { setColor(newValue, forKey: Keys.panelBackground) }
    }

    /// How much of the terminal the switcher's backdrop carries away, 0…1.
    var backdropDim: CGFloat {
        get {
            guard defaults.object(forKey: Keys.backdropDim) != nil else { return Defaults.backdropDim }
            return min(max(CGFloat(defaults.double(forKey: Keys.backdropDim)), 0), 1)
        }
        set {
            defaults.set(Double(min(max(newValue, 0), 1)), forKey: Keys.backdropDim)
            notify(.appearance)
        }
    }

    /// What sits behind a ⌘K row's mark when the mark doesn't paint its own
    /// background.
    ///
    /// Light by default, because these are brand marks and brand marks are
    /// drawn to sit on paper — Claude's is a mid-salmon glyph with holes cut
    /// out of it, and on a near-black tile the holes fill in with the panel and
    /// the whole thing reads as a smudge. It is also the only way the row is
    /// consistent: an icon that ships its own white card, like Codex's, is
    /// already a white square, and a bare glyph beside it on black looks like a
    /// different kind of thing rather than the same kind drawn differently.
    var lightIconTiles: Bool {
        get {
            guard defaults.object(forKey: Keys.lightIconTiles) != nil
            else { return Defaults.lightIconTiles }
            return defaults.bool(forKey: Keys.lightIconTiles)
        }
        set {
            defaults.set(newValue, forKey: Keys.lightIconTiles)
            notify(.appearance)
        }
    }

    /// Whether `⌘J` opens a todo list in the switcher's panel.
    ///
    /// Off by default, and the only feature in Rune that is. A terminal that
    /// grew a task manager nobody asked for would be a worse terminal; this is
    /// here for people who want one and invisible to everyone else, down to the
    /// key doing nothing until it is switched on.
    var todosEnabled: Bool {
        get { defaults.bool(forKey: Keys.todosEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.todosEnabled)
            notify(.appearance)
        }
    }

    /// Which palette the diff is drawn in. See `DiffTheme`.
    var diffTheme: String {
        get { defaults.string(forKey: Keys.diffTheme) ?? Defaults.diffTheme }
        set {
            defaults.set(newValue, forKey: Keys.diffTheme)
            notify(.appearance)
        }
    }

    /// The diff's font, or empty to follow the terminal's.
    ///
    /// Following Ghostty is the default because the diff sits beside the
    /// terminal and the two showing the same code in different faces reads as
    /// two applications rather than one.
    var diffFontName: String {
        get { defaults.string(forKey: Keys.diffFontName) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.diffFontName)
            notify(.appearance)
        }
    }

    /// Points, or zero to follow the terminal's size.
    var diffFontSize: Double {
        get { defaults.double(forKey: Keys.diffFontSize) }
        set {
            defaults.set(newValue, forKey: Keys.diffFontSize)
            notify(.appearance)
        }
    }

    /// Steps of ⌘+/⌘− applied on top of whatever size the font resolves to.
    ///
    /// The terminal and the diff zoom together — they are the same document
    /// read two ways, and one of them changing size on its own is the kind of
    /// mismatch you notice every time your eye crosses the seam. Persisted, so
    /// a size you settled on survives the next launch.
    var diffFontZoom: Double {
        get { defaults.double(forKey: Keys.diffFontZoom) }
        set {
            defaults.set(max(-6, min(24, newValue)), forKey: Keys.diffFontZoom)
            notify(.appearance)
        }
    }

    enum Defaults {
        static let diffTheme = "zed"
        static let panelBackground = NSColor(white: 0.055, alpha: 1)
        static let backdropDim: CGFloat = 0.6
        static let lightIconTiles = true
    }

    func resetAppearance() {
        for key in [
            Keys.accent, Keys.panelBackground, Keys.backdropDim, Keys.lightIconTiles,
            Keys.diffTheme, Keys.diffFontName, Keys.diffFontSize, Keys.diffFontZoom,
        ] {
            defaults.removeObject(forKey: key)
        }
        notify(.appearance)
    }

    // MARK: - Shortcuts

    /// The chord bound to an action — the override if there is one, the
    /// shipped default otherwise.
    func chord(for action: ShortcutAction) -> KeyChord {
        overrides[action] ?? action.default
    }

    func setChord(_ chord: KeyChord?, for action: ShortcutAction) {
        var next = overrides
        next[action] = chord
        overrides = next
    }

    /// The action already using a chord, if any. Two menu items with the same
    /// key equivalent is not an error AppKit reports — it just silently picks
    /// one — so the settings window has to say so itself.
    func conflict(with chord: KeyChord, ignoring action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.chord(for: $0) == chord }
    }

    func resetShortcuts() {
        defaults.removeObject(forKey: Keys.shortcuts)
        cachedOverrides = nil
        notify(.shortcuts)
    }

    /// Decoded once and kept, because the menu bar asks for every action's
    /// chord each time it is rebuilt.
    private var cachedOverrides: [ShortcutAction: KeyChord]?

    private var overrides: [ShortcutAction: KeyChord] {
        get {
            if let cachedOverrides { return cachedOverrides }
            let decoded: [ShortcutAction: KeyChord]
            if let data = defaults.data(forKey: Keys.shortcuts),
               let stored = try? JSONDecoder().decode([String: KeyChord].self, from: data) {
                decoded = stored.reduce(into: [:]) { result, pair in
                    guard let action = ShortcutAction(rawValue: pair.key) else { return }
                    result[action] = pair.value
                }
            } else {
                decoded = [:]
            }
            cachedOverrides = decoded
            return decoded
        }
        set {
            cachedOverrides = newValue
            let encodable = newValue.reduce(into: [String: KeyChord]()) { $0[$1.key.rawValue] = $1.value }
            defaults.set(try? JSONEncoder().encode(encodable), forKey: Keys.shortcuts)
            notify(.shortcuts)
        }
    }

    // MARK: - Storage

    private enum Keys {
        static let accent = "RuneAccentColor"
        static let panelBackground = "RunePanelBackground"
        static let backdropDim = "RuneBackdropDim"
        static let lightIconTiles = "RuneLightIconTiles"
        static let todosEnabled = "RuneTodosEnabled"
        static let diffTheme = "RuneDiffTheme"
        static let diffFontName = "RuneDiffFontName"
        static let diffFontSize = "RuneDiffFontSize"
        static let diffFontZoom = "RuneDiffFontZoom"
        static let shortcuts = "RuneShortcuts"
    }

    /// sRGB components rather than an archived `NSColor`. A colour picked from
    /// the wheel can land in any colour space, and one archived in a space that
    /// later fails to resolve reads back as nil — a setting that silently
    /// forgets itself. Four numbers cannot.
    private func color(forKey key: String) -> NSColor? {
        guard let parts = defaults.array(forKey: key) as? [Double], parts.count == 4 else { return nil }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }

    private func setColor(_ color: NSColor?, forKey key: String) {
        guard let color, let srgb = color.usingColorSpace(.sRGB) else {
            defaults.removeObject(forKey: key)
            notify(.appearance)
            return
        }
        defaults.set(
            [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent],
            forKey: key)
        notify(.appearance)
    }

    private func notify(_ kind: Kind) {
        NotificationCenter.default.post(name: Self.changed, object: kind)
    }
}
