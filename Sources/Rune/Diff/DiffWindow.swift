import Cocoa

/// The diff, in a window of its own.
///
/// A window rather than a pane, deliberately and for now. Panes are typed to
/// terminals all the way through `Split`, so putting a non-terminal in one
/// means a `Pane` protocol and a pass through every split, zoom, focus and
/// close path — which is worth doing once this view has earned it, and a poor
/// thing to do first. A window costs nothing, full-screens on its own, and
/// answers whether the rendering is right.
@MainActor
final class DiffWindowController: NSWindowController {
    static let shared = DiffWindowController()

    private let diffView = DiffView()
    private let status = NSTextField(labelWithString: "")
    private var directory: String?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Changes"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        guard let content = window?.contentView else { return }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)

        diffView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(diffView)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rule)

        NSLayoutConstraint.activate([
            diffView.topAnchor.constraint(equalTo: content.topAnchor),
            diffView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            rule.topAnchor.constraint(equalTo: diffView.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            status.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    /// Show the uncommitted changes for whatever directory the focused terminal
    /// is sitting in.
    func show(directory: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(diffView)
        reload(directory: directory)
    }

    func reload(directory: String?) {
        guard let directory else {
            status.stringValue = "No terminal to take a directory from."
            diffView.show([])
            return
        }
        self.directory = directory
        status.stringValue = "Reading…"

        // Off the main thread: `git diff` on a large repository is not
        // instant, and this is the window's own load — blocking here would
        // freeze the terminal behind it too, since they share a process.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GitDiff.uncommitted(in: directory) }
            let root = GitDiff.repositoryRoot(of: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result, root: root, directory: directory) }
            }
        }
    }

    private func finish(
        _ result: Result<[GitDiff.File], Error>, root: String?, directory: String
    ) {
        switch result {
        case .success(let files):
            diffView.show(files)
            let added = files.reduce(0) { $0 + $1.addedCount }
            let removed = files.reduce(0) { $0 + $1.removedCount }
            let where_ = root.map { ($0 as NSString).lastPathComponent } ?? directory
            window?.title = files.isEmpty ? "Changes" : "Changes — \(where_)"
            status.stringValue = files.isEmpty
                ? "\(where_) is clean"
                : "\(files.count) file\(files.count == 1 ? "" : "s") changed, "
                    + "+\(added) −\(removed)   ·   n and p move by hunk, ⌘F finds"
        case .failure(GitDiff.Failure.notARepository):
            diffView.show([])
            status.stringValue = "\(directory) is not inside a git repository."
        case .failure(let error):
            diffView.show([])
            status.stringValue = "git: \(error.localizedDescription)"
        }
    }
}
