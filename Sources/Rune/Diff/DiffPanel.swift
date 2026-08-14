import Cocoa

/// The diff, beside the terminal rather than in a window of its own.
///
/// Not a pane in the split tree, deliberately. `SplitPane` is typed to a
/// terminal through every path that touches it — focus, dimming, the find bar,
/// zoom, close — and a diff answers almost none of those questions. Making it a
/// pane means a protocol through all of that, and the reward is being able to
/// split a diff against a diff, which nobody asked for.
///
/// Three columns of chrome and one of content: a summary line, the list of what
/// changed, the diff itself, and a commit box. Enough to read a change and
/// land it without leaving, which is the whole point of it being here rather
/// than in another application.
@MainActor
final class DiffPanel: NSView {
    private let diffView = DiffView()
    private let fileList = DiffFileList()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let message = NSTextField()
    private let commitButton = NSButton()
    private let divider = DiffDivider()
    private let listDivider = DiffDivider()

    /// Where the panel's left edge is being dragged to. The controller owns the
    /// width; this only reports.
    var onResize: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    /// Something changed the repository, so the host should read it again.
    var onNeedsReload: (() -> Void)?

    private var files: [GitDiff.File] = []
    private var root = ""
    private var directory = ""
    private var listWidth: NSLayoutConstraint!
    /// What to put the sidebar back to when it is brought out again.
    private var listWidthBeforeHiding: CGFloat = 244

    static let minimumWidth: CGFloat = 420

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        // Settings apply now rather than the next time the panel is opened. A
        // theme you have to close a window to see is a theme you cannot choose
        // between.
        NotificationCenter.default.addObserver(
            forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
                guard note.object as? Settings.Kind != .shortcuts else { return }
                MainActor.assumeIsolated { self?.redraw() }
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        // The whole panel in the editor's face. One SF Pro label beside a
        // monospaced diff is what made this read as a Mac window with code in
        // it rather than as part of the editor.
        status.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        hint.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.stringValue = ""
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        let topRule = separator()
        let bottomRule = separator()
        // A vertical seam, so it cannot come from `separator()` — that helper
        // pins a height of 1, and asking the same view to also span top to
        // bottom is a contradiction Auto Layout resolves by dropping
        // constraints, which took the file list and the diff down with it.
        let listRule = NSView()
        listRule.wantsLayer = true
        listRule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        listRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listRule)

        fileList.translatesAutoresizingMaskIntoConstraints = false
        fileList.onSelect = { [weak self] selected in
            self?.updateHint()
            guard let first = selected.first else { return }
            self?.diffView.scrollToFile(first.displayPath)
        }
        fileList.onToggleViewed = { [weak self] file in self?.toggleViewed([file]) }
        addSubview(fileList)

        diffView.translatesAutoresizingMaskIntoConstraints = false
        diffView.onSelectionChange = { [weak self] in self?.updateHint() }
        addSubview(diffView)

        message.placeholderString = "Commit message"
        message.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        message.controlSize = .small
        message.target = self
        message.action = #selector(commitClicked)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)

