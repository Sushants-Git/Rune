import Cocoa

/// One row in the ⌘K switcher.
struct PaletteItem {
    let title: String
    let subtitle: String
    /// Small trailing chip, e.g. a tab count.
    let badge: String?
    /// The workspace you were in when the switcher opened.
    let isCurrent: Bool
    /// The agent running there, or the project's own icon — either replaces
    /// the generic terminal glyph.
    let icon: NSImage?
    /// Everything the fuzzy filter is allowed to match against.
    let searchText: String
    /// The name already set by hand, if any — what ⌘R starts editing.
    let editableName: String
    /// Shown greyed out while renaming, so an empty field reads as "back to
    /// whatever the terminal calls itself" rather than as blank.
    let automaticTitle: String
}

/// The body of the ⌘K switcher: a filter field over a list, plus a hint bar.
///
/// It only knows about `PaletteItem`s — the switcher that hosts it decides what
/// those stand for and what selecting one does. Moving the selection *previews*
/// (the host swaps the workspace in behind the overlay), Enter keeps it, and
/// Escape puts you back where you started.
@MainActor
final class SwitcherPalette: NSView {
    let searchField = NSTextField()

    /// Pulled fresh rather than snapshotted: a workspace can close while the
    /// switcher is open, and selecting it would resurrect a dead surface.
    private let currentItems: () -> [PaletteItem]
    /// Indices into the *unfiltered* list, in display order.
    private var filtered: [Int] = []
    private var items: [PaletteItem] = []
    private var selection = 0

    private let onPreview: (Int) -> Void
    private let onCommit: (Int) -> Void
    private let onCancel: () -> Void
    /// ⌘R: the row was renamed in place. An empty name means "go back to the
    /// automatic one".
    var onRename: ((Int, String) -> Void)?
    /// Fired when the list grows or shrinks so the host can resize.
    var onSizeChange: (() -> Void)?

    /// Set while the table is rebuilt so the resulting selection change doesn't
    /// fire a preview for a row the user never moved to.
    private var suppressPreview = false

    /// The item being renamed in place, as an index into the unfiltered list.
    private var editingIndex: Int?
    private weak var editingField: NSTextField?

    private let panel = NSVisualEffectView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No workspaces match")
    private var scrollHeight: NSLayoutConstraint!

    static let width: CGFloat = 540
    private static let rowHeight: CGFloat = 34
    private static let maxVisibleRows = 9
    /// Rows are inset from the panel edge so the selection pill has somewhere
    /// to sit without touching the sides.
    fileprivate static let rowInset: CGFloat = 6
    fileprivate static let contentInset: CGFloat = 14

    init(
        items: @escaping () -> [PaletteItem],
        onPreview: @escaping (Int) -> Void,
        onCommit: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentItems = items
        self.onPreview = onPreview
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)

        self.items = items()
        self.filtered = Array(self.items.indices)
        // Start on the workspace you're already in, so ↑/↓ move relative to
        // where you are rather than from an arbitrary anchor.
        selection = self.items.firstIndex { $0.isCurrent } ?? 0

        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Chrome

    private func build() {
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 4
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // NSVisualEffectView clips to a mask image rather than a corner radius,
        // so the blur itself has to be rounded off separately.
        panel.maskImage = Self.roundedMask(radius: 4)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.5
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.layer?.masksToBounds = false

        // A big, bare field. No leading icon: the panel appearing *is* the
        // affordance, and an icon only steals width from the placeholder.
        searchField.placeholderString = "Search workspaces…"
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        panel.addSubview(searchField)

        let headerDivider = Divider()
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(headerDivider)

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        // Stays `.regular` so rows are asked to draw a selection at all;
        // PaletteRowView then replaces AppKit's full-bleed bar with an inset
        // pill that doesn't fight the panel's corner radius.
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.addTableColumn(NSTableColumn(identifier: .init("item")))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyLabel)

        let footerDivider = Divider()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(footerDivider)

