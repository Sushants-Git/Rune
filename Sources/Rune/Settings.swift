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

    /// Whether Rune's own surfaces are drawn light or dark.
    ///
    /// Three answers, and the default is the interesting one: the ⌘K panel sits
    /// *on* the terminal, so the thing it has to stay legible against is the
    /// terminal's own background — not the system's idea of the hour. A Mac in
    /// light mode running a dark terminal wants a dark panel, and `.system`
    /// would get that exactly backwards.
    enum Appearance: String, CaseIterable {
        /// Follow the terminal's background.
        case automatic
        case light
        case dark

        var title: String {
            switch self {
            case .automatic: "Match the terminal"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .automatic }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.appearance)
            notify(.appearance)
        }
    }

    /// The panel colour only when it was chosen by hand.
    ///
    /// The default is a near-black, which is the wrong default over a light
    /// terminal — but a colour the user actually picked is a colour they want,
    /// whatever the terminal is doing. Telling the two apart is the difference
    /// between following the theme and overriding a preference.
    var panelBackgroundOverride: NSColor? { color(forKey: Keys.panelBackground) }

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
    /// On by default, and switchable off — the other way round from where it
    /// started. It shares the switcher's panel and costs nothing when unused,
    /// and a key that did nothing until you found a setting was a feature most
    /// people never discovered they had.
    var todosEnabled: Bool {
        // On unless turned off. `defaults.bool` reads a missing key as false,
        // which is the wrong default for a list that is one keystroke away and
        // costs nothing when unused.
        get { defaults.object(forKey: Keys.todosEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.todosEnabled)
            notify(.appearance)
        }
    }

    enum Defaults {
        static let panelBackground = NSColor(white: 0.055, alpha: 1)
        static let backdropDim: CGFloat = 0.6
        static let lightIconTiles = true
    }

    func resetAppearance() {
        for key in [
            Keys.accent, Keys.panelBackground, Keys.backdropDim, Keys.lightIconTiles,
            Keys.appearance,
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
        static let appearance = "RuneAppearance"
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

    /// Re-read what is on disk and tell everything to repaint.
    ///
    /// Nothing is cached here — every property reads `UserDefaults` on demand —
    /// so this is a synchronise plus an announcement rather than a reload. That
    /// is enough: the announcement is the part anything already on screen was
    /// missing.
    func reload() {
        defaults.synchronize()
        notify(.appearance)
        notify(.shortcuts)
    }

    private func notify(_ kind: Kind) {
        NotificationCenter.default.post(name: Self.changed, object: kind)
    }
}