        commitButton.title = "Commit"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commitButton)

        for handle in [divider, listDivider] {
            handle.translatesAutoresizingMaskIntoConstraints = false
            addSubview(handle)
        }
        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width - delta)
        }
        listDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.listWidth.constant = min(max(self.listWidth.constant + delta, 170), 380)
        }

        // Wide enough for a file name and its folder without either of them
        // truncating on the common case, which 210 was not.
        listWidth = fileList.widthAnchor.constraint(equalToConstant: 244)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 6),

            status.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            hint.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            hint.leadingAnchor.constraint(
                greaterThanOrEqualTo: status.trailingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            topRule.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),

            fileList.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            fileList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            fileList.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            listWidth,

            listRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            listRule.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            listRule.leadingAnchor.constraint(equalTo: fileList.trailingAnchor),
            listRule.widthAnchor.constraint(equalToConstant: 1),

            listDivider.leadingAnchor.constraint(equalTo: fileList.trailingAnchor, constant: -3),
            listDivider.topAnchor.constraint(equalTo: fileList.topAnchor),
            listDivider.bottomAnchor.constraint(equalTo: fileList.bottomAnchor),
            listDivider.widthAnchor.constraint(equalToConstant: 6),

            diffView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: listRule.trailingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),

            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            message.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            message.trailingAnchor.constraint(
                equalTo: commitButton.leadingAnchor, constant: -8),

            commitButton.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            commitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        updateHint()
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: - Content

    func show(
        files: [GitDiff.File], root: String?, directory: String,
        preservingScroll: Bool = false
    ) {
        // A refresh nobody asked for, saying exactly what the last one said.
        // The watcher fires on any write under the working tree, and a build
        // writing to an ignored directory produces hundreds of those — each of
        // which used to rebuild and re-lay-out the whole document for a diff
        // that had not changed by a character.
        let sameRoot = self.root == (root ?? directory)
        if preservingScroll, sameRoot, files == self.files { return }

        self.files = files
        self.root = root ?? directory
        self.directory = directory
        redraw(preservingScroll: preservingScroll)
    }

    private func redraw(preservingScroll: Bool = false) {
        diffView.show(
            files, hidden: HiddenFiles.all(root: root), preservingScroll: preservingScroll)
        fileList.show(files, root: root)

        let added = files.reduce(0) { $0 + $1.addedCount }
        let removed = files.reduce(0) { $0 + $1.removedCount }
        let staged = files.filter(\.staged).count
        let name = (root as NSString).lastPathComponent
        status.stringValue = files.isEmpty
            ? "\(name) is clean"
            : "\(name) · \(files.count) file\(files.count == 1 ? "" : "s"), +\(added) −\(removed)"
                + (staged > 0 ? " · \(staged) staged" : "")
        commitButton.isEnabled = staged > 0
        updateHint()
    }

    func showMessage(_ text: String) {
        files = []
        diffView.show([])
        fileList.show([], root: root)
        status.stringValue = text
    }

    func goToHunk(_ delta: Int) { diffView.goToHunk(delta) }
    func moveInList(by delta: Int) { fileList.move(by: delta) }
    func takeFocus() {
        fileList.takeFocus()
        updateHint()
    }

    // MARK: - Doing things

    /// Space. Staged files come back out; everything else goes in — so the key
    /// is "move this across" rather than two keys you have to choose between.
    func toggleStageSelection() {
        let selected = fileList.selectedFiles
        guard !selected.isEmpty, !directory.isEmpty else { return }
        let paths = selected.map(\.displayPath)
        let allStaged = selected.allSatisfy { $0.staged && !$0.unstaged }
        do {
            if allStaged {
                try GitDiff.unstage(paths, in: directory)
            } else {
                try GitDiff.stage(paths, in: directory)
            }
            onNeedsReload?()
        } catch {
            status.stringValue = "git: \(error.localizedDescription)"
        }
    }

    /// Whether the keyboard is in the diff rather than the list, which is what
    /// decides whether `space` means this file or these lines.
    var isReadingDiff: Bool { diffView.isTextFocused }

    /// The keys that apply where you are, rather than every key there is.
    ///
    /// The list and the diff take different ones, and a single line of hints
    /// covering both is a line nobody reads. With a selection up it says what
    /// the selection is instead, because that is the question at that moment.
    func updateHint() {
        // With the list away there is nothing on screen that mentions the key
        // that brings it back, so the diff's hints say so until it returns.
        let sidebar = fileList.isHidden ? " · b sidebar" : ""
        if isReadingDiff {
            let lines = diffView.selectedLineCount
            hint.stringValue = (lines > 1
                ? "\(lines) lines · space stage · u unstage · s whole hunk"
                : "⇥ files · space stages the line · s the hunk · u unstages · h folds")
                + sidebar
        } else {
            hint.stringValue =
                "⇥ diff · space stage · v viewed · h fold · c commit · b sidebar"
        }
    }

    /// `b`: put the file list away. A diff read at full width is worth more
    /// than a list of eight names you have already read.
    func toggleSidebar() {
        let hiding = listWidth.constant > 0
        if hiding { listWidthBeforeHiding = listWidth.constant }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            listWidth.animator().constant = hiding ? 0 : listWidthBeforeHiding
            layoutSubtreeIfNeeded()
        }
        fileList.isHidden = hiding
        listDivider.isHidden = hiding
        if hiding, !isReadingDiff {
            window?.makeFirstResponder(diffView.focusTarget)
            diffView.prepareForFocus()
        }
        updateHint()
    }

    /// `s` / `S`: the hunk the caret is in, moved across or explicitly back.
    func stageHunk(reverse: Bool? = nil) {
        // Only in the diff. In the list the unit is the file, and `space`
        // already means that — a second key for it would be a second answer to
        // a question nobody asked twice.
        guard isReadingDiff, diffView.selectHunk() else { return }
        stageSelectedLines(reverse: reverse)
    }

    /// ⇥: across to the diff and back. The two halves take different keys, so
    /// there has to be a way to say which half you are in without the mouse.
    func switchSide() {
        // Nowhere to switch to with the list away, in either direction: the
        // keyboard must not land in a view that is not on screen.
        guard !fileList.isHidden else { return }
        let toDiff = !isReadingDiff
        window?.makeFirstResponder(toDiff ? diffView.focusTarget : fileList.focusTarget)
        if toDiff { diffView.prepareForFocus() }
        updateHint()
    }

    /// Stage — or unstage — whatever the selection in the diff covers.
    ///
    /// `space` moves the selection across, the same word it means in the file
    /// list: whatever is not staged gets staged, and if all of it is already
    /// staged it comes back out. One key, one idea, on both sides of the panel.
    /// `u` is the explicit way back for when you do not want to think about
    /// which way a toggle will go.
    func stageSelectedLines(reverse: Bool? = nil) {
        let changes = diffView.selectedChanges()
        let lines = changes.flatMap { change in
            change.hunks.flatMap { entry in
                entry.lines.sorted().compactMap { entry.hunk.lines[safe: $0] }
            }
        }.filter { $0.kind != .context }

        guard !lines.isEmpty else {
            status.stringValue = "That selection has no changes in it."
            return
        }
        // Nothing to decide when the caller already said which way.
        let staging = reverse.map { !$0 } ?? !lines.allSatisfy(\.staged)
        apply(changes, staging: staging)
    }

    /// Move the lines that can move, and leave the rest alone.
    ///
    /// A line already where it is going is dropped rather than sent again. It
    /// is not merely redundant: a patch describing a change the index already
    /// has does not apply, and git would refuse the whole thing — so selecting
    /// four lines with one already staged used to stage none of them.
    private func apply(
        _ changes: [(file: GitDiff.File, hunks: [(hunk: GitDiff.Hunk, lines: Set<Int>)])],
        staging: Bool
    ) {
        guard !directory.isEmpty else { return }

        var wanted: [(path: String, untracked: Bool,
                      lines: [(kind: GitDiff.Line.Kind, text: String)])] = []
        for change in changes {
            var picked: [(kind: GitDiff.Line.Kind, text: String)] = []
            for entry in change.hunks {
                for index in entry.lines.sorted() {
                    guard let line = entry.hunk.lines[safe: index], line.kind != .context,
                          line.staged != staging
                    else { continue }
                    picked.append((line.kind, line.text))
                }
            }
            if !picked.isEmpty {
                wanted.append((change.file.displayPath, change.file.untracked, picked))
            }
        }
        guard !wanted.isEmpty else {
            status.stringValue = staging
                ? "That is already staged."
                : "Nothing in that selection is staged."
            return
        }

        do {
            guard try GitDiff.move(wanted, staging: staging, in: directory) > 0 else {
                status.stringValue = "Could not find those lines in the index."
                return
            }
            onNeedsReload?()
        } catch {
            status.stringValue = "git: \(error.localizedDescription)"
        }
    }

    func toggleViewedSelection() { toggleViewed(fileList.selectedFiles) }

    /// `h`: fold a file's diff away, or bring it back.
    ///
    /// From the list it is the highlighted files; from the diff it is the file
    /// the caret is in, so the key means the same thing on either side without
    /// asking you to go and select the row first.
    func toggleHiddenSelection() {
        let files = isReadingDiff
            ? [diffView.fileAtCaret].compactMap { $0 }
            : fileList.selectedFiles
        guard !files.isEmpty else { return }
        HiddenFiles.toggle(files, root: root)
        redraw(preservingScroll: true)
    }

    private func toggleViewed(_ selected: [GitDiff.File]) {
        guard !selected.isEmpty else { return }
        for file in selected { ViewedFiles.toggle(file, root: root) }
        fileList.show(files, root: root)
    }

    func focusCommitMessage() { window?.makeFirstResponder(message) }

    @objc private func commitClicked() {
        guard !directory.isEmpty else { return }
        do {
            let summary = try GitDiff.commit(message: message.stringValue, in: directory)
            message.stringValue = ""
            ViewedFiles.clear(root: root)
            status.stringValue = summary
            onNeedsReload?()
        } catch {
            status.stringValue = "git: \(error.localizedDescription)"
        }
    }
}

/// A grab handle: a hairline you can pull.
final class DiffDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var origin: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onDrag?(x - origin)
    }

    override func mouseUp(with event: NSEvent) {
        origin = nil
    }
}
