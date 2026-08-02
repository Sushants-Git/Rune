import Cocoa

// Before anything AppKit does: this binary is also the `rune` command, and a
// command that printed its version by opening a window would be a strange one.
CLI.runIfInvokedAsTool()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
