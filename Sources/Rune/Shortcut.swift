import Cocoa

/// A key equivalent, in the form AppKit wants it.
///
/// `key` is a menu key equivalent rather than a keycode — lowercase where a
/// letter, and the glyph AppKit expects for the special keys (`⌫`, `↩`, `←`).
/// Storing it this way means a chord can be handed straight to `NSMenuItem`
/// with nothing in between to get wrong, and it survives a keyboard layout
/// change the way the rest of the menu bar does.
struct KeyChord: Equatable, Codable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        modifiers = NSEvent.ModifierFlags(rawValue: try container.decode(UInt.self, forKey: .modifiers))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }

    // MARK: - Recording

    /// The chord a key press stands for, or nil if it isn't one.
    ///
    /// A bare letter is not a shortcut — it is typing. At least one of the
    /// non-shift modifiers has to be down, because ⇧A in a terminal is a
    /// capital A and binding it would take the letter away from every shell
    /// running inside Rune.
    static func from(_ event: NSEvent) -> KeyChord? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }

        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
        // `charactersIgnoringModifiers` still folds shift for letters on some
        // layouts, and the menu wants the unshifted key with shift stated
        // separately, so lowercase and let `modifiers` carry it.
        let key = Self.functionKeys[raw] ?? raw.lowercased()
        return KeyChord(key, modifiers)
    }

    /// The keys that arrive as private-use codepoints and are written as
    /// glyphs in a menu.
    private static let functionKeys: [String: String] = [
        String(UnicodeScalar(NSLeftArrowFunctionKey)!): "\u{2190}",
        String(UnicodeScalar(NSRightArrowFunctionKey)!): "\u{2192}",
        String(UnicodeScalar(NSUpArrowFunctionKey)!): "\u{2191}",
        String(UnicodeScalar(NSDownArrowFunctionKey)!): "\u{2193}",
        String(UnicodeScalar(NSHomeFunctionKey)!): "\u{2196}",
        String(UnicodeScalar(NSEndFunctionKey)!): "\u{2198}",
        String(UnicodeScalar(NSPageUpFunctionKey)!): "\u{21DE}",
        String(UnicodeScalar(NSPageDownFunctionKey)!): "\u{21DF}",
        String(UnicodeScalar(NSDeleteFunctionKey)!): "\u{2326}",
    ]

    // MARK: - Display

    /// `⇧⌘D`, in the order macOS writes modifiers.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        return text + Self.glyphs[key, default: key.uppercased()]
    }

    private static let glyphs: [String: String] = [
        "\r": "\u{21A9}", "\u{3}": "\u{2324}", "\t": "\u{21E5}", " ": "Space",
        "\u{8}": "\u{232B}", "\u{7f}": "\u{232B}", "\u{1b}": "\u{238B}",
    ]
}

/// Everything in Rune's menus that can be rebound.
///
/// The list is deliberately not "every menu item". Copy, Paste and Quit belong
/// to macOS and moving them would be a bug wearing a feature's clothes, and the
/// ⌘1–9 / ⌥1–9 families are ranges rather than single chords. What is left is
/// the part of the menu bar that is Rune's own idea.
enum ShortcutAction: String, CaseIterable, Codable {
    case newTab, newWorkspace, newWindow, closeTerminal, closeWindow
    case increaseFont, decreaseFont, resetFont, toggleFullScreen
    case splitRight, splitDown
    case focusSplitLeft, focusSplitRight, focusSplitUp, focusSplitDown
    case zoomSplit, equalizeSplits
    case switchWorkspace, renameWorkspace, nextTab, previousTab

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWorkspace: "New Workspace"
        case .newWindow: "New Window"
        case .closeTerminal: "Close Terminal"
        case .closeWindow: "Close Window"
        case .increaseFont: "Increase Font Size"
        case .decreaseFont: "Decrease Font Size"
        case .resetFont: "Reset Font Size"
        case .toggleFullScreen: "Toggle Full Screen"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focusSplitLeft: "Focus Split Left"
        case .focusSplitRight: "Focus Split Right"
        case .focusSplitUp: "Focus Split Up"
        case .focusSplitDown: "Focus Split Down"
        case .zoomSplit: "Zoom Split"
        case .equalizeSplits: "Equalize Splits"
        case .switchWorkspace: "Switch to Workspace…"
        case .renameWorkspace: "Rename Workspace…"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        }
    }

    /// Which menu it appears under — also how the settings list is grouped, so
    /// finding a shortcut to change means looking where you last used it.
    var group: String {
        switch self {
        case .newTab, .newWorkspace, .newWindow, .closeTerminal, .closeWindow: "Shell"
        case .increaseFont, .decreaseFont, .resetFont, .toggleFullScreen: "View"
        case .splitRight, .splitDown, .focusSplitLeft, .focusSplitRight,
             .focusSplitUp, .focusSplitDown, .zoomSplit, .equalizeSplits: "Splits"
        case .switchWorkspace, .renameWorkspace, .nextTab, .previousTab: "Workspaces"
        }
    }

    var `default`: KeyChord {
        switch self {
        case .newTab: KeyChord("t")
        case .newWorkspace: KeyChord("n")
        case .newWindow: KeyChord("n", [.command, .shift])
        case .closeTerminal: KeyChord("w")
        case .closeWindow: KeyChord("w", [.command, .shift])
        case .increaseFont: KeyChord("+")
        case .decreaseFont: KeyChord("-")
        case .resetFont: KeyChord("0")
        case .toggleFullScreen: KeyChord("f", [.command, .control])
        case .splitRight: KeyChord("d")
        case .splitDown: KeyChord("d", [.command, .shift])
        case .focusSplitLeft: KeyChord("\u{2190}", [.command, .option])
        case .focusSplitRight: KeyChord("\u{2192}", [.command, .option])
        case .focusSplitUp: KeyChord("\u{2191}", [.command, .option])
        case .focusSplitDown: KeyChord("\u{2193}", [.command, .option])
        case .zoomSplit: KeyChord("\r", [.command, .shift])
        case .equalizeSplits: KeyChord("=", [.command, .option])
        case .switchWorkspace: KeyChord("k")
        case .renameWorkspace: KeyChord("r")
        case .nextTab: KeyChord("]", [.command, .shift])
        case .previousTab: KeyChord("[", [.command, .shift])
        }
    }

    /// The groups in menu-bar order, each with its actions. `CaseIterable` is
    /// already in that order, so grouping only has to preserve it.
    static var grouped: [(name: String, actions: [ShortcutAction])] {
        var order: [String] = []
        var byGroup: [String: [ShortcutAction]] = [:]
        for action in allCases {
            if byGroup[action.group] == nil { order.append(action.group) }
            byGroup[action.group, default: []].append(action)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }
}
