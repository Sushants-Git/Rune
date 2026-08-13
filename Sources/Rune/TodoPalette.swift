import Cocoa

/// The todo list, in the switcher's panel.
///
/// The same surface as `⌘K` and deliberately so: it is the panel Rune already
/// has, drawn with the same glass, the same rows and the same hint bar, showing
/// a different list. A second window with its own shape would be a second thing
/// to learn and a second thing to position.
///
/// Unlike `⌘K` it is not a search field with a list under it. `⌘K` exists to
/// filter, so the keyboard belongs in the field; this exists to *read* and act
/// on what you find, so the list holds the keyboard and single keys do things:
/// `a` adds, `A` adds underneath, `c` copies, `⏎` ticks off. Typing only starts
/// when you ask for it, and stops as soon as the line is in.
@MainActor
final class TodoPalette: NSView, OverlayPanel {
    /// What the panel is doing: reading the list, or taking a line for it.
    private enum Mode: Equatable {
        case list
        /// Adding, with the task the new one goes under, or nil for a root.
        case adding(under: UUID?)
    }

    private let field = NSTextField()
    private let onDismiss: () -> Void

    /// The list normally, the field while a line is being typed.
    ///
    /// Computed rather than fixed: the window hands the keyboard back to this
    /// after a trip to another app, and handing it to the list mid-sentence
    /// would eat the sentence.
    var focusView: NSView {
        if case .adding = mode { return field }
        return self
    }

    private let store = TodoStore.shared
    private var rows: [TodoStore.Row] = []
    private var selection = 0
    private var mode: Mode = .list { didSet { applyMode() } }

    private let panel = NSView()
    private let title = NSTextField(labelWithString: "Todo")
    private let count = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing to do. Press a to add one.")
    private let hints = NSStackView()
    private var scrollHeight: NSLayoutConstraint!

    static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 34
    private static let maxVisibleRows = 10
    private static let cornerRadius: CGFloat = 12

