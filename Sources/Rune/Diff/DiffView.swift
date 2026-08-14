import Cocoa

/// A rendered unified diff.
///
/// An `NSTextView` rather than a table of rows, and that is the whole design
/// decision. A diff is judged on the things AppKit gives a text view for
/// nothing — selecting across lines, copying, `⌘F`, scrolling that behaves —
/// and a table gets you virtualisation you do not need in exchange for
/// rewriting all of them.
///
/// Line numbers are a ruler rather than text in the document, so copying a
/// diff gives you the code and not a column of numbers down the left.
@MainActor
final class DiffView: NSView {
    private let scrollView = NSScrollView()
    private let textView: DiffTextView
    private let gutter = DiffGutter()

    /// Built by hand, and that is load-bearing.
    ///
    /// `NSTextView()` gives you a TextKit 2 view. The ruler asks it for
    /// `layoutManager` to find out where each line landed, and touching that
    /// property drags a TextKit 2 view part-way back to TextKit 1 — far enough
    /// that the ruler could enumerate line fragments and read the numbers off
    /// them, and not far enough for the view to draw a single glyph. The gutter
    /// rendered beside an empty column and the diff looked like it had found
    /// nothing.
    ///
    /// Handing it a container from a storage/layout stack built here makes it
    /// TextKit 1 from the start, so the ruler's question is an ordinary one.
    private static func makeTextView() -> DiffTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude))
        // Not width-tracking: a diff line is not prose and must not fold. A
        // wrapped line breaks mid-token, throws the gutter out of step with
        // what is on screen, and turns one change into two rows of rubble.
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return DiffTextView(frame: .zero, textContainer: container)
    }

    /// Where each hunk starts, as a character offset, for `n` and `p`.
    private var hunkOffsets: [Int] = []
    /// Where each file starts, so clicking a row in the list goes there.
    private var fileOffsets: [String: Int] = [:]
    private var currentHunk = -1

    /// One entry per rendered line: what the gutter shows for it.
    private var rows: [DiffGutter.Entry] = []
    /// One entry per rendered line: the band drawn behind it.
    private var fills: [DiffTextView.Fill] = []
    /// One entry per rendered line: which change it is, for staging a
    /// selection. Nil on headers and hunk markers, which are not lines of any
    /// file and cannot be staged.
    private var origins: [Origin?] = []
    private var lineStarts: [Int] = []
    private var shownFiles: [GitDiff.File] = []
    /// Which file each rendered line belongs to, headers included — `origins`
    /// cannot answer that, because a header is not a line of a file and `h`
    /// still has to work when the caret is parked on one.
    private var rowFiles: [Int] = []
    /// Row index to the stripe drawn down the side of it.
    private var accents: [Int: NSColor] = [:]

    /// Where a rendered line came from.
    struct Origin {
        let file: Int
        let hunk: Int
        let line: Int
    }

    /// The terminal's font unless Settings says otherwise, so the diff and the
    /// pane beside it are visibly the same application.
    @MainActor static var font: NSFont {
        let settings = Settings.shared
        let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty
        let base = settings.diffFontSize > 0
            ? settings.diffFontSize
            : (ghostty?.fontSize ?? 12)
        let size = max(8, min(36, base + settings.diffFontZoom))
        let name = settings.diffFontName.isEmpty
            ? (ghostty?.fontFamily ?? "")
            : settings.diffFontName
        if !name.isEmpty, let chosen = NSFont(name: name, size: size) { return chosen }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    override init(frame frameRect: NSRect) {
        self.textView = DiffView.makeTextView()
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // Room down both sides. Text against the panel's edge was most of why
        // this read as cut off rather than laid out.
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        // Built by hand, so the defaults `NSTextView(frame:)` would have set
        // are not there: without a maxSize the view cannot grow past its
        // initial frame, and a document that cannot grow to its content is a
        // document that shows none of it.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        gutter.textView = textView
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)

        // The gutter redraws when the document scrolls under it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
            }

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 74),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Content

    func show(
        _ files: [GitDiff.File], hidden: Set<String> = [], preservingScroll: Bool = false
    ) {
        let wasAt = scrollView.contentView.bounds.origin
        // The row rather than the character offset. Staging does not remove
        // lines from this view — it is a diff against HEAD, so a staged line
        // still shows — which makes the row index stable across the rebuild and
        // lets the caret stay on the line you were working down.
        let wasOn = preservingScroll && textView.selectedRange().length == 0
            ? line(containing: textView.selectedRange().location)
            : nil
        let text = NSMutableAttributedString()
        hunkOffsets = []
        fileOffsets = [:]
        rows = []
        fills = []
        origins = []
        accents = [:]
        rowFiles = []
        shownFiles = files
        currentHunk = -1

        for (fileIndex, file) in files.enumerated() {
            fileOffsets[file.displayPath] = text.length
            accents[rows.count] = file.tint
            let isHidden = hidden.contains(file.displayPath)
            text.append(header(for: file, hidden: isHidden))
            rows.append(.none)
            fills.append(.file)
            origins.append(nil)
            rowFiles.append(fileIndex)

            if isHidden {
                text.append(line("  ⋯ folded away, h shows it", .meta))
                rows.append(.none)
                fills.append(.none)
                origins.append(nil)
                rowFiles.append(fileIndex)
                continue
            }

            if file.isBinary {
                text.append(line("  Binary file — nothing to show", .meta))
                rows.append(.none)
                fills.append(.none)
                origins.append(nil)
                rowFiles.append(fileIndex)
                continue
            }

            let language = Syntax.language(forPath: file.displayPath)
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                hunkOffsets.append(text.length)
                text.append(line(hunk.header, .hunk))
                rows.append(.none)
                fills.append(.hunk)
                origins.append(nil)
                rowFiles.append(fileIndex)

                for (lineIndex, row) in hunk.lines.enumerated() {
                    text.append(line(
                        marker(row.kind) + row.text, style(row.kind),
                        code: row.text, language: language))
                    rows.append(.numbers(old: row.oldNumber, new: row.newNumber))
                    switch (row.kind, row.staged) {
                    case (.added, false): fills.append(.added)
                    case (.added, true): fills.append(.addedStaged)
                    case (.removed, false): fills.append(.removed)
                    case (.removed, true): fills.append(.removedStaged)
                    case (.context, _): fills.append(.none)
                    }
                    origins.append(Origin(file: fileIndex, hunk: hunkIndex, line: lineIndex))
                    rowFiles.append(fileIndex)
                }
            }
        }

        if files.isEmpty {
            text.append(line("Nothing to show. The working tree is clean.", .meta))
            rows.append(.none)
            fills.append(.none)
            origins.append(nil)
        }

        // Batched, so the layout manager invalidates once instead of reacting
        // to the storage emptying and then filling again — the second half of
        // why a stage looked like a flash rather than an edit.
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(text)
        textView.textStorage?.endEditing()
        let starts = Self.lineStarts(in: text.string)
        lineStarts = starts
        textView.fills = fills
        textView.accents = accents
        textView.lineStarts = starts
        textView.needsDisplay = true
        gutter.entries = rows
        gutter.fills = fills
        gutter.accents = accents
        gutter.lineStarts = starts
        gutter.needsDisplay = true
        // Laid out either way: restoring an offset needs the document to be
        // its real size first, and scrolling to the top needs the same before
        // anything else asks where the top is.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.scroll(preservingScroll ? wasAt : .zero)

        if let wasOn, let start = lineStarts[safe: wasOn] {
            textView.setSelectedRange(NSRange(location: start, length: 0))
        }
        refreshCurrentRow()

    }

    private func marker(_ kind: GitDiff.Line.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }

    /// The offset of every line, so the ruler can map a fragment back to the
    /// row it belongs to without rescanning the document each time it draws.
    private static func lineStarts(in string: String) -> [Int] {
        var starts = [0]
        for (index, character) in string.utf16.enumerated() where character == 10 {
            starts.append(index + 1)
        }
        return starts
    }

    // MARK: - Styling

    private enum Style { case context, added, removed, hunk, file, meta }

    private func style(_ kind: GitDiff.Line.Kind) -> Style {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .context: .context
        }
    }

    /// The row that introduces a file.
    ///
    /// Built by hand rather than through `line()` because it is the one row
    /// that is not a line of code: a path in three weights reads as a heading,
    /// and the same path in one monospaced grey run reads as more diff. The
    /// folder is dimmed, the name carries the weight, the counts take the
    /// colours they mean, and what git thinks of the file is a tag on the end.
    private func header(for file: GitDiff.File, hidden: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        // Air above each header, so files read as blocks rather than as one
        // scroll. Not below: the `@@` line under it belongs to it.
        paragraph.paragraphSpacingBefore = 10
        paragraph.paragraphSpacing = 2

        let text = NSMutableAttributedString()
        func append(_ body: String, _ font: NSFont, _ colour: NSColor) {
            guard !body.isEmpty else { return }
            text.append(NSAttributedString(string: body, attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: paragraph,
            ]))
        }

        let full = file.displayPath as NSString
        let folder = full.deletingLastPathComponent
        append(folder.isEmpty ? "" : folder + "/", .systemFont(ofSize: 11), .tertiaryLabelColor)
        append(full.lastPathComponent, .systemFont(ofSize: 12.5, weight: .semibold), .labelColor)

        if !file.isBinary {
            append("   +\(file.addedCount)", .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                   file.addedCount > 0 ? .systemGreen : .quaternaryLabelColor)
            append(" −\(file.removedCount)", .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                   file.removedCount > 0 ? .systemRed : .quaternaryLabelColor)
        }

        var tags: [String] = []
        if file.untracked { tags.append("new file") }
        else if file.oldPath == nil { tags.append("added") }
        if file.newPath == nil { tags.append("deleted") }
        if file.isRename, let old = file.oldPath { tags.append("was \((old as NSString).lastPathComponent)") }
        if file.isBinary { tags.append("binary") }
        if file.staged { tags.append(file.unstaged ? "partly staged" : "staged") }
        if hidden { tags.append("hidden") }
        append("   " + tags.joined(separator: " · "), .systemFont(ofSize: 10), .tertiaryLabelColor)

        text.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: paragraph,
        ]))
        return text
    }

    /// `code` is the line without its `+`/`-` marker, and the offset of the
    /// marker is what the syntax spans have to be shifted by.
    private func line(
        _ body: String, _ style: Style,
        code: String? = nil, language: Syntax.Language = .none
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        // A little air between rows. A diff read at the terminal's own line
        // height is a solid block of text, and the bands behind it have no room
        // to read as separate rows.
        paragraph.lineHeightMultiple = 1.15

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: paragraph,
        ]

        let theme = DiffTheme.current
        switch style {
        case .context:
            attributes[.foregroundColor] = theme.contextText
        // No `.backgroundColor` on any of these: an attribute run is only as
        // wide as its glyphs, so every changed line ended in mid-air with the
        // panel's background beyond it. The bands are drawn full-width by
        // `DiffTextView` instead.
        case .added:
            attributes[.foregroundColor] = theme.changedText(added: true)
        case .removed:
            attributes[.foregroundColor] = theme.changedText(added: false)
        case .hunk:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .file:
            attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
            attributes[.foregroundColor] = NSColor.labelColor
        case .meta:
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        let result = NSMutableAttributedString(string: body + "\n", attributes: attributes)

        // Syntax over the top, and only over the code — the marker column keeps
        // the diff's own colour so `+` and `-` stay readable at a glance.
        if let code, !code.isEmpty, theme.highlightsSyntax {
            let offset = (body as NSString).length - (code as NSString).length
            for (range, token) in Syntax.spans(in: code, language: language) {
                guard let colour = token.color(in: theme) else { continue }
                let shifted = NSRange(location: range.location + offset, length: range.length)
                guard shifted.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: colour, range: shifted)
            }
        }
        return result
    }

    // MARK: - Moving

    /// `n` and `p`. Hunk by hunk rather than line by line, because a hunk is
    /// the unit you actually review in.
    func goToHunk(_ delta: Int) {
        guard !hunkOffsets.isEmpty else { return }
        currentHunk = max(0, min(hunkOffsets.count - 1, currentHunk + delta))
        let offset = hunkOffsets[currentHunk]
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }



    func scrollToFile(_ path: String) {
        guard let offset = fileOffsets[path] else { return }
        // The document may have been set microseconds ago, in which case none
        // of it has been laid out and every question about where a character
        // sits answers zero — which is how a jump to the first file landed in
        // the middle of the second.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        // To the top of the view rather than merely into it: a file header
        // scrolled to the bottom edge is technically visible and useless.
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count - 1, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }

    /// What the caret or the selection covers, grouped into one entry per hunk.
    ///
    /// A caret with nothing selected counts as the line it is sitting on, so
    /// staging one line is a keystroke rather than a drag — which is how you
    /// actually do it when you are reading downwards.
    func selectedChanges() -> [(file: GitDiff.File, hunks: [(hunk: GitDiff.Hunk, lines: Set<Int>)])] {
        let range = textView.selectedRange()
        let first = line(containing: range.location) ?? 0
        let last = range.length > 0
            ? (line(containing: max(range.location, range.upperBound - 1)) ?? first)
            : first

        // Kept in the order they appear, so a patch reads down the file the way
        // the diff on screen does.
        var order: [Int] = []
        var byFile: [Int: [(hunk: Int, lines: Set<Int>)]] = [:]
        for row in first...max(first, last) {
            guard let origin = origins[safe: row] ?? nil else { continue }
            if byFile[origin.file] == nil {
                byFile[origin.file] = []
                order.append(origin.file)
            }
            if let index = byFile[origin.file]?.firstIndex(where: { $0.hunk == origin.hunk }) {
                byFile[origin.file]?[index].lines.insert(origin.line)
            } else {
                byFile[origin.file]?.append((origin.hunk, [origin.line]))
            }
        }

        return order.compactMap { fileIndex in
            guard let file = shownFiles[safe: fileIndex], let entries = byFile[fileIndex] else {
                return nil
            }
            let hunks = entries.compactMap { entry -> (hunk: GitDiff.Hunk, lines: Set<Int>)? in
                guard let hunk = file.hunks[safe: entry.hunk] else { return nil }
                return (hunk, entry.lines)
            }
            return hunks.isEmpty ? nil : (file, hunks)
        }
    }

    /// Whether the keyboard is in the diff text rather than the file list, which
    /// is what decides whether a key means "this selection" or "this file".
    var isTextFocused: Bool { window?.firstResponder === textView }

    var focusTarget: NSView { textView }

    /// The file the caret is somewhere inside, header row included.
    var fileAtCaret: GitDiff.File? {
        guard let row = line(containing: textView.selectedRange().location),
              let index = rowFiles[safe: row]
        else { return nil }
        return shownFiles[safe: index]
    }

    /// Put the caret somewhere worth staging.
    ///
    /// Called when the diff takes the keyboard: landing at offset zero puts it
    /// on a file header, which is not a line anything can be done to, so the
    /// panel would look inert at exactly the moment it became active.
    func prepareForFocus() {
        guard textView.selectedRange().length == 0,
              (origins[safe: line(containing: textView.selectedRange().location) ?? 0] ?? nil) == nil
        else {
            refreshCurrentRow()
            return
        }
        // The first *changed* line, not merely the first line that belongs to a
        // hunk: landing on a context line puts the caret somewhere `space`
        // would decline to act on, which reads as the key being broken.
        let changed = fills.firstIndex(where: \.isChange)
        guard let row = changed ?? origins.firstIndex(where: { $0 != nil }),
              let start = lineStarts[safe: row]
        else { return }
        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        refreshCurrentRow()
    }

    /// The row the caret is on, but only when it is a line that can be staged.
    private func refreshCurrentRow() {
        let range = textView.selectedRange()
        var row: Int?
        if range.length == 0, let candidate = line(containing: range.location),
           (origins[safe: candidate] ?? nil) != nil {
            row = candidate
        }
        guard row != textView.currentRow else { return }
        textView.currentRow = row
        gutter.currentRow = row
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    /// Told when the selection moves, so the panel can say what a key would do
    /// to it.
    var onSelectionChange: (() -> Void)?

    /// How many changed lines the selection covers. Context lines do not count
    /// — staging them is a no-op, and counting them would promise more than the
    /// key delivers.
    /// Whether every changed line in the selection is already in the index,
    /// which is what decides which way `space` will go.
    var selectionIsAllStaged: Bool {
        let lines = selectedChanges().flatMap { change in
            change.hunks.flatMap { entry in
                entry.lines.compactMap { entry.hunk.lines[safe: $0] }
            }
        }.filter { $0.kind != .context }
        return !lines.isEmpty && lines.allSatisfy(\.staged)
    }

    var selectedLineCount: Int {
        selectedChanges().reduce(0) { total, change in
            total + change.hunks.reduce(0) { $0 + $1.lines.count }
        }
    }

    /// Grow the selection to the whole hunk the caret is in.
    ///
    /// Staging a hunk is the common case, and doing it by dragging from the
    /// `@@` line to the last `+` is work. This selects it first and stages
    /// second, so the thing that is about to happen is on screen before it does.
    @discardableResult
    func selectHunk() -> Bool {
        let caret = line(containing: textView.selectedRange().location) ?? 0
        // A caret parked on a header or a `@@` line means the hunk below it.
        var anchor = caret
        while anchor < origins.count, (origins[safe: anchor] ?? nil) == nil { anchor += 1 }
        guard let origin = origins[safe: anchor] ?? nil else { return false }

        func belongs(_ row: Int) -> Bool {
            guard let other = origins[safe: row] ?? nil else { return false }
            return other.file == origin.file && other.hunk == origin.hunk
        }
        var first = anchor
        while first > 0, belongs(first - 1) { first -= 1 }
        var last = anchor
        while last + 1 < origins.count, belongs(last + 1) { last += 1 }

        guard let start = lineStarts[safe: first] else { return false }
        let end = lineStarts[safe: last + 1] ?? (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start - 1)))
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        return true
    }

    private func line(containing offset: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "n", "j": goToHunk(1)
        case "p", "k": goToHunk(-1)
        default: super.keyDown(with: event)
        }
    }
}

