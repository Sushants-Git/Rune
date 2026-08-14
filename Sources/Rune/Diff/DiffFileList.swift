import Cocoa

extension GitDiff.File {
    /// Green for staged, orange for waiting, blue for never-seen. Read in the
    /// list and again down the side of the file's header in the diff, so the
    /// same file is the same colour wherever you meet it.
    var tint: NSColor {
        if untracked { return .systemBlue }
        if staged && !unstaged { return .systemGreen }
        if staged { return .systemYellow }
        return .systemOrange
    }
}

/// Which files you have already looked at.
///
/// Keyed by content, not by path: a file marked viewed and then edited again is
/// not viewed any more, which is the only reading of the mark that survives an
/// agent still working in the background. Kept per repository so two checkouts
/// do not share opinions.
@MainActor
enum ViewedFiles {
    private static let key = "RuneDiffViewed"

    private static func token(_ file: GitDiff.File) -> String {
        // The counts stand in for a hash of the hunks. Cheap, and wrong only
        // when an edit leaves the exact same number of added and removed lines
        // — in which case you are looking at a revision of something you had
        // already read, which is the case where being wrong costs least.
        "\(file.displayPath)#\(file.addedCount)+\(file.removedCount)"
    }

    static func isViewed(_ file: GitDiff.File, root: String) -> Bool {
        stored(root).contains(token(file))
    }

    static func toggle(_ file: GitDiff.File, root: String) {
        var set = stored(root)
        let key = token(file)
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        write(set, root: root)
    }

    static func clear(root: String) { write([], root: root) }

    private static func stored(_ root: String) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[root] ?? [])
    }

    private static func write(_ set: Set<String>, root: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[root] = Array(set)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// The list of changed files, down the left of the diff.
///
/// Multiple selection on purpose: staging is something you do to a set, and
/// making it one-at-a-time is the difference between a review tool and a
/// sequence of chores.
@MainActor
final class DiffFileList: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var files: [GitDiff.File] = []
    private var root = ""

    /// The highlighted files changed; the diff should follow the first.
    var onSelect: (([GitDiff.File]) -> Void)?
    var onToggleViewed: ((GitDiff.File) -> Void)?

    var selectedFiles: [GitDiff.File] {
        tableView.selectedRowIndexes.compactMap { files[safe: $0] }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        tableView.headerView = nil
        // Two lines of text and a dot need the room. At 30 the name and the
        // path it sits above were touching, which is most of why the column
        // read as a wall rather than a list.
        tableView.rowHeight = 42
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.addTableColumn(
            NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        // A gap above the first row, so it is not welded to the rule over it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func show(_ files: [GitDiff.File], root: String) {
        let previous = selectedFiles.map(\.displayPath)
        self.files = files
        self.root = root
        tableView.reloadData()

        // Hold the selection across a reload, or staging a file scrolls you
        // back to the top of a list you were halfway down.
        let restored = IndexSet(files.indices.filter { previous.contains(files[$0].displayPath) })
        if restored.isEmpty, !files.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            tableView.selectRowIndexes(restored, byExtendingSelection: false)
        }
    }

    func move(by delta: Int) {
        guard !files.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), files.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func takeFocus() { window?.makeFirstResponder(tableView) }

    /// The view that should hold the keyboard when this side is the active one.
    var focusTarget: NSView { tableView }

    @objc private func rowDoubleClicked() {
        guard let file = files[safe: tableView.clickedRow] else { return }
        onToggleViewed?(file)
    }
}

extension DiffFileList: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let file = files[safe: row] else { return nil }
        return FileRow(file: file, viewed: ViewedFiles.isViewed(file, root: root))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedFiles)
    }
}

/// One file: where it lives, what it is called, and how much of it moved.
private final class FileRow: NSView {
    init(file: GitDiff.File, viewed: Bool) {
        super.init(frame: .zero)

        // A dot rather than a letter. The states are few and a colour is read
        // faster than a `M` you have to remember the meaning of; the tooltip
        // carries the word for when you don't.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = file.tint.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let full = file.displayPath as NSString
        let name = NSTextField(labelWithString: full.lastPathComponent)
        name.font = .systemFont(ofSize: 12, weight: viewed ? .regular : .medium)
        name.textColor = viewed ? .tertiaryLabelColor : .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        let folder = full.deletingLastPathComponent
        let path = NSTextField(labelWithString: folder)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.translatesAutoresizingMaskIntoConstraints = false
        addSubview(path)

        // Coloured rather than grey: the two numbers say opposite things and
        // reading them as one grey blob is what made this column noisy.
        let counts = NSTextField(labelWithString: "")
        counts.attributedStringValue = Self.counts(for: file)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counts)

        toolTip = [
            file.displayPath,
            file.untracked ? "untracked" : nil,
            file.staged ? "staged" : nil,
            file.unstaged ? "not staged" : nil,
            viewed ? "viewed" : nil,
        ].compactMap { $0 }.joined(separator: " · ")

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            // Centred as a pair rather than pinned to the top: the two lines
            // are one label, and hanging them off the top edge left the row
            // bottom-heavy at every width. A file at the repository root has no
            // second line, so its name centres on its own instead of sitting
            // high above a placeholder that says nothing.
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            folder.isEmpty
                ? name.centerYAnchor.constraint(equalTo: centerYAnchor)
                : name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -10),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            path.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -10),

            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `+3 −0`, each half in its own colour, and a zero left grey so the eye
    /// skips it.
    private static func counts(for file: GitDiff.File) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        if file.isBinary {
            return NSAttributedString(
                string: "bin",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: "+\(file.addedCount)",
            attributes: [
                .font: font,
                .foregroundColor: file.addedCount > 0
                    ? NSColor.systemGreen : NSColor.quaternaryLabelColor,
            ]))
        text.append(NSAttributedString(
            string: "  −\(file.removedCount)",
            attributes: [
                .font: font,
                .foregroundColor: file.removedCount > 0
                    ? NSColor.systemRed : NSColor.quaternaryLabelColor,
            ]))
        return text
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
