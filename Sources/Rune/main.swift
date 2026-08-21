import Cocoa

/// Point libghostty at the resources we ship before it starts.
///
/// `theme = Ayu Light` is resolved from the user's own themes directory and
/// then from the application's bundled library. Rune bundled nothing, so the
/// second half of that never happened: a theme name that worked in Ghostty was
/// simply "not found" here.
///
/// Guarded on the directory actually being there. libghostty only claims
/// TERM=xterm-ghostty when it has a resources directory, and it expects the
/// terminfo database beside it — so announcing a directory that a build did not
/// produce would leave every shell in the app announcing a terminal type
/// nothing can look up. No directory, no promise, and Rune behaves as it did
/// before.
private func pointGhosttyAtBundledResources() {
    guard let resources = Bundle.main.resourceURL else { return }
    let ghostty = resources.appendingPathComponent("ghostty")
    let terminfo = resources.appendingPathComponent("terminfo")
    let manager = FileManager.default
    guard manager.fileExists(atPath: ghostty.appendingPathComponent("themes").path),
          manager.fileExists(atPath: terminfo.path)
    else { return }
    setenv("GHOSTTY_RESOURCES_DIR", ghostty.path, 1)
}

pointGhosttyAtBundledResources()

// Before anything AppKit does: this binary is also the `rune` command, and a
// command that printed its version by opening a window would be a strange one.
CLI.runIfInvokedAsTool()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