extension DiffView: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        refreshCurrentRow()
        onSelectionChange?()
    }
}

/// The document, with the row bands drawn behind the text.
///
/// A `.backgroundColor` attribute paints the glyphs' own extent and stops. On
/// prose that is what you want; on a diff it means a two-character line gets a
/// two-character stripe of green and the rest of the row is panel background,
/// which is most of why this read as chopped. Every other diff — delta, hunk,
/// lazygit — fills the row edge to edge, so this draws the bands itself,
/// underneath the text and across the full document width.
@MainActor
final class DiffTextView: NSTextView {
    enum Fill {
        case none, added, removed, addedStaged, removedStaged, hunk, file

        /// Whether this row is a line you could stage or unstage.
        var isChange: Bool {
            switch self {
            case .added, .removed, .addedStaged, .removedStaged: true
            case .none, .hunk, .file: false
            }
        }

        var isStaged: Bool {
            switch self {
            case .addedStaged, .removedStaged: true
            default: false
            }
        }

        var isAddition: Bool {
            switch self {
            case .added, .addedStaged: true
            default: false
            }
        }
    }

    /// One per line of the document, in order.
    var fills: [Fill] = []
    /// Row index to the stripe drawn down the side of it.
    var accents: [Int: NSColor] = [:]
    /// UTF-16 offset of each line, ascending.
    var lineStarts: [Int] = []
    /// The line `space` would stage. Nil when the caret is not on one.
    var currentRow: Int?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !fills.isEmpty,
              let layout = layoutManager,
              let container = textContainer
        else { return }

