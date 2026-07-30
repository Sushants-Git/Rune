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
    /// What that workspace is doing, spelled out.
    let status: Status
    /// Everything the fuzzy filter is allowed to match against.
    let searchText: String
    /// The name already set by hand, if any — what ⌘R starts editing.
    let editableName: String
    /// Shown greyed out while renaming, so an empty field reads as "back to
    /// whatever the terminal calls itself" rather than as blank.
    let automaticTitle: String
}

/// The switcher's own colours.
///
/// Fixed rather than semantic, and that is the point. Rune sets the window's
/// appearance from the terminal's background so the traffic lights stay
/// legible, which means `labelColor` and friends flip to *black* whenever
/// you're running a light theme. The panel is always dark, so it has to state
/// its own colours or it goes black-on-black the first time someone uses a
/// light colourscheme.
enum PaletteStyle {
    /// Near-black rather than pure black: a true #000 panel over a #000
    /// terminal has no edge at all, and the switcher needs to read as a thing
    /// sitting *on* the terminal.
    static let background = NSColor(white: 0.055, alpha: 1)
    static let border = NSColor(white: 1, alpha: 0.10)
    static let divider = NSColor(white: 1, alpha: 0.07)
    static let selection = NSColor(white: 1, alpha: 0.09)

    static let primaryText = NSColor(white: 0.96, alpha: 1)
    static let secondaryText = NSColor(white: 1, alpha: 0.55)
    static let tertiaryText = NSColor(white: 1, alpha: 0.34)

    static let tile = NSColor(white: 1, alpha: 0.07)
    static let chip = NSColor(white: 1, alpha: 0.07)
    static let chipEmphasised = NSColor(white: 1, alpha: 0.14)
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

    private let panel = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No workspaces match")
    private var scrollHeight: NSLayoutConstraint!

    static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 40
    private static let maxVisibleRows = 8
    private static let cornerRadius: CGFloat = 12
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
        // Solid, not vibrant. A blur samples the terminal behind it, so the
        // panel's own darkness depended on what happened to be on screen —
        // over a pale `ls` it went milky and the rows lost their contrast.
        // Opaque black is the same panel every time.
        panel.wantsLayer = true
        panel.layer?.backgroundColor = PaletteStyle.background.cgColor
        panel.layer?.cornerRadius = Self.cornerRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = PaletteStyle.border.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.55
        panel.layer?.shadowRadius = 40
        panel.layer?.shadowOffset = CGSize(width: 0, height: -10)
        panel.layer?.masksToBounds = false

        // A big, bare field. No leading icon: the panel appearing *is* the
        // affordance, and an icon only steals width from the placeholder.
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.textColor = PaletteStyle.primaryText
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        // Attributed rather than a plain `placeholderString`, which AppKit
        // renders in a semantic grey that goes near-invisible on the panel.
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search workspaces…",
            attributes: [
                .foregroundColor: PaletteStyle.tertiaryText,
                .font: NSFont.systemFont(ofSize: 15),
            ])
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
        emptyLabel.textColor = PaletteStyle.tertiaryText
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

            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: Self.contentInset),
            searchField.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -Self.contentInset),

            headerDivider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 15),
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

            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9),
            hints.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -Self.contentInset),
            hints.leadingAnchor.constraint(
                greaterThanOrEqualTo: panel.leadingAnchor, constant: Self.contentInset),
            hints.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -9),
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

    /// Keycap-style hints, the way a launcher does it: the key drawn as a key,
    /// then what it does. Everything the switcher responds to is listed, since
    /// a panel with no menu is a panel with nowhere else to learn it from.
    private static func hintBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 14
        for (keys, label) in [
            (["↑", "↓"], "Navigate"),
            (["↵"], "Open"),
            (["⌘R"], "Rename"),
            (["esc"], "Close"),
        ] {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10.5)
            text.textColor = PaletteStyle.tertiaryText

            let caps = NSStackView(views: keys.map { Keycap($0) })
            caps.orientation = .horizontal
            caps.spacing = 2

            let pair = NSStackView(views: [caps, text])
            pair.orientation = .horizontal
            pair.spacing = 5
            stack.addArrangedSubview(pair)
        }
        return stack
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

        // The text runs the full width of the row and the status cluster floats
        // over its trailing end. See `PaletteRow`.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9

        if index == editingIndex {
            let field = NSTextField(string: item.editableName)
            field.cell = PaddedFieldCell(textCell: item.editableName)
            field.stringValue = item.editableName
            field.font = .systemFont(ofSize: 13, weight: .medium)
            field.textColor = PaletteStyle.primaryText
            field.isEditable = true
            field.isBordered = false
            field.focusRingType = .none
            field.drawsBackground = false
            field.placeholderAttributedString = NSAttributedString(
                string: item.automaticTitle,
                attributes: [
                    .foregroundColor: PaletteStyle.tertiaryText,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                ])
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            stack.addArrangedSubview(FieldWell(field: field))
        } else {
            let name = NSTextField(labelWithString: item.title)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.textColor = PaletteStyle.primaryText
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            stack.addArrangedSubview(name)

            // Title and directory share a line: two stacked lines per row makes
            // a short list read like a settings pane instead of a launcher.
            if !item.subtitle.isEmpty {
                let path = NSTextField(labelWithString: item.subtitle)
                path.font = .systemFont(ofSize: 11)
                path.textColor = PaletteStyle.tertiaryText
                path.lineBreakMode = .byTruncatingHead
                path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(path)
            }
        }

        // The whole reason to open this list is to find the terminal that wants
        // you, so what each one is doing is spelled out rather than coded into
        // a coloured dot you then have to remember the key for.
        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 6
        if let badge = ActivityBadge(item.status) {
            cluster.addArrangedSubview(badge)
        }
        if let text = item.badge {
            cluster.addArrangedSubview(Chip(text: text))
        }
        if item.isCurrent {
            cluster.addArrangedSubview(Chip(text: "current", emphasised: true))
        }

        return PaletteRow(icon: icon, text: stack, cluster: cluster)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressPreview else { return }
        let row = tableView.selectedRow
        guard let index = filtered[safe: row], row != selection else { return }
        selection = row
        onPreview(index)
    }
}

