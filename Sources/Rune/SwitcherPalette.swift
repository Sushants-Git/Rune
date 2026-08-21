import Cocoa

/// One row in the ⌘K switcher.
struct PaletteItem {
    let title: String
    let subtitle: String
    /// Small trailing chip, e.g. a tab count.
    let badge: String?
    /// The workspace you were in when the switcher opened.
    let isCurrent: Bool
    /// Pinned to the top with ⌘P.
    let isPinned: Bool
    /// One pane is filling the tab, from ⌘⇧↵.
    let isZoomed: Bool
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
    /// Armed with → to notify when its agent stops.
    let bell: Workspace.Bell
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
    /// Whether the panel should be drawn dark-on-light rather than
    /// light-on-dark.
    ///
    /// Taken from the terminal's own background, because that is what the panel
    /// sits on. Every colour below is a translucent white over a near-black
    /// slab, which over a light theme leaves white text on pale grey — legible
    /// in the sense that the pixels differ, and unreadable in every sense that
    /// matters.
    @MainActor static var isLight: Bool {
        // A panel colour picked by hand decides this outright. The text has to
        // be legible on the panel it is drawn on, and nothing else — pick a
        // white panel under a dark terminal and following the *terminal* would
        // put white text on it.
        if let chosen = Settings.shared.panelBackgroundOverride { return chosen.isLight }
        switch Settings.shared.appearance {
        case .light: return true
        case .dark: return false
        case .automatic:
            let terminal = (NSApp.delegate as? AppDelegate)?.ghostty?.backgroundColor
            return (terminal ?? .black).isLight
        }
    }

    /// Near-black rather than pure black: a true #000 panel over a #000
    /// terminal has no edge at all, and the switcher needs to read as a thing
    /// sitting *on* the terminal. Near-white for the same reason on a light
    /// theme.
    ///
    /// Settable in Settings ▸ Appearance. Computed rather than stored so the
    /// next ⌘K picks up a change without anything having to be told about it —
    /// the panel is built fresh on every open.
    @MainActor static var background: NSColor {
        Settings.shared.panelBackgroundOverride
            ?? (isLight ? NSColor(white: 0.97, alpha: 1) : Settings.Defaults.panelBackground)
    }

    /// Laid over the glass so the rows' contrast is a constant, not a function
    /// of whatever the terminal happens to be showing.
    @MainActor static var scrim: NSColor {
        isLight ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0.04, alpha: 0.42)
    }
    @MainActor static var border: NSColor { ink(0.14, over: 0.10) }
    @MainActor static var divider: NSColor { ink(0.09, over: 0.07) }
    @MainActor static var selection: NSColor { ink(0.08, over: 0.09) }

    @MainActor static var primaryText: NSColor {
        isLight ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }
    @MainActor static var secondaryText: NSColor { ink(0.62, over: 0.55) }
    @MainActor static var tertiaryText: NSColor { ink(0.42, over: 0.34) }

    @MainActor static var tile: NSColor { ink(0.07, over: 0.07) }
    /// What goes behind a mark that doesn't paint its own background.
    ///
    /// Settable in Settings ▸ Appearance; see `Settings.lightIconTiles`. On a
    /// light panel a white plate is invisible, so the setting means "a plate
    /// that contrasts" rather than literally "a white one".
    @MainActor static var markPlate: NSColor {
        guard Settings.shared.lightIconTiles else { return tile }
        return isLight ? NSColor(white: 0, alpha: 0.06) : NSColor.white.withAlphaComponent(0.9)
    }
    @MainActor static var chip: NSColor { ink(0.07, over: 0.07) }
    @MainActor static var chipEmphasised: NSColor { ink(0.13, over: 0.14) }

    /// Ink of the right polarity: black over a light panel, white over a dark
    /// one. The two alphas are separate because the same number does not read
    /// the same in both directions — black at 8% is heavier than white at 8%.
    @MainActor private static func ink(_ onLight: CGFloat, over onDark: CGFloat) -> NSColor {
        isLight ? NSColor(white: 0, alpha: onLight) : NSColor(white: 1, alpha: onDark)
    }
}

extension NSColor {
    /// Whether this reads as a light colour, by perceived brightness rather
    /// than by the average of the channels — green carries most of the
    /// impression of lightness and blue almost none.
    var isLight: Bool {
        guard let srgb = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance > 0.5
    }
}