        let inset = textContainerInset
        let theme = DiffTheme.current
        // The width of the band, not of the text: bands run to the edge of what
        // is on screen even when the document is narrower than the panel.
        let width = max(bounds.width, visibleRect.maxX)

        let query = rect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphs = layout.glyphRange(forBoundingRect: query, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) {
            fragment, _, _, glyphRange, _ in
            let index = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let row = self.line(containing: index),
                  let fill = self.fills[safe: row], fill != .none
            else { return }

            let band = NSRect(
                x: 0, y: fragment.minY + inset.height,
                width: width, height: fragment.height)

            switch fill {
            case .added: theme.addedBackground.setFill()
            case .removed: theme.removedBackground.setFill()
            case .addedStaged: theme.stagedBackground(added: true).setFill()
            case .removedStaged: theme.stagedBackground(added: false).setFill()
            case .hunk: NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            case .file: NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
            case .none: return
            }
            band.fill()

            // A file starts with a rule above it. Without one the headers ran
            // together with the last line of the file before them.
            if fill == .file {
                NSColor.separatorColor.setFill()
                NSRect(x: 0, y: band.minY, width: width, height: 1).fill()
            }
            // Where the caret is, which in a view you cannot type into is
            // otherwise invisible — and an invisible caret is an invisible
            // answer to "which line would `space` stage?".
            if row == self.currentRow {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                band.fill()
            }

            // A stripe down the inside edge of a changed row, so which side a
            // line is on survives a colourblind reading and a pale theme. On a
            // header it is the file's own colour — the same one its dot has in
            // the list, so the two halves of the panel agree.
            if let accent = self.accents[row] {
                accent.withAlphaComponent(0.9).setFill()
                NSRect(x: 0, y: band.minY, width: 3, height: band.height).fill()
            } else if fill.isStaged {
                theme.stagedStripe.setFill()
                NSRect(x: 0, y: band.minY, width: 2, height: band.height).fill()
            } else if fill.isChange {
                theme.changedText(added: fill.isAddition).withAlphaComponent(0.55).setFill()
                NSRect(x: 0, y: band.minY, width: 2, height: band.height).fill()
            }
        }
    }

    /// Which line a character offset falls in.
    private func line(containing offset: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// The gutter: old and new line numbers, drawn beside the text.
///
/// A plain view rather than an `NSRulerView`. The ruler drew its numbers
/// perfectly and stopped the text view drawing at all — the scroll view
/// compensated for the rule thickness by shifting its clip view's bounds origin
/// to -62 instead of insetting its frame, and the document never appeared.
/// Three attempts at making the ruler behave all left the gutter beside an
/// empty column, so the ruler is gone and this draws in its own space, beside
/// the scroll view rather than inside it.
///
/// The numbers still are not text in the document, which is the point: copying
/// a diff gives you the code.
@MainActor
final class DiffGutter: NSView {
    enum Entry {
        /// A header or a hunk marker, which is not a line of any file.
        case none
        case numbers(old: Int?, new: Int?)
    }

    weak var textView: NSTextView?
    var entries: [Entry] = []
    /// The band behind each line, so a changed row reads as one row across the
    /// seam instead of stopping dead where the numbers end.
    var fills: [DiffTextView.Fill] = []
    /// Row index to the stripe drawn down the side of it.
    var accents: [Int: NSColor] = [:]
    /// UTF-16 offset of each line, ascending.
    var lineStarts: [Int] = []
    /// The line `space` would stage.
    var currentRow: Int?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A shade off the text's background, and nothing else. There used to be
        // a hairline down the inside edge; once the row bands crossed it, it
        // was a bright line ruled through the middle of every row rather than a
        // boundary between two columns.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
        bounds.fill()

        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let theme = DiffTheme.current

        let visible = clip.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let inset = textView.textContainerInset.height

        layout.enumerateLineFragments(forGlyphRange: glyphs) {
            fragment, usedRect, _, glyphRange, _ in
            let characterIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let row = self.line(containing: characterIndex) else { return }
            // Only the first fragment of a wrapped line carries a number; the
            // continuations are the same line, and numbering them twice would
            // be a lie about how many lines there are.
            guard self.lineStarts[row] == characterIndex else { return }

            let y = usedRect.minY + inset - visible.minY
            guard y > -20, y < self.bounds.height else { return }

            // Every band the text carries, the gutter carries too — headers
            // and hunk markers included, which is why this runs before the
            // numbers are asked for. Those rows have no numbers, and returning
            // early on them left each header sawn off at the seam.
            let fill = self.fills[safe: row] ?? DiffTextView.Fill.none
            switch fill {
            case .added: theme.addedBackground.setFill()
            case .removed: theme.removedBackground.setFill()
            case .addedStaged: theme.stagedBackground(added: true).setFill()
            case .removedStaged: theme.stagedBackground(added: false).setFill()
            case .hunk: NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            case .file: NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
            case .none: NSColor.clear.setFill()
            }
            // The fragment rather than the used rect, and over the seam rather
            // than up to it: the text side bands the whole fragment, including
            // the space above a header, and a gutter that banded only the glyphs
            // would leave a step at every heading.
            let bandY = fragment.minY + inset - visible.minY
            NSRect(x: 0, y: bandY, width: self.bounds.width, height: fragment.height).fill()

            if row == self.currentRow {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSRect(x: 0, y: bandY, width: self.bounds.width, height: fragment.height).fill()
                // A solid nib at the very edge of the panel, so the current
                // line is findable without hunting for a tint.
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: bandY, width: 3, height: fragment.height).fill()
            } else if let accent = self.accents[row] {
                accent.withAlphaComponent(0.9).setFill()
                NSRect(x: 0, y: bandY, width: 3, height: fragment.height).fill()
            } else if fill.isStaged {
                // The one mark that says "this is in the index", at the edge of
                // the panel where a column of them reads as a run.
                theme.stagedStripe.setFill()
                NSRect(x: 0, y: bandY, width: 3, height: fragment.height).fill()
            }

            guard case .numbers(let old, let new) = self.entries[safe: row] ?? .none else { return }
            // Right-aligned in two columns rather than one padded string: at
            // four digits the second column ran off the end of the gutter and
            // showed "64  6" where it meant "64  64".
            Self.draw(old, rightEdgeAt: 32, y: y, attributes: attributes)
            Self.draw(new, rightEdgeAt: 64, y: y, attributes: attributes)
        }
    }

    private static func draw(
        _ value: Int?, rightEdgeAt x: CGFloat, y: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let text = (value.map(String.init) ?? "·") as NSString
        let width = text.size(withAttributes: attributes).width
        text.draw(at: NSPoint(x: x - width, y: y), withAttributes: attributes)
    }

    /// Which line a character offset falls in. Binary search, because this runs
    /// for every visible fragment on every scroll.
    private func line(containing offset: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
