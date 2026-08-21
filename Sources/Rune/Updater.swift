import Cocoa

/// In-app updates, fed straight from the GitHub Releases API.
///
/// Ghostty does this with Sparkle and a hosted appcast. Rune doesn't, on
/// purpose. Sparkle's value is mostly in the parts Rune can't use yet: a signed
/// appcast, Developer ID validation, and a framework with XPC helpers that has
/// to be embedded, re-signed and rpath-fixed inside a bundle `swift build`
/// doesn't know how to assemble. Rune ships an ad-hoc signed zip attached to a
/// GitHub Release, so the release list *is* the appcast, and the whole mechanism
/// is one HTTP GET, one unzip and one swap.
///
/// The tradeoff is honest and worth writing down: an ad-hoc signature proves the
/// download wasn't corrupted in transit, not who built it. What actually stands
/// between a user and a malicious update here is HTTPS to api.github.com plus
/// the release only being writable by whoever holds the repo's credentials. When
/// Rune gets a Developer ID, this should grow real signature-identity checks —
/// see `verify(stagedApp:)`, which is where they'd go.
@MainActor
final class Updater {
    static let shared = Updater()

    /// Posted whenever `state` changes. The pill in each window's title bar
    /// listens for it, which is why this is a notification rather than a single
    /// callback — there is one updater and any number of windows.
    static let stateChanged = Notification.Name("RuneUpdaterStateChanged")

    /// Where a check looks. Overridable so the flow can be exercised against a
    /// fixture without cutting a real release.
    nonisolated private static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["RUNE_UPDATE_FEED"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/Sushants-Git/Rune/releases/latest")!
    }

    /// The release page, for the cases where Rune would rather hand the user to
    /// the browser than pretend it can install something itself.
    static let releasesPage = URL(string: "https://github.com/Sushants-Git/Rune/releases/latest")!

    /// The assets a release can carry for Rune to install it, best first.
    ///
    /// Two of them because the artefact was renamed when builds went universal:
    /// releases up to v0.5.0 attach `macos-arm64.zip` and later ones attach
    /// `macos-universal.zip`. An updater that only knew the new name would look
    /// at an older release and report finding nothing — which is precisely the
    /// silent-failure shape this code has already been bitten by once.
    nonisolated private static let assetSuffixes = ["macos-universal.zip", "macos-arm64.zip"]

    enum State {
        case idle
        case checking
        case available(Release)
        /// `fraction` is nil until the server tells us how big the asset is.
        case downloading(Release, fraction: Double?)
        case readyToInstall(Release)
        /// Only ever shown for a check the user asked for; an automatic check
        /// that finds nothing says nothing.
        case upToDate
        case failed(String)
    }

