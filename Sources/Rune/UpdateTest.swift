import Cocoa

/// Drives the updater end to end against a local feed, because the alternative
/// way to test an update is to cut a real release and hope.
///
///   RUNE_UPDATE_FEED=http://localhost:8000/latest.json RUNE_TEST_UPDATE=1 \
///     /tmp/updtest/installed/Rune.app/Contents/MacOS/Rune
///
/// Prints each state transition and then installs, which quits this process and
/// relaunches whatever replaced it — so the last thing it proves is that the
/// swap left a working app behind.
@MainActor
enum UpdateTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNE_TEST_UPDATE"] != nil
    }

    /// Set when the run should stop before replacing anything, for exercising
    /// the check and download halves without a swap.
    private static var checkOnly: Bool {
        let mode = ProcessInfo.processInfo.environment["RUNE_TEST_UPDATE"]
        return mode == "check" || mode == "pill"
    }

    /// `pill` writes each state's rendering to /tmp so the chrome can be looked
    /// at without a screen recording entitlement.
    private static var rendersPill: Bool {
        ProcessInfo.processInfo.environment["RUNE_TEST_UPDATE"] == "pill"
    }

    /// Draw the pill as it currently stands into /tmp/rune-pill-<state>.png.
    private static func renderPill(_ name: String) {
        let pill = UpdatePill()
        pill.layoutSubtreeIfNeeded()
        let size = pill.fittingSize
        guard size.width > 0, size.height > 0 else {
            print("pill \(name): hidden")
            return
        }
        pill.frame = NSRect(origin: .zero, size: size)
        guard let rep = pill.bitmapImageRepForCachingDisplay(in: pill.bounds) else { return }
        pill.cacheDisplay(in: pill.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: "/tmp/rune-pill-\(name).png")
        try? png.write(to: url)
        print("pill \(name): \(Int(size.width))x\(Int(size.height)) -> \(url.path)")
    }

    static func run() {
        print("=== UPDATE TEST ===")
        print("running version: \(Updater.currentVersion.map(String.init(describing:)) ?? "none")")
        print("supported: \(Updater.shared.isSupported)")

        NotificationCenter.default.addObserver(
            forName: Updater.stateChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { advance() }
        }

        Updater.shared.checkNow()
    }

    private static func advance() {
        switch Updater.shared.state {
        case .idle:
            print("state: idle")
        case .checking:
            print("state: checking")
        case .available(let release):
            print("state: available \(release.version)")
            if rendersPill {
                renderPill("available")
                // Carry on into the download so its pill can be drawn too.
                Updater.shared.download()
                return
            }
            guard !checkOnly else { finish(0) }
            Updater.shared.download()
        case .downloading(_, let fraction):
            print("state: downloading \(fraction.map { "\(Int($0 * 100))%" } ?? "…")")
        case .readyToInstall(let release):
            print("state: ready \(release.version)")
            if rendersPill {
                renderPill("ready")
                finish(0)
            }
            guard !checkOnly else { finish(0) }
            print("installing…")
            Updater.shared.install()
        case .upToDate:
            print("state: up to date")
            finish(0)
        case .failed(let reason):
            print("state: FAILED \(reason)")
            finish(1)
        }
    }

    private static func finish(_ code: Int32) -> Never {
        print("=== DONE ===")
        exit(code)
    }
}
