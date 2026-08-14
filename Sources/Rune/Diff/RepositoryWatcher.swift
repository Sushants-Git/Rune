import Foundation

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

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
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
            UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents))
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
