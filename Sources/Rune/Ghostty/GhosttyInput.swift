import Cocoa
import GhosttyKit

// Modifier / key-event translation between AppKit and libghostty.
//
// Adapted from Ghostty's own macOS embedding layer (MIT, Mitchell Hashimoto and
// Ghostty contributors) — see vendor/ghostty/macos/Sources/Ghostty.

enum GhosttyInput {
    /// Translate AppKit modifier flags into a libghostty mods enum.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Sided modifiers. libghostty can't represent "both pressed", which is
        // fine because nothing downstream needs that.
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// Translate a libghostty mods enum back into AppKit modifier flags.
    static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }
}

extension NSEvent {
    /// Build a libghostty key event for this NSEvent.
    ///
    /// `text` and `composing` are left unset because neither can be derived
    /// safely here — the caller owns those.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false

        // macOS gives us no way to know which modifiers were consumed producing
        // text. Ghostty's long-standing heuristic: control and command never
        // contribute, everything else did.
        ev.mods = GhosttyInput.mods(modifierFlags)
        ev.consumed_mods = GhosttyInput.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        // The unshifted codepoint uses `byApplyingModifiers: []` rather than
        // `charactersIgnoringModifiers` because the latter changes behavior when
        // ctrl is held.
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            ev.unshifted_codepoint = scalar.value
        }

        return ev
    }

    /// The text to hand libghostty for this key event, or nil if it should
    /// encode the key itself.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // Control characters are encoded by libghostty's own key encoder, so
            // hand it the uncontrolled character instead.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // Function keys arrive as private-use codepoints; don't forward those.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