/// One row's contents: the icon, the name, and the status cluster.
///
/// The cluster **floats over** the text rather than sitting beside it. Laid out
/// side by side, a long workspace name and a long status fight for the same
/// width, and Auto Layout resolves it by compressing whichever has the weaker
/// priority — which is how a status badge ends up rendered as "C…" and a tab
/// count as an empty grey box.
///
/// So the text gets the entire row to run in, the cluster is drawn on top of
/// its trailing end, and the text is masked to fade out just before it reaches
/// the cluster. A short name is unaffected: it never reaches the fade. A long
/// one runs as far as there is room and dissolves rather than being chopped.
private final class PaletteRow: NSView {
    private let text: NSView
    private let cluster: NSView
    private let fade = CAGradientLayer()

    /// How wide the dissolve is, and how much clear space to leave between the
    /// end of the fade and the cluster itself.
    private static let fadeWidth: CGFloat = 34
    private static let clusterGap: CGFloat = 8

    init(icon: NSView, text: NSView, cluster: NSView) {
        self.text = text
        self.cluster = cluster
        super.init(frame: .zero)

        for view in [icon, text, cluster] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        // Order matters: the cluster is added last so it draws over the text.
        addSubview(icon)
        addSubview(text)
        addSubview(cluster)

        text.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [
            NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor,
        ]

        let inset = SwitcherPalette.contentInset - SwitcherPalette.rowInset

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),

            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            cluster.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Nothing in the cluster may ever be compressed; the text yields first.
        cluster.setContentCompressionResistancePriority(.required, for: .horizontal)
        cluster.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()

        // A row with nothing on the right needs no fade at all.
        guard cluster.subviews.count > 0, cluster.frame.width > 0 else {
            text.layer?.mask = nil
            return
        }

        // Where the text should have finished, in the text view's own space.
        let stop = cluster.frame.minX - Self.clusterGap - text.frame.minX
        guard stop > Self.fadeWidth, stop < text.frame.width else {
            // The cluster is wider than the row, or the text already ends well
            // clear of it. Either way a partial mask would only cause trouble.
            text.layer?.mask = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = text.bounds
        let width = text.frame.width
        fade.locations = [
            0,
            NSNumber(value: Double((stop - Self.fadeWidth) / width)),
            NSNumber(value: Double(stop / width)),
        ]
        text.layer?.mask = fade
        CATransaction.commit()
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
        PaletteStyle.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

// MARK: - Small pieces

/// A hairline that reads as a seam rather than as a system separator.
private final class Divider: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        PaletteStyle.divider.setFill()
        bounds.fill()
    }
}

/// The rounded, tinted square a row's symbol sits in.
private final class IconTile: NSView {
    init(image artwork: NSImage?, symbol: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
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
            layer?.backgroundColor = PaletteStyle.tile.cgColor
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            image.contentTintColor = PaletteStyle.secondaryText
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: artwork == nil ? 24 : 17),
            image.heightAnchor.constraint(equalToConstant: artwork == nil ? 24 : 17),
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
        layer?.backgroundColor = (emphasised ? PaletteStyle.chipEmphasised : PaletteStyle.chip)
            .cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = emphasised ? PaletteStyle.secondaryText : PaletteStyle.tertiaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        // On the label, not just the chip: the chip's width is driven by this,
        // so without it a squeezed row collapses the chip into an empty box.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = PaletteStyle.secondaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
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
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor

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
    /// The field editor is shared with the rest of the window, and inherits the
    /// window's appearance — which Rune derives from the *terminal's* theme. On
    /// a light colourscheme that gives a black caret and a black selection on
    /// the panel's black background, so both are stated outright.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = (notification.object as? NSTextField)?.currentEditor()
                as? NSTextView
        else { return }
        editor.insertionPointColor = PaletteStyle.primaryText
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.5),
            .foregroundColor: PaletteStyle.primaryText,
        ]
    }

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