        let hints = Self.hintBar()
        hints.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hints)

        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 13),
            searchField.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: Self.contentInset),
            searchField.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -Self.contentInset),

            headerDivider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            headerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            // No constant here: the padding above the first row comes from the
            // scroll view's content inset, the same place the padding below the
            // last row comes from. A constant on top of that made them uneven.
            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: Self.rowInset),
            scrollView.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -Self.rowInset),
            scrollHeight,

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerDivider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 7),
            hints.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -Self.contentInset),
            hints.leadingAnchor.constraint(
                greaterThanOrEqualTo: panel.leadingAnchor, constant: Self.contentInset),
            hints.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -7),
        ])

        reloadRows(notifySize: false)
    }

    /// The list grows with the number of matches, up to a cap, so two open
    /// workspaces don't get a half-empty panel.
    private func updateHeight() {
        let rows = min(max(filtered.count, 1), Self.maxVisibleRows)
        // Exactly the table's own height plus the scroll view's insets, so a
        // short list has nothing to scroll and no scroller appears over it —
        // and the gap above the first row matches the gap below the last.
        scrollHeight.constant = CGFloat(rows) * Self.rowHeight + 12

        let fits = filtered.count <= Self.maxVisibleRows
        scrollView.hasVerticalScroller = !fits
        scrollView.verticalScrollElasticity = fits ? .none : .allowed

        emptyLabel.isHidden = !filtered.isEmpty
    }

    /// Keycap-style hints, the way a launcher does it: what it does, then the
    /// key drawn as a key.
    private static func hintBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        for (keys, label) in [("⌘r", "Rename")] {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10.5)
            text.textColor = .secondaryLabelColor

            let pair = NSStackView(views: [text, Keycap(keys)])
            pair.orientation = .horizontal
            pair.spacing = 5
            stack.addArrangedSubview(pair)
        }
        return stack
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Filtering

    /// Re-read the list (titles and directories change as you work) without
    /// disturbing which row is selected.
    func reload() {
        applyFilter(searchField.stringValue, keepSelection: true)
    }

    private func applyFilter(_ query: String, keepSelection: Bool) {
        // Anchor on the underlying index, not the row, so the selection
        // survives both filtering and workspaces opening or closing.
        let anchor = keepSelection ? filtered[safe: selection] : nil

        items = currentItems()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // No query means creation order, untouched. The switcher never
            // reshuffles on its own.
            filtered = Array(items.indices)
        } else {
            filtered = items.indices
                .compactMap { index -> (Int, Int)? in
                    guard let score = FuzzyMatch.score(
                        needle: trimmed, haystack: items[index].searchText)
                    else { return nil }
                    return (index, score)
                }
                // Ties keep creation order rather than whatever sort() picks.
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .map(\.0)
        }

        selection = anchor.flatMap { filtered.firstIndex(of: $0) } ?? 0
        reloadRows(notifySize: true)
    }

    private func reloadRows(notifySize: Bool) {
        updateHeight()
        tableView.reloadData()
        syncSelection(preview: false)
        if notifySize { onSizeChange?() }
    }

    // MARK: - Selection

    /// Index into the unfiltered list of whatever row is highlighted.
    var selectedItemIndex: Int? { filtered[safe: selection] }

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = (selection + delta % filtered.count + filtered.count) % filtered.count
        syncSelection(preview: true)
    }

    /// Push `selection` into the table, and optionally swap in the workspace
    /// behind the overlay so you can see what you're about to pick.
    private func syncSelection(preview: Bool) {
        guard let index = filtered[safe: selection] else { return }

        suppressPreview = true
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        suppressPreview = false
        tableView.scrollRowToVisible(selection)

        if preview { onPreview(index) }
    }

    func commit() {
        guard let index = filtered[safe: selection] else {
            onCancel()
            return
        }
        onCommit(index)
    }

    func cancel() {
        onCancel()
    }

    @objc private func tableClicked() {
        // A click on the row being renamed belongs to the field, not the list.
        guard editingIndex == nil else { return }
        guard let index = filtered[safe: tableView.clickedRow] else { return }
        onCommit(index)
    }

    // MARK: - Renaming in place

    var isRenaming: Bool { editingIndex != nil }

    /// ⌘R: turn the highlighted row's name into a text field. Editing where the
    /// name already is beats stacking a dialog on top of the switcher.
    func beginRename() {
        guard let index = selectedItemIndex else { return }
        editingIndex = index
        tableView.reloadData()
        syncSelection(preview: false)
        focusEditingField()
    }

    /// The row's field has to be found after the table has actually built it —
    /// `reloadData` doesn't promise the view exists by the time it returns.
    private func focusEditingField() {
        guard let index = editingIndex, let row = filtered.firstIndex(of: index) else { return }
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true),
              let field = Self.editableField(in: cell)
        else { return }

        editingField = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private static func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }

    func commitRename() {
        guard let index = editingIndex, let field = editingField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        endRename()
        onRename?(index, name)
        reload()
    }

    func cancelRename() {
        guard editingIndex != nil else { return }
        endRename()
        tableView.reloadData()
        syncSelection(preview: false)
    }

    private func endRename() {
        editingIndex = nil
        editingField = nil
        window?.makeFirstResponder(searchField)
    }
}

// MARK: - Table data

extension SwitcherPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = filtered[safe: row], let item = items[safe: index] else { return nil }

        let icon = IconTile(
            image: item.icon,
            symbol: item.badge == nil ? "terminal" : "square.stack")

        let stack = NSStackView(views: [icon])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Self.contentInset - Self.rowInset,
            bottom: 0, right: Self.contentInset - Self.rowInset)

        if index == editingIndex {
            let field = NSTextField(string: item.editableName)
            field.cell = PaddedFieldCell(textCell: item.editableName)
            field.stringValue = item.editableName
            field.font = .systemFont(ofSize: 13, weight: .medium)
            field.isEditable = true
            field.isBordered = false
            field.focusRingType = .none
            field.drawsBackground = false
            field.placeholderString = item.automaticTitle
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            stack.addArrangedSubview(FieldWell(field: field))
            stack.addArrangedSubview(NSView())  // spacer
        } else {
            let name = NSTextField(labelWithString: item.title)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            stack.addArrangedSubview(name)

            // Title and directory share a line: two stacked lines per row makes
            // a short list read like a settings pane instead of a launcher.
            if !item.subtitle.isEmpty {
                let path = NSTextField(labelWithString: item.subtitle)
                path.font = .systemFont(ofSize: 11)
                path.textColor = .tertiaryLabelColor
                path.lineBreakMode = .byTruncatingHead
                path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(path)
            }
            stack.addArrangedSubview(NSView())  // spacer
        }

        if let text = item.badge {
            stack.addArrangedSubview(Chip(text: text))
        }
        if item.isCurrent {
            stack.addArrangedSubview(Chip(text: "current", emphasised: true))
        }

        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressPreview else { return }
        let row = tableView.selectedRow
        guard let index = filtered[safe: row], row != selection else { return }
        selection = row
        onPreview(index)
    }
}

