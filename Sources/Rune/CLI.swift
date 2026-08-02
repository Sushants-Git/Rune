import Cocoa

/// `rune` on the command line.
///
/// The same binary is both the app and the tool: `Rune.app/Contents/MacOS/Rune`
/// symlinked onto your PATH. That's why this runs before `NSApplication` is
/// touched — `rune --version` typed into a shell should print a line and exit,
/// not bounce a Dock icon and open a window.
///
/// The distinction between "the app was launched" and "the tool was run" is
/// whether there are arguments. Finder, Raycast, `open` and LaunchServices all
/// start the app with none (or with a `-psn_…` serial number, which is not an
/// argument anyone typed).
enum CLI {
    /// The argument the tool passes to a cold-launched app to say which
    /// directory the first window belongs in. Internal, and deliberately not
    /// something a person would type — it arrives *as* an argument, so it must
    /// not be mistaken for a request to run the tool again.
    static let startupDirectoryFlag = "--startup-directory"

    /// Sent to an already-running Rune to ask for a window. Distributed
    /// notifications are the cheapest IPC that macOS gives two processes of the
    /// same user, and this needs to carry one string.
    static let openNotification = Notification.Name("com.rune.rune.open")

    /// Arguments a person actually typed.
    private static var arguments: [String] {
        CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
    }

    /// The `.app` this binary actually lives in.
    ///
    /// Not `Bundle.main`: the whole point of the tool is being reached through a
    /// symlink on `$PATH`, and when the executable is entered that way
    /// `Bundle.main` resolves to the directory holding the symlink — so the app
    /// bundle, and with it the version, the identifier and everything else in
    /// Info.plist, silently isn't there. `rune --version` printing "unknown"
    /// was exactly this.
    static let bundle: Bundle = {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return .main }
        // …/Rune.app/Contents/MacOS/Rune → …/Rune.app
        let app = URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Rune.app
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return .main }
        return bundle
    }()

    static var version: String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The directory a cold-launched app should open its first window in.
    static var startupDirectory: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: startupDirectoryFlag),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Handle a command-line invocation, or return and let the app start.
    ///
    /// Anything handled here exits the process; nothing here returns having
    /// done something the app then has to know about.
    static func runIfInvokedAsTool() {
        let arguments = Self.arguments
        guard let first = arguments.first else { return }

        // A cold launch carrying the internal flag is the app starting, not the
        // tool running — it was put there by a previous `rune <path>`.
        if first == startupDirectoryFlag { return }

        switch first {
        case "--version", "-v", "version":
            print("rune \(version)")
            exit(0)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default:
            break
        }

        if first.hasPrefix("-") {
            FileHandle.standardError.write(Data("rune: unknown option \(first)\n".utf8))
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)  // EX_USAGE
        }

        open(directory: first)
    }

    /// `rune <path>` — a window there, in the Rune you already have open.
    private static func open(directory: String) {
        let path = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            .standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            FileHandle.standardError.write(Data("rune: no such directory: \(directory)\n".utf8))
            exit(66)  // EX_NOINPUT
        }

        // An instance is already up: hand it the path and get out of the way.
        // Running a second copy of a terminal you already have open is never
        // what someone meant by `rune .`.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundle.bundleIdentifier ?? "com.rune.rune")
        if let existing = running.first(where: { $0.processIdentifier != getpid() }) {
            DistributedNotificationCenter.default().postNotificationName(
                openNotification, object: path, userInfo: nil, deliverImmediately: true)
            existing.activate(options: [])
            exit(0)
        }

        // Nothing running. Launch through LaunchServices rather than becoming
        // the app in this process: a GUI app started straight from a shell
        // inherits the terminal's session and doesn't get activated properly.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [startupDirectoryFlag, path]
        configuration.activates = true

        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(
            at: bundle.bundleURL, configuration: configuration
        ) { _, error in
            failure = error
            done.signal()
        }
        done.wait()

        if let failure {
            FileHandle.standardError.write(Data("rune: \(failure.localizedDescription)\n".utf8))
            exit(70)  // EX_SOFTWARE
        }
        exit(0)
    }

    private static var usage: String {
        """
        rune \(version) — a terminal for running several coding agents at once

        usage:
          rune                 open Rune, or bring it to the front
          rune <directory>     open a workspace there, in the Rune already running
          rune --version       print the version
          rune --help          print this

        The command is this app's own binary. Install it with:
          ./scripts/install-cli.sh
        """
    }
}