/// The body of the ⌘K switcher: a filter field over a list, plus a hint bar.
///
/// It only knows about `PaletteItem`s — the switcher that hosts it decides what
/// those stand for and what selecting one does. Moving the selection *previews*
/// (the host swaps the workspace in behind the overlay), Enter keeps it, and
/// Escape puts you back where you started.
@MainActor
final class SwitcherPalette: NSView, OverlayPanel {
    let searchField = NSTextField()
    var focusView: NSView { searchField }

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
    /// ⌘W: close the row's workspace outright. The switcher stays open — the
    /// point of closing from here is clearing out several at once, and a dialog
    /// that dismissed itself after each one would make that four ⌘Ks.
    var onCloseItem: ((Int) -> Void)?
    /// →: arm or disarm "tell me when the agent in this one stops". The host
    /// owns the arming, and reloads the list to put the bell on the row.
    var onToggleNotify: ((Int) -> Void)?

    /// ⌘P: pin the row to the top, or unpin it. The host owns the pin order and
    /// reloads the list, so the palette never reorders anything itself.
    var onTogglePin: ((Int) -> Void)?
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

    /// The live material behind the panel, and a fixed darkening on top of it.
    /// Split in two on purpose: the material is what makes it glass, the scrim
    /// is what stops the glass deciding how readable the rows are.
    private let backdrop = SwitcherPalette.makeBackdrop(cornerRadius: cornerRadius)
    private let scrim = NSView()

    /// Covers the search strip so the top of the panel can be grabbed, the way
    /// a title bar can. It stands in front of the text field, which would
    /// otherwise swallow the click to place a cursor.
    private let grip = PanelGrip()

