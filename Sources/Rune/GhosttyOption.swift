import Foundation

/// The Ghostty settings the visual editor knows how to show.
///
/// Ghostty has several hundred config keys. This is the subset worth a control:
/// the ones people actually change, in the shape they think about them. The
/// rest of the file stays reachable — the pane has a button that opens it in an
/// editor, and nothing here touches a key it does not list.
///
/// Every option names its Ghostty default. The pane shows that as placeholder
/// text when the file says nothing, so the difference between "set to this" and
/// "happens to be this" stays visible rather than being flattened into a
/// control that always looks decided.
struct GhosttyOption {
    enum Kind {
        case text(placeholder: String)
        /// A number with bounds, and whether it has to be whole.
        case number(min: Double, max: Double, integral: Bool)
        case toggle
        /// One of a fixed set. The first is Ghostty's default.
        case choice([String])
        case color
        case slider(min: Double, max: Double)
    }

    let key: String
    let title: String
    let kind: Kind
    /// What Ghostty does when the key is absent, written the way the file
    /// would write it.
    let `default`: String
    let note: String?

    init(_ key: String, _ title: String, _ kind: Kind, default: String, note: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.default = `default`
        self.note = note
    }
}

enum GhosttyOptions {
    static let groups: [(name: String, options: [GhosttyOption])] = [
        ("Font", [
            GhosttyOption(
                "font-family", "Family", .text(placeholder: "system default"),
                default: "",
                note: "The exact name the font calls itself, e.g. “JetBrains Mono”."),
            GhosttyOption("font-size", "Size", .number(min: 4, max: 96, integral: false),
                          default: "13"),
            GhosttyOption("font-thicken", "Thicken", .toggle, default: "false",
                          note: "Heavier stems. Worth trying on a non-Retina display."),
        ]),

        ("Colours", [
            GhosttyOption(
                "theme", "Theme", .text(placeholder: "none"),
                default: "",
                note: "One of Ghostty's built-in themes, which sets the whole palette at "
                    + "once. Run `ghostty +list-themes` to see them. Anything set below "
                    + "wins over the theme."),
            GhosttyOption("background", "Background", .color, default: "#282c34"),
            GhosttyOption("foreground", "Foreground", .color, default: "#ffffff"),
            GhosttyOption("selection-background", "Selection", .color, default: ""),
            GhosttyOption("cursor-color", "Cursor", .color, default: ""),
            GhosttyOption("background-opacity", "Opacity", .slider(min: 0.2, max: 1),
                          default: "1"),
        ]),

        ("Cursor", [
            GhosttyOption("cursor-style", "Style", .choice(["block", "bar", "underline"]),
                          default: "block"),
            GhosttyOption("cursor-style-blink", "Blink", .choice(["", "true", "false"]),
                          default: "",
                          note: "Left unset, the program running decides."),
        ]),

        ("Window", [
            GhosttyOption("window-padding-x", "Padding, horizontal",
                          .number(min: 0, max: 100, integral: true), default: "2"),
            GhosttyOption("window-padding-y", "Padding, vertical",
                          .number(min: 0, max: 100, integral: true), default: "2"),
            GhosttyOption("window-padding-balance", "Balance padding", .toggle,
                          default: "false",
                          note: "Spread the leftover pixels evenly instead of letting them "
                              + "collect on one side."),
            GhosttyOption("unfocused-split-opacity", "Unfocused split",
                          .slider(min: 0.2, max: 1), default: "0.7",
                          note: "How solid the panes you are not typing in look."),
        ]),

        ("Behaviour", [
            GhosttyOption("mouse-hide-while-typing", "Hide pointer", .toggle,
                          default: "false",
                          note: "Takes the mouse pointer out of the way while you type."),
            GhosttyOption("copy-on-select", "Copy on select",
                          .choice(["true", "false", "clipboard"]), default: "true",
                          note: "“clipboard” puts the selection on the system clipboard "
                              + "rather than the selection buffer."),
            GhosttyOption("confirm-close-surface", "Confirm close",
                          .choice(["true", "false", "always"]), default: "true",
                          note: "Ask before closing a terminal that still has something running."),
            GhosttyOption("shell-integration", "Shell integration",
                          .choice(["detect", "none", "bash", "elvish", "fish", "zsh"]),
                          default: "detect",
                          note: "How Rune learns your working directory and what is running "
                              + "— the ⌘K switcher is built on it."),
            GhosttyOption("scrollback-limit", "Scrollback",
                          .number(min: 0, max: 1_000_000_000, integral: true),
                          default: "50000000", note: "Bytes of history kept per terminal."),
        ]),
    ]

    static var all: [GhosttyOption] { groups.flatMap(\.options) }
}
