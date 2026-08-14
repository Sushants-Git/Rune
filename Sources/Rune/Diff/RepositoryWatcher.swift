import Foundation

/// Directories whose churn can never show up in a diff.
///
/// `.git` is the interesting exception rather than the rule: almost everything
/// in it is git's own bookkeeping, but `index` is exactly how staging announces
/// itself and `HEAD` is how a checkout or a commit does. The rest are the usual
/// build outputs — ignored by git, so invisible in the diff by definition, and
/// the noisiest things on the disk.
private let noisyDirectories = [
    "/.build/", "/build/", "/DerivedData/", "/node_modules/", "/target/",
    "/dist/", "/.next/", "/.venv/", "/__pycache__/", "/.zig-cache/", "/zig-out/",
]

/// At file scope rather than on the class, and that is not a style choice: a C
/// function pointer that reaches for `Self` crashed the Swift 6 concurrency
/// pass — a compiler crash, not a diagnostic.
private func pathCouldMatter(_ path: String) -> Bool {
    if let range = path.range(of: "/.git/") {
        let rest = path[range.upperBound...]
        return rest == "index" || rest == "HEAD" || rest == "MERGE_HEAD"
            || rest == "ORIG_HEAD" || rest.hasPrefix("refs/")
    }
    return !noisyDirectories.contains { path.contains($0) }
}

/// Tells you when a repository changed underneath you.
///
/// The panel exists to be read while something else is writing — an agent in
/// the pane beside it, lazygit in another tab, you in an editor. A diff that
/// only updates when you press `r` is a screenshot, and the first thing it does
/// is disagree with the terminal next to it.
///
/// FSEvents rather than polling `git status`: status on a large tree is not
/// free, and running it twice a second forever to learn nothing is the kind of
/// background cost you notice on battery and cannot explain.
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// Latency, in seconds, that FSEvents coalesces bursts over. A build or a
    /// checkout is thousands of events; this turns them into one or two.
    private static let latency = 0.6


    /// - Parameter root: the repository's working tree. Watched whole, `.git`
    ///   included, because staging shows up as a write to `.git/index` and
    ///   nowhere else.
    init?(root: String, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // A burst that is entirely build output is not news. Without this
            // check a `swift build` in the pane beside the diff fired the whole
            // pipeline — four git subprocesses and a full re-render — twice a
            // second for the length of the build, none of which could change a
            // single line of what was on screen.
            guard list.isEmpty || list.prefix(Int(count)).contains(where: pathCouldMatter)
            else { return }
            watcher.onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            // NoDefer so the first change in a quiet period arrives at once and
            // only the tail of a burst waits out the latency.
            //
            // UseCFTypes is not optional here. Without it the callback's
            // `eventPaths` is a C array of `char *`, and reading it as an
            // NSArray — which is what the filtering below needs — means sending
            // Objective-C messages to a pointer that is not an object. It does
            // not fail cleanly: the process dies with no exception, no crash
            // report and no exit handler, about a second after the first write
            // to the repository. Staging writes `.git/index`, so staging was
            // always the thing that appeared to kill it.
            UInt32(kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