/// A row whose selection highlight is a rounded pill rather than the
/// edge-to-edge bar AppKit draws by default. Neutral rather than accent-tinted:
/// the list is scanned constantly, and a saturated bar under every keypress is
/// tiring.
private final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { _ = newValue }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - Small pieces

/// A hairline that reads as a seam rather than as a system separator.
private final class Divider: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        bounds.fill()
    }
}

/// The rounded, tinted square a row's symbol sits in.
private final class IconTile: NSView {
    init(image artwork: NSImage?, symbol: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous

        let image = NSImageView()
        if let artwork {
            // Real marks are drawn for light backgrounds — several are
            // near-black — so they get a light tile of their own, the way an
            // app icon sits in a launcher.
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            image.image = artwork
            image.imageScaling = .scaleProportionallyUpOrDown
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 10.5, weight: .medium)
            image.contentTintColor = .secondaryLabelColor
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 21),
            heightAnchor.constraint(equalToConstant: 21),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: artwork == nil ? 21 : 16),
            image.heightAnchor.constraint(equalToConstant: artwork == nil ? 21 : 16),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A small rounded label — tab counts, the "current" marker. Grey rather than
/// tinted: these annotate a row, they don't call for action, and an accent
/// colour on every row's right edge is noise.
private final class Chip: NSView {
    init(text: String, emphasised: Bool = false) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(emphasised ? 0.13 : 0.07).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = emphasised ? .secondaryLabelColor : .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A key drawn as a key, for the footer hints.
private final class Keycap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The well the ⌘R field sits in, so the row visibly *becomes* an input rather
/// than just tinting the text that was already there.
private final class FieldWell: NSView {
    init(field: NSTextField) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor

        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// NSTextField has no padding of its own, so the cell has to inset both the
/// drawn text and the field editor.
private final class PaddedFieldCell: NSTextFieldCell {
    private static let padding: CGFloat = 10

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: Self.padding, dy: 0))
    }
}

// MARK: - Search field

extension SwitcherPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // A rename in progress owns its own keystrokes; only the search field
        // filters.
        guard notification.object as AnyObject? !== editingField else { return }
        applyFilter(searchField.stringValue, keepSelection: false)
    }

    /// Navigation has to be intercepted here rather than in a `keyDown`
    /// override: an editable NSTextField hands its key events to AppKit's
    /// shared field editor, which becomes the real first responder, so the
    /// field's own `keyDown` never runs. The field editor turns those keys into
    /// these command selectors instead.
    ///
    /// Going through the selectors also gets the emacs-style bindings for free
    /// — the field editor already maps ⌃P/⌃N to moveUp:/moveDown:.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // While a row is being renamed the same keys mean something else: the
        // list shouldn't move under an edit.
        if control === editingField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                commitRename()
            case #selector(NSResponder.cancelOperation(_:)):
                cancelRename()
            default:
                return false
            }
            return true
        }

        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            commit()
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1)
        default:
            return false
        }
        return true
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Fuzzy matching

enum FuzzyMatch {
    /// Score `needle` as a subsequence of `haystack`, or nil if it isn't one.
    ///
    /// Every occurrence of the first character is tried as an anchor and the
    /// best alignment wins. A single greedy pass takes the *first* candidate
    /// character it sees, which is how "pro" used to score `Workspace…frontend`
    /// (p from "Workspace", r and o from "frontend") as highly as `projectx` —
    /// the obvious answer lost to an accident of path spelling.
    static func score(needle: String, haystack: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        guard !n.isEmpty else { return 0 }

        var best: Int?
        for start in h.indices where h[start] == n[0] {
            guard let score = align(n, h, from: start) else { continue }
            if best == nil || score > best! { best = score }
        }
        return best
    }

    private static func align(_ n: [Character], _ h: [Character], from start: Int) -> Int? {
        var score = 0
        var ni = 0
        var lastMatch = -1

        for hi in start..<h.count {
            guard ni < n.count, h[hi] == n[ni] else { continue }

            score += 1
            if lastMatch == hi - 1 { score += 6 }
            if hi == 0 {
                score += 12
            } else if isBoundary(h[hi - 1]) {
                score += 6
            }

            lastMatch = hi
            ni += 1
        }

        return ni == n.count ? score : nil
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "/" || character == "-"
            || character == "_" || character == "." || character == "@"
    }
}
