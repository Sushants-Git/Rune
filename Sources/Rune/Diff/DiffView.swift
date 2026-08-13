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
    private let textView = NSTextView()
    private let ruler: DiffRuler

    /// Where each hunk starts, as a character offset, for `n` and `p`.
    private var hunkOffsets: [Int] = []
    private var currentHunk = -1

    /// One entry per rendered line: what the gutter shows for it.
    private var gutter: [DiffRuler.Entry] = []

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame frameRect: NSRect) {
        ruler = DiffRuler(scrollView: nil, orientation: .verticalRuler)
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
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        ruler.scrollView = scrollView
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Content

    func show(_ files: [GitDiff.File]) {
        let text = NSMutableAttributedString()
        hunkOffsets = []
        gutter = []
        currentHunk = -1

        for file in files {
            text.append(header(for: file))
            gutter.append(.none)

            if file.isBinary {
                text.append(line("  Binary file — nothing to show", .meta))
                gutter.append(.none)
                continue
            }

            for hunk in file.hunks {
                hunkOffsets.append(text.length)
                text.append(line(hunk.header, .hunk))
                gutter.append(.none)

                for row in hunk.lines {
                    text.append(line(marker(row.kind) + row.text, style(row.kind)))
                    gutter.append(.numbers(old: row.oldNumber, new: row.newNumber))
                }
            }
        }

        if files.isEmpty {
            text.append(line("Nothing to show. The working tree is clean.", .meta))
            gutter.append(.none)
        }

        textView.textStorage?.setAttributedString(text)
        ruler.entries = gutter
        ruler.lineStarts = Self.lineStarts(in: text.string)
        ruler.ruleThickness = 62
        ruler.needsDisplay = true
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

    private func line(_ body: String, _ style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        // A wrapped continuation lines up under the text rather than under the
        // marker, so a long line reads as one line rather than as a new row.
        paragraph.headIndent = 18

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: paragraph,
        ]

        switch style {
        case .context:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .added:
            attributes[.foregroundColor] = NSColor.labelColor
            attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.16)
        case .removed:
            attributes[.foregroundColor] = NSColor.labelColor
            attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.16)
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
        return NSAttributedString(string: body + "\n", attributes: attributes)
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

/// The gutter: old and new line numbers, drawn beside the text rather than in
/// it.
@MainActor
final class DiffRuler: NSRulerView {
    enum Entry {
        /// A header or a hunk marker, which is not a line of any file.
        case none
        case numbers(old: Int?, new: Int?)
    }

    var entries: [Entry] = []
    /// UTF-16 offset of each line, ascending.
    var lineStarts: [Int] = []

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        NSColor.textBackgroundColor.setFill()
        rect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let visible = scrollView?.contentView.bounds ?? .zero
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let inset = textView.textContainerInset.height

        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, glyphRange, _ in
            let characterIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let row = self.line(containing: characterIndex) else { return }
            // Only the first fragment of a wrapped line carries the number; the
            // continuations are the same line and numbering them twice would be
            // a lie about how many lines there are.
            guard self.lineStarts[row] == characterIndex else { return }
            guard case .numbers(let old, let new) = self.entries[safe: row] ?? .none else { return }

            let y = usedRect.minY + inset - visible.minY
            let text = "\(Self.pad(old))\(Self.pad(new))" as NSString
            text.draw(at: NSPoint(x: 4, y: y), withAttributes: attributes)
        }
    }

    private static func pad(_ value: Int?) -> String {
        let text = value.map(String.init) ?? "·"
        return String(repeating: " ", count: max(0, 5 - text.count)) + text
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
