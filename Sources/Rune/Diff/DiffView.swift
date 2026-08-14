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
    private let textView: NSTextView
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
    private static func makeTextView() -> NSTextView {
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
        return NSTextView(frame: .zero, textContainer: container)
    }

    /// Where each hunk starts, as a character offset, for `n` and `p`.
    private var hunkOffsets: [Int] = []
    private var currentHunk = -1

    /// One entry per rendered line: what the gutter shows for it.
    private var rows: [DiffGutter.Entry] = []

    /// The terminal's font unless Settings says otherwise, so the diff and the
    /// pane beside it are visibly the same application.
    @MainActor static var font: NSFont {
        let settings = Settings.shared
        let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty
        let size = settings.diffFontSize > 0
            ? settings.diffFontSize
            : (ghostty?.fontSize ?? 12)
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
            gutter.widthAnchor.constraint(equalToConstant: 78),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Content

    func show(_ files: [GitDiff.File]) {
        let text = NSMutableAttributedString()
        hunkOffsets = []
        rows = []
        currentHunk = -1

        for file in files {
            text.append(header(for: file))
            rows.append(.none)

            if file.isBinary {
                text.append(line("  Binary file — nothing to show", .meta))
                rows.append(.none)
                continue
            }

            let language = Syntax.language(forPath: file.displayPath)
            for hunk in file.hunks {
                hunkOffsets.append(text.length)
                text.append(line(hunk.header, .hunk))
                rows.append(.none)

                for row in hunk.lines {
                    text.append(line(
                        marker(row.kind) + row.text, style(row.kind),
                        code: row.text, language: language))
                    rows.append(.numbers(old: row.oldNumber, new: row.newNumber))
                }
            }
        }

        if files.isEmpty {
            text.append(line("Nothing to show. The working tree is clean.", .meta))
            rows.append(.none)
        }

        textView.textStorage?.setAttributedString(text)
        gutter.entries = rows
        gutter.lineStarts = Self.lineStarts(in: text.string)
        gutter.needsDisplay = true
        textView.scroll(.zero)

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

    private func header(for file: GitDiff.File) -> NSAttributedString {
        var name = file.displayPath
        if file.isRename, let old = file.oldPath { name = "\(old) → \(file.displayPath)" }
        if file.oldPath == nil { name += "  (new)" }
        if file.newPath == nil { name += "  (deleted)" }
        let counts = file.isBinary ? "" : "   +\(file.addedCount) −\(file.removedCount)"
        return line(name + counts, .file)
    }

    /// `code` is the line without its `+`/`-` marker, and the offset of the
    /// marker is what the syntax spans have to be shifted by.
    private func line(
        _ body: String, _ style: Style,
        code: String? = nil, language: Syntax.Language = .none
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: paragraph,
        ]

        let theme = DiffTheme.current
        switch style {
        case .context:
            attributes[.foregroundColor] = theme.contextText
        case .added:
            attributes[.foregroundColor] = theme.changedText(added: true)
            attributes[.backgroundColor] = theme.addedBackground
        case .removed:
            attributes[.foregroundColor] = theme.changedText(added: false)
            attributes[.backgroundColor] = theme.removedBackground
        case .hunk:
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.07)
        case .file:
            attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
            attributes[.foregroundColor] = NSColor.labelColor
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.16)
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



    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "n", "j": goToHunk(1)
        case "p", "k": goToHunk(-1)
        default: super.keyDown(with: event)
        }
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
    /// UTF-16 offset of each line, ascending.
    var lineStarts: [Int] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
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

        let visible = clip.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let inset = textView.textContainerInset.height

        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, glyphRange, _ in
            let characterIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let row = self.line(containing: characterIndex) else { return }
            // Only the first fragment of a wrapped line carries a number; the
            // continuations are the same line, and numbering them twice would
            // be a lie about how many lines there are.
            guard self.lineStarts[row] == characterIndex else { return }
            guard case .numbers(let old, let new) = self.entries[safe: row] ?? .none else { return }

            let y = usedRect.minY + inset - visible.minY
            guard y > -20, y < self.bounds.height else { return }
            // Right-aligned in two columns rather than one padded string: at
            // four digits the second column ran off the end of the gutter and
            // showed "64  6" where it meant "64  64".
            Self.draw(old, rightEdgeAt: 34, y: y, attributes: attributes)
            Self.draw(new, rightEdgeAt: 70, y: y, attributes: attributes)
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