    /// Real glass where the system has it, vibrancy where it doesn't.
    ///
    /// `NSGlassEffectView` is macOS 26 and later; Rune runs on 13. The fallback
    /// is the same idea one generation earlier, and because the scrim carries
    /// the contrast either way, the two look closer than they otherwise would.
    static func makeBackdrop(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            return glass
        }
        let vibrancy = NSVisualEffectView()
        // `.withinWindow`, not `.behindWindow`: the thing worth sampling is the
        // terminal underneath the panel, which is a sibling view in this same
        // window, not the desktop behind the whole thing.
        vibrancy.blendingMode = .withinWindow
        vibrancy.material = .hudWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = cornerRadius
        vibrancy.layer?.cornerCurve = .continuous
        vibrancy.layer?.masksToBounds = true
        return vibrancy
    }
    /// Rows are inset from the panel edge so the selection pill has somewhere
    /// to sit without touching the sides.
    static let rowInset: CGFloat = 6
    static let contentInset: CGFloat = 14

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
        // Glass, with a scrim under it.
        //
        // This was solid black for a long time, and for a good reason: a plain
        // blur samples the terminal behind it, so over a pale `ls` the panel
        // went milky and the rows lost their contrast. The panel's darkness
        // should not depend on what happened to be on screen.
        //
        // What makes it workable now is that the darkness is no longer coming
        // from the material. The glass provides the refraction and the live
        // sample of what's behind; `scrim` provides a fixed floor of darkness
        // underneath the text. Bright terminal, dark terminal, the rows sit on
        // the same contrast either way — see `PaletteStyle.scrim`.
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

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: panel.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: panel.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        // No shadow. It was doing the job of a border — a grey haze spreading a
        // third of the way across the window — and the panel already has an
        // edge, a scrim and a background that differs from the terminal's. Three
        // things saying "this is in front" is two too many.
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

        grip.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(grip)

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

            // The whole strip, edge to edge, not just the field's own box —
            // the padding around it should drag too.
            grip.topAnchor.constraint(equalTo: panel.topAnchor),
            grip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            grip.bottomAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 15),

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
    /// then what it does.
    ///
    /// Only the ones worth saying. Arrows moving a selection and ⏎ taking it are
    /// what every list on the machine already does, so spelling them out spent
    /// half the bar teaching nobody anything — and made the four that *are*
    /// particular to Rune harder to pick out for being in a crowd. The keys
    /// themselves are unchanged; it's the sentence that was redundant.
    private static func hintBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 14
        for (keys, label) in [
            (["⌘R"], "Rename"),
            (["⌘P"], "Pin"),
            (["→"], "Notify"),
            (["⌘W"], "Close"),
            // "Dismiss" rather than "Close", now that ⌘W closes a workspace and
            // esc closes the panel. Two rows both labelled Close would be a
            // riddle in the one place that exists to answer them.
            (["esc"], "Dismiss"),
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

    /// Reload and put the highlight on a specific item, given its index into
    /// the unfiltered list.
    ///
    /// Plain `reload` anchors on the selected row's *index*, which is exactly
    /// wrong after a pin: the indices are what moved, so anchoring would leave
    /// the highlight sitting on whichever workspace slid into the old slot.
    /// - Parameter preview: whether the terminal behind should follow. Pinning
    ///   is bookkeeping and should not move you; closing a row leaves the
    ///   highlight somewhere new, and a highlight that disagrees with what is
    ///   on screen behind it is its own bug.
    func reload(selecting itemIndex: Int?, preview: Bool = false) {
        applyFilter(searchField.stringValue, keepSelection: true)
        guard let itemIndex, let row = filtered.firstIndex(of: itemIndex) else { return }
        selection = row
        syncSelection(preview: preview)
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

    /// ⌘W: close the highlighted row's workspace.
    ///
    /// ⌘W because that is the key that closes things on a Mac — it was ⌘C,
    /// which is Copy everywhere else and had to be learned here on its own.
    ///
    /// Refused mid-rename: closing the row being edited would be a startling
    /// answer to a half-typed name. The host reloads the list, which is what
    /// moves the selection onto whatever takes the closed row's place.
    func closeSelected() {
        guard !isRenaming, let index = selectedItemIndex else { return }
        onCloseItem?(index)
    }

    /// ⌘P: pin the highlighted row to the top, or unpin it. Refused mid-rename
    /// for the same reason ⌘W is — the field editor's keystrokes are its own.
    func togglePinOnSelected() {
        guard !isRenaming, let index = selectedItemIndex else { return }
        onTogglePin?(index)
    }

    /// →: ring me when the agent on the highlighted row stops.
    ///
    /// An arrow key rather than another ⌘-chord, because it is the one gesture
    /// in this panel that is *about* the row you are arrowing through — you
    /// come down the list looking for the one that's working, and the key that
    /// arms it is under the same finger that got you there.
    func toggleNotifyOnSelected() {
        guard !isRenaming, let index = selectedItemIndex else { return }
        onToggleNotify?(index)
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

        // A pinned row is already at the top; the glyph says *why* it's there,
        // which is the difference between an order you chose and one you're
        // trying to account for.
        if item.isPinned,
           let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") {
            let mark = NSImageView(image: pin)
            mark.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            mark.contentTintColor = PaletteStyle.secondaryText
            mark.setContentHuggingPriority(.required, for: .horizontal)
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(mark)
            stack.setCustomSpacing(6, after: mark)
        }

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
        // A glyph rather than a word. "Zoomed" is jargon and "full screen" is
        // both long and wrong — the pane fills its tab, not the display — and
        // either would crowd out the status this row exists to report. The mark
        // is the one the title bar already uses for the same state.
        if item.isZoomed {
            cluster.addArrangedSubview(
                Chip(symbol: "arrow.up.left.and.arrow.down.right", hint: "A pane is zoomed"))
        }
        // A bell, because that is what it is. It sits before "current" so the
        // thing you armed reads the same whether or not you happen to be
        // standing in it.
        // Two different bells, because they promise different things. The
        // ringing one says "every time", and it has to be distinguishable at a
        // glance from the one that goes quiet after it fires — otherwise the
        // second press has no visible result and you cannot tell which you
        // asked for.
        switch item.bell {
        case .off:
            break
        case .once:
            cluster.addArrangedSubview(
                Chip(symbol: "bell.fill", hint: "Notifies you the next time this agent stops"))
        case .always:
            cluster.addArrangedSubview(Chip(
                symbol: "bell.and.waves.left.and.right.fill",
                hint: "Notifies you every time this agent stops"))
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
final class PaletteRowView: NSTableRowView {
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

/// The strip across the top of the panel that drags it.
///
/// This used to be an inert `NSView`, on the reasoning that a view overriding
/// nothing passes `mouseDown` up the responder chain and the overlay would pick
/// it up at the top. That is true of most of the strip and not of the part over
/// the search field's own rectangle, where the event stops somewhere before it
/// arrives — so the padding around the field dragged the panel and the field
/// itself did nothing, which is the part of the strip a pointer is most likely
/// to be on and the part that looks most like a title bar.
///
/// The same view is hit either way; only the outcome differed, and only by
/// where in that view the click was. Forwarding to the overlay on purpose
/// rather than relying on where an unhandled event drifts settles it.
@MainActor
final class PanelGrip: NSView {
    private var overlay: SwitcherOverlay? {
        sequence(first: self as NSView, next: { $0.superview })
            .lazy.compactMap { $0 as? SwitcherOverlay }.first
    }

    override func mouseDown(with event: NSEvent) { overlay?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { overlay?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { overlay?.mouseUp(with: event) }
}

/// A hairline that reads as a seam rather than as a system separator.
final class Divider: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        PaletteStyle.divider.setFill()
        bounds.fill()
    }
}

/// The rounded square a row's mark sits in.
private final class IconTile: NSView {
    private static let side: CGFloat = 24

    init(image artwork: NSImage?, symbol: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        // Clipped, so a mark that fills its tile takes the tile's corners
        // instead of showing its own square ones inside a rounded box.
        layer?.masksToBounds = true

        let image = NSImageView()
        let markSide: CGFloat

        if let artwork {
            if Self.paintsItsOwnBackground(artwork) {
                // Edge to edge, the way an app icon sits in a launcher — no
                // plate, because there is nothing for a plate to show through.
                // The hairline is what a near-black mark needs so it doesn't
                // read as a hole punched in a near-black panel, and it costs a
                // pixel where a plate would cost the whole tile.
                layer?.borderWidth = 1
                layer?.borderColor = PaletteStyle.border.cgColor
                markSide = Self.side
            } else {
                layer?.backgroundColor = PaletteStyle.markPlate.cgColor
                markSide = 16
            }
            image.image = artwork
            image.imageScaling = .scaleProportionallyUpOrDown
        } else {
            layer?.backgroundColor = PaletteStyle.tile.cgColor
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            image.contentTintColor = PaletteStyle.secondaryText
            markSide = Self.side
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: markSide),
            image.heightAnchor.constraint(equalToConstant: markSide),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether the mark paints to its own edges — a launcher icon rather than a
    /// glyph on nothing. One downsampled read, done once when the tile is built.
    ///
    /// Asked of the mark's own bounds rather than the file's. Plenty of icons
    /// ship with transparent padding baked in, and testing the outer ring of
    /// the image just measures that padding — every launcher icon came back
    /// "transparent" and got a plate it didn't need.
    ///
    /// This used to ask a second question — whether the ink was dark enough to
    /// need something light behind it — and answer it from the mark's average
    /// luminance. That is what put Claude's salmon glyph on the panel's black
    /// tile: mid-toned ink reads as "light enough", which is true of the ink
    /// and false of the mark, whose cut-out holes then fill in with the panel.
    /// Where a bare glyph sits is a matter of taste, not of arithmetic, so it
    /// is a setting now. See `PaletteStyle.markPlate`.
    private static func paintsItsOwnBackground(_ artwork: NSImage) -> Bool {
        guard let mark = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = pixels.withUnsafeMutableBytes({ bytes in
            CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return false }
        context.draw(mark, in: CGRect(x: 0, y: 0, width: side, height: side))

        func alpha(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * side + x) * 4 + 3]) / 255 }

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where alpha(x, y) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return false }

        var edgeOpaque = 0
        var edgeTotal = 0
        for y in minY...maxY {
            for x in minX...maxX where x == minX || y == minY || x == maxX || y == maxY {
                edgeTotal += 1
                if alpha(x, y) > 0.8 { edgeOpaque += 1 }
            }
        }
        return edgeTotal > 0 && Double(edgeOpaque) / Double(edgeTotal) > 0.75
    }
}

/// A small rounded label — tab counts, the "current" marker. Grey rather than
/// tinted: these annotate a row, they don't call for action, and an accent
/// colour on every row's right edge is noise.
private final class Chip: NSView {
    /// A chip carrying a mark instead of a word, for the states a word would
    /// be too long for. Same box, so it sits in the cluster like any other.
    convenience init(symbol: String, hint: String) {
        self.init(text: "")
        toolTip = hint
        subviews.forEach { $0.removeFromSuperview() }

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)
        image.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        image.contentTintColor = PaletteStyle.tertiaryText
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
        ])
    }

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
final class Keycap: NSView {
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
        layer?.borderColor = Settings.shared.effectiveAccent.withAlphaComponent(0.8).cgColor

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
            .backgroundColor: Settings.shared.effectiveAccent.withAlphaComponent(0.5),
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
        case #selector(NSResponder.moveRight(_:)):
            // Right arrow belongs to the field editor first — it is how you get
            // back through a query you are still editing. It only means "notify
            // me" at the very end of the text, where moving right would do
            // nothing anyway, so the two never compete for the same keystroke.
            let caret = textView.selectedRange()
            guard caret.length == 0,
                  caret.location >= (textView.string as NSString).length
            else { return false }
            toggleNotifyOnSelected()
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