    private let backdrop = SwitcherPalette.makeBackdrop(cornerRadius: cornerRadius)
    private let scrim = NSView()
    private let grip = PanelGrip()

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        build()
        refresh()
        applyMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func cancel() {
        onDismiss()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Chrome

    private func build() {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.clear.cgColor
        panel.layer?.cornerRadius = Self.cornerRadius
        panel.layer?.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(backdrop, positioned: .below, relativeTo: nil)

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = PaletteStyle.scrim.cgColor
        scrim.layer?.cornerRadius = Self.cornerRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.layer?.borderWidth = 1
        scrim.layer?.borderColor = PaletteStyle.border.cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrim, positioned: .above, relativeTo: backdrop)

        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.55
        panel.layer?.shadowRadius = 40
        panel.layer?.shadowOffset = CGSize(width: 0, height: -10)
        panel.layer?.masksToBounds = false

        // The header is a title until you press `a`, and the field takes its
        // place rather than appearing beneath it — so the panel never changes
        // height just because you started typing.
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = PaletteStyle.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        count.font = .systemFont(ofSize: 11)
        count.textColor = PaletteStyle.tertiaryText
        count.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(count)

        field.font = .systemFont(ofSize: 13)
        field.textColor = PaletteStyle.primaryText
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.isHidden = true
        field.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(field)

        grip.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(grip)

        let headerDivider = Divider()
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(headerDivider)

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("todo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: SwitcherPalette.rowInset, left: 0,
            bottom: SwitcherPalette.rowInset, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = PaletteStyle.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyLabel)

        let footerDivider = Divider()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(footerDivider)

        hints.orientation = .horizontal
        hints.spacing = 13
        hints.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hints)

        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)

        let inset = SwitcherPalette.contentInset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),

            backdrop.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: panel.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: panel.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),

            count.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),

            field.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),

            grip.topAnchor.constraint(equalTo: panel.topAnchor),
            grip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            grip.bottomAnchor.constraint(equalTo: title.bottomAnchor, constant: 13),

            headerDivider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 13),
            headerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: SwitcherPalette.rowInset),
            scrollView.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -SwitcherPalette.rowInset),
            scrollHeight,

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerDivider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9),
            hints.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            hints.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -9),
        ])
    }

    /// The hint bar says what the keys do *now*, because in this panel that
    /// changes: in the list they are commands, and in the field they are text.
    private func setHints(_ pairs: [(String, String)]) {
        hints.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, label) in pairs {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10.5)
            text.textColor = PaletteStyle.tertiaryText
            let pair = NSStackView(views: [Keycap(key), text])
            pair.orientation = .horizontal
            pair.spacing = 5
            hints.addArrangedSubview(pair)
        }
    }

    private func applyMode() {
        switch mode {
        case .list:
            field.isHidden = true
            field.stringValue = ""
            title.isHidden = false
            count.isHidden = false
            setHints([
                ("a", "Add"), ("A", "Sub-task"), ("c", "Copy"),
                ("⏎", "Done"), ("⌫", "Delete"), ("esc", "Dismiss"),
            ])
            window?.makeFirstResponder(self)
        case .adding(let parent):
            let under = parent.flatMap { id in store.items.first { $0.id == id }?.text }
            field.placeholderAttributedString = NSAttributedString(
                string: under.map { "New task under \($0)" } ?? "New task",
                attributes: [
                    .foregroundColor: PaletteStyle.tertiaryText,
                    .font: NSFont.systemFont(ofSize: 13),
                ])
            field.isHidden = false
            title.isHidden = true
            count.isHidden = true
            setHints([("⏎", "Save"), ("esc", "Cancel")])
            window?.makeFirstResponder(field)
        }
    }

    // MARK: - List

    private func refresh() {
        rows = store.rows
        selection = min(max(selection, 0), max(rows.count - 1, 0))

        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        scrollView.isHidden = rows.isEmpty

        let visible = min(rows.count, Self.maxVisibleRows)
        scrollHeight.constant = rows.isEmpty
            ? 44
            : CGFloat(visible) * Self.rowHeight + SwitcherPalette.rowInset * 2

        let left = store.remaining
        count.stringValue = left == 0
            ? (store.items.isEmpty ? "" : "all done")
            : "\(left) left"

        syncSelection()
    }

    private func syncSelection() {
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    private var selected: TodoStore.Row? { rows[safe: selection] }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta % rows.count + rows.count) % rows.count
        syncSelection()
    }

    // MARK: - Doing things

    private func toggleSelected() {
        guard let row = selected else { return }
        store.toggle(row.item.id)
        refresh()
    }

    func deleteSelected() {
        guard let row = selected else { return }
        store.remove(row.item.id)
        refresh()
    }

    private func copySelected() {
        guard let row = selected, let text = store.copyText(for: row.item.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func commitAdd() {
        guard case .adding(let parent) = mode else { return }
        let typed = field.stringValue
        store.add(typed, parent: parent)
        refresh()
        // Land on what was just added, so the next thing you do lands on it.
        if let index = rows.lastIndex(where: {
            $0.item.text == typed.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            selection = index
        }
        mode = .list
        syncSelection()
    }

    @objc private func rowClicked() {
        guard rows.indices.contains(tableView.clickedRow) else { return }
        selection = tableView.clickedRow
        toggleSelected()
    }

    // MARK: - Keys

    /// Single keys, because the list holds the keyboard rather than a field.
    override func keyDown(with event: NSEvent) {
        guard case .list = mode else { return super.keyDown(with: event) }

        switch event.keyCode {
        case 126: move(by: -1); return          // ↑
        case 125: move(by: 1); return           // ↓
        case 36: toggleSelected(); return       // ⏎
        case 51, 117: deleteSelected(); return  // ⌫, ⌦
        case 53: cancel(); return               // esc
        default: break
        }

        switch event.charactersIgnoringModifiers {
        case "a": mode = .adding(under: nil)
        case "A": mode = .adding(under: selected.map { $0.item.parent ?? $0.item.id })
        case "c": copySelected()
        case "j": move(by: 1)
        case "k": move(by: -1)
        case " ": toggleSelected()
        default: super.keyDown(with: event)
        }
    }

    /// Hovering moves the highlight, so `c` copies what the pointer is on
    /// without a click first. A click would tick the row off, which is a long
    /// way from "I wanted to copy that".
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .inVisibleRect, .activeInActiveApp],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .list = mode, !rows.isEmpty else { return }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, row != selection else { return }
        selection = row
        syncSelection()
    }
}