    struct Release {
        let version: Version
        let notes: String
        let page: URL
        let asset: URL
    }

    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: Self.stateChanged, object: self) }
    }

    /// The unpacked, validated app waiting to replace the running one.
    private var staged: URL?
    private var work: Task<Void, Never>?

    /// The installed build's version, or nil when Rune isn't running from a
    /// bundle at all (`swift run`), which is the signal to disable updates.
    ///
    /// Read from disk on every call, deliberately, rather than through
    /// `bundle.infoDictionary` — Foundation caches that for the life of the
    /// process, so an app whose bundle is replaced underneath it goes on
    /// reporting the version it launched as:
    ///
    ///     first read                    : 0.9.4
    ///     after the bundle was replaced : 0.9.4   ← cached
    ///     read straight from disk       : 0.9.5
    ///
    /// Which is exactly what `rune update` does to a running Rune. The app
    /// kept comparing the new release against its own stale number and kept
    /// offering an update that was already installed, with no way out but a
    /// relaunch. One small plist read an hour is a very cheap fix for that.
    static var currentVersion: Version? {
        let bundle = CLI.bundle.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let string = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return Version(string)
    }

    /// Whether updating is possible at all. A `swift build` binary run straight
    /// out of `.build` has nothing to replace, and saying "update available" to
    /// someone running their own build would be a lie about what the button does.
    var isSupported: Bool { Self.currentVersion != nil }

    // MARK: - Checking

    private static let lastCheckKey = "RuneLastUpdateCheck"
    /// The version that was running the last time a check happened.
    private static let lastCheckVersionKey = "RuneLastUpdateCheckVersion"
    /// And which copy of Rune it was.
    ///
    /// `UserDefaults` is keyed by bundle identifier, so every Rune on the
    /// machine shares this one timer — the installed app, a build in `build/`,
    /// an old copy in `~/Downloads`. Anyone who develops Rune while also using
    /// it has at least two, and one silences the other for an hour with no way
    /// to tell why. That is not hypothetical: a test build wrote this timestamp
    /// and the installed app then sat quiet on a stale version.
    private static let lastCheckPathKey = "RuneLastUpdateCheckPath"

    /// The shortest gap between two checks.
    ///
    /// This was a day, and a day is far too long. The failure it produces looks
    /// exactly like a broken updater: check at 20:22, find nothing because
    /// nothing is out yet, a release ships at 21:50, and the app then sits
    /// silent until the following evening — with the pill it is supposed to
    /// show sitting behind a timer nobody can see. That happened, and the
    /// second report of "the updater isn't working" was it.
    ///
    /// An hour costs one request an hour against an unauthenticated limit of
    /// sixty, which is nothing, and it means a terminal left open notices a
    /// release over a coffee rather than over a night.
    private static let checkInterval: TimeInterval = 60 * 60

    /// How often to *consider* checking. Equal to the interval, so the timer is
    /// the schedule rather than a sampler for a slower one.
    private static let pollInterval: TimeInterval = 60 * 60

    private var timer: Timer?

    /// Begin checking, and keep checking.
    ///
    /// The keeping is the point, and it was missing: `checkInBackground` used to
    /// be called once from `applicationDidFinishLaunching` and never again, so
    /// an app that documented "it checks once a day" actually checked once per
    /// *launch*. Rune is a terminal — it is opened once and left for days, which
    /// is exactly the usage pattern where "once per launch" means "never".
    ///
    /// The timer is hourly and cheap: most wake-ups compare two dates and
    /// return. Becoming active is worth a look too, since a laptop that slept
    /// through the timer would otherwise sit idle until the next hour, and
    /// coming back to the app is the moment someone might act on it.
    ///
    /// Opening the app checks *unconditionally*, ignoring the interval. Launching
    /// is a deliberate act and a natural moment to be told something is waiting,
    /// and it's the one check a person can actually cause on purpose short of
    /// finding the menu item. It costs a single request, and the interval still
    /// governs everything that happens afterwards without anyone asking.
    func start() {
        guard isSupported else { return }
        check(userInitiated: false)

        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkInBackground() }
        }
        // Nothing here is time-critical; letting the OS coalesce these keeps a
        // sleeping laptop asleep.
        timer.tolerance = Self.pollInterval / 10
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Updater.shared.checkInBackground() }
        }
    }

    /// A check that stays silent unless it finds something, and does nothing at
    /// all if one ran recently.
    func checkInBackground() {
        guard isSupported else { return }

        // The timer only applies to the copy of Rune that set it. A different
        // version means a build that no longer exists; a different path means a
        // different copy entirely, and neither should be able to silence this
        // one. Installing a build and having it stay quiet because its
        // predecessor looked an hour ago is the same silence-that-reads-as-
        // broken as the interval itself.
        let running = Self.currentVersion.map(String.init(describing:))
        let checked = UserDefaults.standard.string(forKey: Self.lastCheckVersionKey)
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let checkedPath = UserDefaults.standard.string(forKey: Self.lastCheckPathKey)
        let sameCopy = running != nil && running == checked && path == checkedPath

        if sameCopy,
           let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date {
            let since = Date().timeIntervalSince(last)
            // A timestamp in the future is a clock that moved, not a check that
            // hasn't aged yet; treating it as fresh would suppress updates until
            // the clock caught up with it.
            if since >= 0, since < Self.checkInterval { return }
        }
        check(userInitiated: false)
    }

    /// The Check for Updates… menu item. Reports every outcome, including
    /// "nothing to do" — the user asked, so silence would read as a bug.
    func checkNow() {
        guard isSupported else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        // A check already in flight, or an update already downloaded and
        // waiting, both mean there is nothing useful for a new check to do.
        switch state {
        case .checking, .downloading, .readyToInstall: return
        default: break
        }

        state = .checking
        work = Task { [weak self] in
            do {
                let release = try await Self.fetchLatest()
                guard let self, !Task.isCancelled else { return }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                // Stamped with which copy did the checking, so no other copy
                // inherits this one's timer. See checkInBackground.
                UserDefaults.standard.set(
                    Self.currentVersion.map(String.init(describing:)),
                    forKey: Self.lastCheckVersionKey)
                UserDefaults.standard.set(
                    Bundle.main.bundleURL.standardizedFileURL.path,
                    forKey: Self.lastCheckPathKey)

                guard let current = Self.currentVersion, let release, release.version > current
                else {
                    self.state = userInitiated ? .upToDate : .idle
                    if userInitiated { self.clearTransient(after: 4) }
                    return
                }
                self.state = .available(release)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = userInitiated
                    ? .failed(Self.message(for: error))
                    : .idle
                if userInitiated { self.clearTransient(after: 6) }
            }
        }
    }

    /// Ask GitHub what the newest release is. Returns nil when the newest
    /// release isn't installable — a draft, a prerelease, or one with no macOS
    /// asset attached, all of which mean "nothing to offer" rather than an error.
    nonisolated private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Rune", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        // The feed is small and changes rarely; a stale cached copy would keep
        // showing an update that's already installed.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // A 404 here is not "you're current" — it's Rune being unable to
            // see any releases, which a repo with none and a repo it can't read
            // both produce. Saying "up to date" for it would be a lie, and was:
            // it hid a private repository for a whole release cycle, because
            // silence looked exactly like success.
            if http.statusCode == 404 { throw UpdateError.noReleases }
            throw UpdateError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let feed = try decoder.decode(Feed.self, from: data)

        let asset = assetSuffixes.lazy
            .compactMap { suffix in feed.assets.first { $0.name.hasSuffix(suffix) } }
            .first

        guard !feed.draft, !feed.prerelease,
              let version = Version(feed.tagName),
              let asset,
              let assetURL = URL(string: asset.browserDownloadUrl),
              let page = URL(string: feed.htmlUrl)
        else { return nil }

        return Release(
            version: version,
            notes: feed.body ?? "",
            page: page,
            asset: assetURL)
    }

    private struct Feed: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    // MARK: - Downloading

    /// Fetch the update and get it ready to install. Safe to call from the pill
    /// on a click; it only does anything from `.available`.
    func download() {
        guard case .available(let release) = state else { return }
        state = .downloading(release, fraction: nil)

        work = Task { [weak self] in
            do {
                // Reported through the singleton rather than a captured `self`:
                // the callback comes off URLSession's queue, and there is only
                // ever one updater for it to be talking about.
                let zip = try await Download.run(from: release.asset) { fraction in
                    Task { @MainActor in
                        Updater.shared.report(fraction, of: release)
                    }
                }
                defer { try? FileManager.default.removeItem(at: zip) }

                let app = try Self.unpack(zip)
                try Self.verify(stagedApp: app, is: release.version)

                guard let self, !Task.isCancelled else {
                    try? FileManager.default.removeItem(
                        at: app.deletingLastPathComponent())
                    return
                }
                self.staged = app
                self.state = .readyToInstall(release)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(Self.message(for: error))
                self.clearTransient(after: 8)
            }
        }
    }

    /// Progress from an in-flight download. Ignored unless that's still what
    /// Rune is doing — a cancelled or failed download shouldn't be able to drag
    /// the pill back to "Downloading" from whatever replaced it.
    private func report(_ fraction: Double?, of release: Release) {
        guard case .downloading = state else { return }
        state = .downloading(release, fraction: fraction)
    }

    /// Unzip into a fresh staging directory and return the `.app` inside it.
    ///
    /// `ditto` rather than a zip library: it's what created the archive in CI,
    /// it preserves the symlinks and resource forks an app bundle relies on, and
    /// getting either of those wrong produces a bundle that unpacks fine and
    /// then won't launch.
    nonisolated private static func unpack(_ zip: URL) throws -> URL {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path],
                failure: UpdateError.unpackFailed)

        let contents = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            try? FileManager.default.removeItem(at: staging)
            throw UpdateError.unpackFailed
        }
        return app
    }

    /// Refuse anything that isn't recognisably the same app at the version the
    /// release claimed.
    ///
    /// The identity check is the weak link and is meant to be: `codesign
    /// --verify` on an ad-hoc signature confirms the bundle's contents match its
    /// own seal — that it arrived intact — and says nothing about who sealed it.
    /// The day Rune is signed with a Developer ID, this gains a
    /// `--requirement` check pinning the team identifier, and that's the line
    /// that would make the download trustworthy on its own.
    nonisolated private static func verify(stagedApp app: URL, is version: Version) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw UpdateError.notRune
        }
        guard info["CFBundleIdentifier"] as? String == CLI.bundle.bundleIdentifier else {
            throw UpdateError.notRune
        }
        guard let shipped = (info["CFBundleShortVersionString"] as? String)
            .flatMap(Version.init), shipped == version
        else { throw UpdateError.versionMismatch }

        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                failure: UpdateError.signatureInvalid)
    }

    // MARK: - Installing

    /// Swap the new app in and relaunch.
    ///
    /// The swap happens in a detached shell that waits for this process to exit,
    /// not here. Replacing a bundle whose executable is currently mapped works
    /// often enough to be tempting and fails in ways that leave no app behind at
    /// all, so the running app's only job is to hand over the paths and quit.
    func install() {
        guard case .readyToInstall = state, let staged else { return }
        let destination = Bundle.main.bundleURL

        // Refuse to point `rm -rf` at anything that isn't the app bundle we
        // started from. Cheap, and the failure it prevents is unrecoverable.
        guard destination.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: destination.path),
              FileManager.default.isWritableFile(
                atPath: destination.deletingLastPathComponent().path)
        else {
            state = .failed("Rune can't update itself where it's installed")
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }

        // The script lives outside the staging directory it deletes: `sh` reads
        // a script as it goes, and deleting the file out from under it midway
        // is a genuinely confusing way to fail.
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-install-\(UUID().uuidString).sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                script.path,
                String(ProcessInfo.processInfo.processIdentifier),
                staged.path,
                destination.path,
                staged.deletingLastPathComponent().path,
                "1",
            ]
            try process.run()
        } catch {
            state = .failed(Self.message(for: error))
            return
        }

        NSApp.terminate(nil)
    }

    /// Quitting counts as restarting.
    ///
    /// "Restart to update" is a button, but it describes something the user can
    /// also just *do* — and doing it left the update staged and unapplied, so
    /// the new copy re-downloaded on the next launch and offered the same
    /// button again, for ever. Anyone who quits Rune with an update waiting has
    /// asked for it as clearly as anyone who clicked.
    ///
    /// No reopen: they quit, so they wanted to be quit.
    func installIfStagedOnQuit() {
        guard case .readyToInstall = state, let staged else { return }
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: destination.path),
              FileManager.default.isWritableFile(
                atPath: destination.deletingLastPathComponent().path)
        else { return }
        try? Self.swap(
            staged: staged, into: destination, waitingFor: getpid(), reopen: false)
    }

    /// Wait for Rune to quit, swap the bundle, put it back if the swap fails,
    /// and start the new one.
    nonisolated private static let installScript = """
    #!/bin/sh
    # $1 pid  $2 new app  $3 installed app  $4 staging dir  $5 reopen (1/0)
    # Written by Rune's updater; safe to delete.
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done

    backup="$3.rune-previous"
    rm -rf "$backup"
    mv "$3" "$backup" || exit 1
    if ! /usr/bin/ditto "$2" "$3"; then
      rm -rf "$3"
      mv "$backup" "$3"
      /usr/bin/open "$3"
      exit 1
    fi

    # Downloads carry a quarantine flag that would make the freshly installed
    # app ask to be vouched for on first launch, as though it were unknown.
    /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
    rm -rf "$backup" "$4"
    [ "$5" = 1 ] && /usr/bin/open "$3"

    """

    // MARK: - `rune update`

    /// The whole update from a shell, start to finish, blocking.
    ///
    /// Deliberately not "tell the running app to update": from a terminal the
    /// expected thing is that the command does the work and says what happened,
    /// rather than nudging a window somewhere else and exiting silently. It is
    /// also the only way to update a Rune that isn't running.
    ///
    /// Everything it needs — fetch, unpack, verify, the install script — is the
    /// same code the pill uses. Only the ending differs: the app quits itself
    /// and comes back, whereas this quits Rune only if it was already running,
    /// and reopens it only in that case.
    nonisolated static func updateFromCommandLine() -> Never {
        let bundle = CLI.bundle
        guard bundle.bundleURL.pathExtension == "app",
              let currentString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let current = Version(currentString)
        else {
            note("rune: this isn't running from an installed Rune.app, so there's nothing to update")
            exit(70)
        }

        note("current: \(current)")

        let outcome = blocking { () async throws -> (Release, URL)? in
            guard let release = try await fetchLatest() else { return nil }
            guard release.version > current else { return (release, URL(fileURLWithPath: "")) }

            note("downloading \(release.version)…")
            let zip = try await Download.run(from: release.asset) { _ in }
            defer { try? FileManager.default.removeItem(at: zip) }
            let app = try unpack(zip)
            try verify(stagedApp: app, is: release.version)
            return (release, app)
        }

        let release: Release
        let staged: URL
        switch outcome {
        case .failure(let error):
            note("rune: \(message(for: error))")
            exit(70)
        case .success(nil):
            note("no releases visible")
            exit(0)
        case .success(.some(let found)):
            (release, staged) = found
        }

        guard release.version > current else {
            note("already on the latest release")
            exit(0)
        }

        // Quit a running Rune before swapping the bundle out from under it —
        // but only *this* Rune. Matching on bundle identifier alone finds every
        // copy on the machine, so updating a build in /tmp went and terminated
        // the one in /Applications.
        let installed = bundle.bundleURL.standardizedFileURL
        let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? "com.rune.rune")
            .first {
                $0.processIdentifier != getpid()
                    && $0.bundleURL?.standardizedFileURL == installed
            }

        if let app {
            note("quitting Rune…")
            app.terminate()
            // Bounded: terminate() is a request, and something modal or wedged
            // can refuse it. Waiting forever here is how this hung.
            let deadline = Date().addingTimeInterval(15)
            while !app.isTerminated, Date() < deadline { usleep(200_000) }
            if !app.isTerminated {
                note("rune: Rune is still running and wouldn't quit. Quit it and try again.")
                exit(75)  // EX_TEMPFAIL
            }
        }

        do {
            // Waiting on this process: it exits in a moment, so the script gets
            // going immediately rather than waiting on an app that has already
            // gone.
            try swap(staged: staged, into: installed, waitingFor: getpid(),
                     reopen: app != nil)
        } catch {
            note("rune: \(error.localizedDescription)")
            exit(70)
        }

        note("updated \(current) → \(release.version)")
        exit(0)
    }

    /// Hand the swap to the detached script, same as the in-app install does.
    nonisolated private static func swap(
        staged: URL, into destination: URL, waitingFor pid: pid_t, reopen: Bool
    ) throws {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-install-\(UUID().uuidString).sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(pid),
            staged.path,
            destination.path,
            staged.deletingLastPathComponent().path,
            reopen ? "1" : "0",
        ]
        try process.run()
        // Not waited on: the script's first act is to wait for `pid` — this
        // process — to exit, so waiting here would deadlock by construction.
    }

    /// Run an async job from a synchronous command-line context.
    nonisolated private static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error> {
        let done = DispatchSemaphore(value: 0)
        // Deliberately not `nonisolated(unsafe) var` shared across a hop: the
        // box is written once inside the task and read once after the wait.
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await work()) }
            catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return box.value ?? .failure(UpdateError.unpackFailed)
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    nonisolated private static func note(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    // MARK: - Plumbing

    enum UpdateError: LocalizedError {
        case http(Int)
        case noReleases
        case unpackFailed
        case notRune
        case versionMismatch
        case signatureInvalid

        var errorDescription: String? {
            switch self {
            case .http(let code): "GitHub returned \(code)"
            case .noReleases: "No releases visible"
            case .unpackFailed: "The download couldn't be unpacked"
            case .notRune: "The download isn't Rune"
            case .versionMismatch: "The download is a different version than the release says"
            case .signatureInvalid: "The download's signature doesn't check out"
            }
        }
    }

    /// Run a tool and throw if it doesn't exit cleanly.
    nonisolated private static func run(
        _ tool: String, _ arguments: [String], failure: UpdateError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure }
    }

    /// Short enough for a title bar pill; the full text is the tooltip.
    nonisolated private static func message(for error: Error) -> String {
        if let update = error as? UpdateError { return update.errorDescription ?? "Update failed" }
        if (error as? URLError)?.code == .notConnectedToInternet { return "You're offline" }
        return (error as NSError).localizedDescription
    }

    /// Drop back to silence after a message that has been read. Only for the
    /// states that are announcements — an available update stays put.
    private func clearTransient(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            switch self.state {
            case .upToDate, .failed: self.state = .idle
            default: break
            }
        }
    }
}

