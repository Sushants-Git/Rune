import Cocoa

/// The todo list, in the switcher's panel.
///
/// The same surface as `⌘K` and deliberately so: it is the panel Rune already
/// has, drawn with the same glass, the same rows and the same hint bar, showing
/// a different list. A second window with its own shape would be a second thing
/// to learn and a second thing to position.
///
/// It shares the overlay too, which means it inherits dragging, the remembered
/// position and the backdrop for free, and only one of the two can be up at a
/// time — which is right, since they answer the same question at different
/// scopes: what am I working on, and what have I left to do.
@MainActor
final class TodoPalette: NSView, OverlayPanel {
    /// The field, which is both "add one" and where the keyboard lives.
    let field = NSTextField()
    var focusField: NSTextField { field }

    private let onDismiss: () -> Void

    private let store = TodoStore.shared
    private var rows: [TodoItem] = []
    private var selection = 0

    private let panel = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing to do")
    private var scrollHeight: NSLayoutConstraint!

    static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 38
    private static let maxVisibleRows = 8
    private static let cornerRadius: CGFloat = 12

    private let backdrop = SwitcherPalette.makeBackdrop(cornerRadius: cornerRadius)
    private let scrim = NSView()
    private let grip = PanelGrip()

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        rows = store.ordered
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func cancel() {
        onDismiss()
    }

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

        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = PaletteStyle.primaryText
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderAttributedString = NSAttributedString(
            string: "What do you have to do?",
            attributes: [
                .foregroundColor: PaletteStyle.tertiaryText,
                .font: NSFont.systemFont(ofSize: 15),
            ])
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

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = PaletteStyle.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyLabel)

        let footerDivider = Divider()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(footerDivider)

        let hints = Self.hintBar()
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

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),

            grip.topAnchor.constraint(equalTo: panel.topAnchor),
            grip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            grip.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: 15),

            headerDivider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 15),
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

            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 10),
            hints.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            hints.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])
    }

    private static func hintBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 14
        for (key, label) in [
            ("⏎", "Add"),
            ("⌘⏎", "Done"),
            ("⌘W", "Delete"),
            ("esc", "Dismiss"),
        ] {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10.5)
            text.textColor = PaletteStyle.tertiaryText
            let pair = NSStackView(views: [Keycap(key), text])
            pair.orientation = .horizontal
            pair.spacing = 5
            stack.addArrangedSubview(pair)
        }
        return stack
    }

    // MARK: - List

    /// Re-read the store and resize. Called on every change, which for a list
    /// this short is cheaper than working out what moved.
    private func refresh() {
        rows = store.ordered
        selection = min(max(selection, 0), max(rows.count - 1, 0))

        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        scrollView.isHidden = rows.isEmpty

        let visible = min(rows.count, Self.maxVisibleRows)
        let height = rows.isEmpty
            ? Self.rowHeight
            : CGFloat(visible) * Self.rowHeight + SwitcherPalette.rowInset * 2
        scrollHeight.constant = height

        syncSelection()
    }

    private func syncSelection() {
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    private var selected: TodoItem? { rows[safe: selection] }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta % rows.count + rows.count) % rows.count
        syncSelection()
    }

    /// `⏎`. With something typed it adds; with an empty field it ticks the
    /// highlighted row off, so the key means "commit what I am looking at"
    /// either way and the field never has to be cleared by hand.
    func commit() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            toggleSelected()
        } else {
            store.add(typed)
            field.stringValue = ""
            // Land on what was just added, which is the last undone row.
            refresh()
            if let index = rows.firstIndex(where: { $0.text == typed && !$0.done }) {
                selection = index
                syncSelection()
            }
        }
    }

    func toggleSelected() {
        guard let item = selected else { return }
        store.toggle(item.id)
        refresh()
    }

    func deleteSelected() {
        guard let item = selected else { return }
        store.remove(item.id)
        refresh()
    }

    @objc private func rowClicked() {
        guard let index = rows.indices.contains(tableView.clickedRow)
            ? tableView.clickedRow : nil else { return }
        selection = index
        toggleSelected()
    }

    // MARK: - Keys

    /// ⌘⏎ toggles without emptying the field first.
    ///
    /// Caught here rather than in the field's command selectors because those
    /// only report the plain key; the modifier never reaches them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, event.charactersIgnoringModifiers == "\r" else {
            return super.performKeyEquivalent(with: event)
        }
        toggleSelected()
        return true
    }
}

// MARK: - Table

extension TodoPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let item = rows[safe: row] else { return nil }
        return TodoRow(item: item)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        selection = tableView.selectedRow
    }
}

// MARK: - Field

extension TodoPalette: NSTextFieldDelegate {
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

/// One todo: a box, the text, and a strike through it once it is done.
private final class TodoRow: NSView {
    init(item: TodoItem) {
        super.init(frame: .zero)

        let box = NSTextField(labelWithString: item.done ? "◼" : "◻")
        box.font = .systemFont(ofSize: 13)
        box.textColor = item.done ? PaletteStyle.tertiaryText : PaletteStyle.secondaryText
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        let label = NSTextField(labelWithString: item.text)
        label.font = .systemFont(ofSize: 13, weight: item.done ? .regular : .medium)
        label.textColor = item.done ? PaletteStyle.tertiaryText : PaletteStyle.primaryText
        // One line, always. A todo is a sentence someone typed and some of them
        // are long; wrapping one across two lines makes the row twice as tall
        // as its neighbours and the list stops being a list.
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        // The label takes whatever width is left rather than hugging its text,
        // or two rows of different lengths truncate in different places.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        if item.done {
            // Set through the attributed string, which carries its own line
            // breaking: assigning one throws away `lineBreakMode` above, and a
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

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