// MARK: - Table

extension TodoPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let entry = rows[safe: row] else { return nil }
        return TodoRow(entry)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }
}

// MARK: - Field

extension TodoPalette: NSTextFieldDelegate {
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitAdd()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            mode = .list
            return true
        default:
            return false
        }
    }
}

/// One task: its branch, a box, and the text.
private final class TodoRow: NSView {
    init(_ entry: TodoStore.Row) {
        super.init(frame: .zero)
        let item = entry.item

        // The branch, drawn rather than typed. `├` and `└` are glyphs sized by
        // the font, and at a row height of 34 they float in the middle of the
        // gap with nothing joining one to the next — a tree with the trunk
        // missing. Two lines per row join up because the rows are contiguous.
        let branch = TodoBranch(visible: entry.depth > 0, continues: !entry.isLast)
        addSubview(branch)

        let box = TodoBox(done: item.done)
        addSubview(box)

        let label = NSTextField(labelWithString: item.text)
        label.font = .systemFont(ofSize: 13, weight: entry.depth == 0 ? .medium : .regular)
        label.textColor = item.done ? PaletteStyle.tertiaryText : PaletteStyle.primaryText
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        if item.done {
            // Through the attributed string, which carries its own line
            // breaking: assigning one throws `lineBreakMode` away, and a
            // struck-through row was the only one that wrapped.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            label.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: PaletteStyle.tertiaryText,
                    .foregroundColor: PaletteStyle.tertiaryText,
                    .font: NSFont.systemFont(ofSize: 13),
                    .paragraphStyle: paragraph,
                ])
        }
        addSubview(label)

        let indent: CGFloat = entry.depth > 0 ? 30 : 14
        NSLayoutConstraint.activate([
            branch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            branch.topAnchor.constraint(equalTo: topAnchor),
            branch.bottomAnchor.constraint(equalTo: bottomAnchor),

            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The elbow joining a sub-task to the task above it.
///
/// A vertical through the top half, and one across to the box. When the task
/// has siblings below it the vertical carries on through the bottom half, so
/// consecutive rows draw one unbroken trunk.
private final class TodoBranch: NSView {
    private let visible: Bool
    private let continues: Bool

    init(visible: Bool, continues: Bool) {
        self.visible = visible
        self.continues = continues
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 11).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Flipped, so `y: 0` is the top and the elbow drops from the task above
    /// rather than rising from the one below.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard visible else { return }
        PaletteStyle.tertiaryText.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // Half-pixel offsets, or a 1pt line lands between two device pixels and
        // comes out as a soft two-pixel smear.
        let x = 0.5
        let middle = (bounds.height / 2).rounded() + 0.5
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: continues ? bounds.height : middle))
        path.move(to: NSPoint(x: x, y: middle))
        path.line(to: NSPoint(x: bounds.width, y: middle))
        path.stroke()
    }
}

/// The checkbox: a real box, drawn rather than typed.
///
/// It was a `◻` in a label, which is a glyph the font decides the size of and
/// this one decided it should be small. Drawing it means it is the size it is
/// meant to be, its corners match the panel's, and a ticked one can fill
/// rather than swap to a different character.
private final class TodoBox: NSView {
    init(done: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        layer?.borderColor = (done ? PaletteStyle.tertiaryText : PaletteStyle.secondaryText).cgColor
        layer?.backgroundColor = done
            ? PaletteStyle.chipEmphasised.cgColor
            : NSColor.clear.cgColor

        if done {
            let tick = NSImageView()
            tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
            tick.symbolConfiguration = .init(pointSize: 9, weight: .bold)
            tick.contentTintColor = PaletteStyle.secondaryText
            tick.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tick)
            NSLayoutConstraint.activate([
                tick.centerXAnchor.constraint(equalTo: centerXAnchor),
                tick.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