// MARK: - Version

/// Just enough of a version to answer "is theirs newer than mine".
///
/// Dotted integers, compared left to right, with a missing component treated as
/// zero so `1.2` and `1.2.0` are the same release. Anything after a `-` is
/// dropped rather than ordered: Rune's release pipeline builds one artifact per
/// tag, so a suffix never distinguishes two things that both exist.
struct Version: Comparable, CustomStringConvertible {
    private let components: [Int]
    private let raw: String

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = String(text.split(separator: "-", maxSplits: 1).first ?? "")
        let parsed = core.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(where: { $0 == nil }) else { return nil }
        components = parsed.compactMap { $0 }
        raw = core
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = lhs.components[safe: index] ?? 0
            let right = rhs.components[safe: index] ?? 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { raw }
}

// MARK: - Download

/// A download that reports progress, which the async `URLSession.data` can't do
/// and `URLSession.bytes` can only do one byte at a time.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Fetch `url` to a temporary file, calling `progress` with a 0…1 fraction
    /// as it goes — nil while the size is still unknown.
    static func run(
        from url: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let delegate = Download(progress: progress)
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Rune", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            session.downloadTask(with: request).resume()
        }
    }

    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// URLSession may report completion twice in error paths; resuming a
    /// continuation twice traps.
    private var finished = false
    private let lock = NSLock()

    private init(progress: @escaping @Sendable (Double?) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The delegate's temporary file is deleted the moment this returns, so
        // it has to be moved somewhere of our own before handing it back.
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            if let response = downloadTask.response as? HTTPURLResponse,
               response.statusCode != 200 {
                try? FileManager.default.removeItem(at: destination)
                finish(.failure(Updater.UpdateError.http(response.statusCode)))
                return
            }
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
