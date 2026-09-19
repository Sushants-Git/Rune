import Cocoa

/// A preview may raise another window, but only this panel owns input.
@MainActor
final class WindowPickerPanel: NSPanel {
    weak var owner: TerminalController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Nil-target Edit actions otherwise continue into the main terminal window.
    @objc func copy(_ sender: Any?) {}
    @objc func cut(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}
    override func selectAll(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)),
            #selector(selectAll(_:))].contains(item.action) { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func toggleFullScreen(_ sender: Any?) {
        let controller = owner
        controller?.dismissSwitcher()
        controller?.window?.toggleFullScreen(sender)
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.owner?.dismissSwitcher()
        }
    }
}

@MainActor
private final class WindowPickerTable: NSTableView {
    weak var palette: WindowPalette?

    override func keyDown(with event: NSEvent) { palette?.keyDown(with: event) }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(palette)
    }
}

#if DEBUG
/// Run with RUNE_TEST_PICKER=1. Exercises real AppKit routing and terminal state
/// without system input synthesis or Accessibility permission.
@MainActor
enum WindowPickerRegression {
    static func run(_ origin: TerminalController, delegate: AppDelegate) {
        guard let second = delegate.newWindow(), let third = delegate.newWindow() else {
            fatalError("Could not create test windows")
        }
        let controllers = [origin, second, third]
        for controller in controllers {
            controller.newTab()
            controller.selectTab(at: 0)
            controller.newWorkspace()
            controller.newTab()
            controller.selectTab(at: 0)
            controller.selectWorkspace(at: 0)
        }
        let workspaces = controllers.map(\.workspaces)
        let tabs = workspaces.map { $0.map(\.tabs) }

        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        func open() -> (WindowPalette, [NSTableView]) {
            origin.window?.makeKeyAndOrderFront(nil)
            origin.showWindows()
            guard let palette = origin.overlay?.panel as? WindowPalette else {
                fatalError("Picker did not open")
            }
            let lists = tables(in: palette)
            precondition(lists.count == 2)
            return (palette, lists)
        }
        func select(_ table: NSTableView, _ row: Int) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let (palette, lists) = open()
        guard let host = palette.window as? WindowPickerPanel else { fatalError("Missing host") }
        for action in [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)),
                       #selector(NSText.paste(_:)), #selector(NSResponder.selectAll(_:))] {
            let item = NSMenuItem(title: "Edit", action: action, keyEquivalent: "")
            precondition(!host.validateUserInterfaceItem(item), "Editing must be disabled")
            let target = NSApp.target(forAction: action) as AnyObject?
            precondition(target !== origin.activeSurface, "Edit action escaped into terminal")
            // Paste in particular must resolve to the inert panel, not merely
            // appear disabled while a direct sendAction still reaches a shell.
            if action == #selector(NSText.paste(_:)) { precondition(target === host) }
        }
        select(lists[0], 1)
        select(lists[1], 3)
        precondition(second.activeTab === tabs[1][1][1])
        select(lists[0], 2)
        select(lists[1], 3)
        select(lists[1], 1)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: host.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        palette.keyDown(with: enter)
        precondition(origin.overlay == nil)
        precondition(second.activeWorkspace === workspaces[1][0])
        precondition(workspaces[1][1].activeTab === tabs[1][1][0], "Unrelated preview survived commit")
        precondition(third.activeTab === tabs[2][0][1], "Destination was not committed")
        precondition(workspaces[2][1].activeTab === tabs[2][1][0])

        let (_, cancelLists) = open()
        select(cancelLists[0], 1)
        select(cancelLists[1], 3)
        origin.dismissSwitcher()
        precondition(origin.overlay == nil)
        precondition(origin.activeWorkspace === workspaces[0][0])
        precondition(second.activeWorkspace === workspaces[1][0])
        precondition(workspaces[1][1].activeTab === tabs[1][1][0])
        precondition(NSApp.keyWindow === origin.window)
        precondition(origin.window?.firstResponder === origin.activeSurface)

        let (_, workspaceLists) = open()
        select(workspaceLists[1], 3)
        origin.selectWorkspace(at: 1)
        precondition(origin.overlay == nil)
        precondition(origin.activeWorkspace === workspaces[0][1], "Cancellation undid workspace command")
        precondition(origin.activeTab === tabs[0][1][0])

        origin.selectWorkspace(at: 0)
        let (_, relativeLists) = open()
        select(relativeLists[1], 3)
        origin.selectRelativeTab(offset: 1)
        precondition(origin.activeWorkspace === workspaces[0][0])
        precondition(origin.activeTab === tabs[0][0][1], "Relative action used preview rather than origin")

        // Closing a tab steps one along the row, and closing some *other* tab
        // leaves you where you are. Both used to be wrong: the survivor was the
        // most recently used tab, so closing the third of several could land
        // you on the first, and a successor was chosen even when the tab that
        // closed was not the one you were in.
        origin.selectWorkspace(at: 0)
        guard let workspace = origin.activeWorkspace else { fatalError("No workspace") }
        while workspace.tabs.count < 4 { origin.newTab() }
        origin.selectTab(at: 1)
        let neighbour = workspace.tabs[2]
        origin.closeTab(workspace.tabs[1])
        precondition(origin.activeTab === neighbour, "Closing a tab should step one along the row")
        origin.selectTab(at: workspace.tabs.count - 1)
        let last = workspace.tabs[workspace.tabs.count - 1]
        origin.closeTab(workspace.tabs[0])
        precondition(origin.activeTab === last, "Closing another tab moved the active one")
        origin.closeTab(last)
        precondition(origin.activeTab === workspace.tabs.last, "Closing the last tab should land on the new last")

        origin.showSessions()
        precondition(origin.overlay != nil)
        origin.openSession(.live(target: UUID(), title: "Closed", directory: "/tmp"))
        precondition(origin.overlay == nil, "Failed live session left a stopped overlay")
        origin.showSessions()
        origin.openSession(AgentHistory.Session(id: "missing", title: "Missing resume", directory: "/tmp", updatedAt: Date()))
        precondition(origin.overlay == nil, "Missing resume left a stopped overlay")
        print("PASS: picker editing isolation, preview rollback/commit, workspace and relative commands, tab close succession, session failure cleanup")
        for controller in controllers {
            for surface in controller.allSurfaces { surface.close() }
        }
        exit(0)
    }
}
#endif

/// Every window at once, in the switcher's panel.
///
/// ⌘K answers "which workspace", and answers it inside one window. With three
/// windows open there was no view of the whole thing at all: you learned what
/// was where by cycling through windows and reading their tab strips. This is
/// the layer above — the windows, what each is holding, and a way into any of
/// them.
///
/// Deliberately read-only. It is a map, and a map you can accidentally
/// rearrange is a worse map; moving a workspace between windows is `←` in ⌘K,
/// where the thing being moved is the thing under the highlight.
@MainActor
final class WindowPalette: NSView, OverlayPanel {
    /// One window, as this panel sees it.
    struct Item {
        let number: Int
        let title: String
        /// The workspaces in it, in the order that window lists them.
        let workspaces: [String]
        let isCurrent: Bool
        /// What that window is showing, so a row can be recognised rather than
        /// counted. Same mark ⌘K puts on the workspace.
        var icon: NSImage? = nil
        var entries: [Entry] = []
    }

    struct Entry {
        let title: String
        let subtitle: String
        let isCurrent: Bool
        var icon: NSImage? = nil
    }

    private let panel = NSView()
    private let backdrop: NSView
    private let scrim = NSView()
    private let windowsHeader = NSTextField(labelWithString: "WINDOWS")
    private let entriesHeader = NSTextField(labelWithString: "WORKSPACES & TABS")
    private let tableView = WindowPickerTable()
    private let scrollView = NSScrollView()
    private let detailTable = WindowPickerTable()
    private let detailScroll = NSScrollView()
    private var rightPane = false
    private var updating = false

    private let items: [Item]
    private let onCommit: (Int, Int?) -> Void
    private let onPreview: (Int, Int?) -> Void
    private let onCancel: () -> Void

    private static let cornerRadius: CGFloat = 8
    /// The same numbers ⌘K uses. `PaletteRow` works its own padding out from
    /// them, so a panel with a different width or a different scroll inset gets
    /// rows whose contents sit slightly wrong — which is most of why this
    /// looked off beside the switcher it is supposed to match.
    private static let width: CGFloat = 720
    private static let listWidth: CGFloat = 268
    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 7

    var focusView: NSView { self }

    init(items: [Item], onPreview: @escaping (Int, Int?) -> Void,
         onCommit: @escaping (Int, Int?) -> Void, onCancel: @escaping () -> Void) {
        self.items = items
        self.onCommit = onCommit
        self.onPreview = onPreview
        self.onCancel = onCancel
        // A window of its own, so what is worth sampling really is behind the
        // whole window rather than inside it.
        self.backdrop = SwitcherPalette.makeBackdrop(
            cornerRadius: Self.cornerRadius, behindWindow: true)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func cancel() { onCancel() }

    private func build() {
        tableView.palette = self
        detailTable.palette = self
        tableView.setAccessibilityLabel("Windows")
        detailTable.setAccessibilityLabel("Workspaces and tabs")
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Self.cornerRadius
        panel.layer?.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(backdrop)

        // The same scrim ⌘K and ⌘L use, rather than an opaque slab. It was the
        // one picker that painted itself solid, which is why it read as a
        // different piece of software from the other two.
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = PaletteStyle.scrim.cgColor
        scrim.layer?.cornerRadius = Self.cornerRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.layer?.borderWidth = 1
        scrim.layer?.borderColor = PaletteStyle.border.cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrim, positioned: .above, relativeTo: backdrop)

        // One header per column, each sitting over its own rows. There used to
        // be a single "Windows / Workspaces & Tabs" title over both of them,
        // which named the two lists in the one place that could not show you
        // where either began.
        for header in [windowsHeader, entriesHeader] {
            header.font = PaletteStyle.font(ofSize: 11, weight: .semibold)
            header.textColor = PaletteStyle.tertiaryText
            header.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(header)
        }

        for table in [tableView, detailTable] {
            table.headerView = nil
            table.rowHeight = Self.rowHeight
            table.backgroundColor = .clear
            // Stays `.regular` so rows are asked to draw a selection at all;
            // PaletteRowView then replaces AppKit's full-bleed bar.
            table.selectionHighlightStyle = .regular
            // The same as ⌘K, and it has to be: `.inset` adds AppKit's own
            // horizontal padding on top of the row's, so the icons sat further
            // in than the header above them, and the trailing chips further out.
            table.style = .plain
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(commit)
        }
        tableView.addTableColumn(NSTableColumn(identifier: .init("window")))
        detailTable.addTableColumn(NSTableColumn(identifier: .init("entry")))

        for (scroll, table) in [(scrollView, tableView), (detailScroll, detailTable)] {
            scroll.documentView = table
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            // The gap above the first row and the gap below the last both come
            // from here, so they cannot drift apart.
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(scroll)
        }

        let headerDivider = Divider()
        let columnDivider = Divider(vertical: true)
        let footerDivider = Divider()
        let hints = PaletteHints.bar([
            (["←", "→"], "Pane"),
            (["↑", "↓"], "Preview"),
            (["⏎"], "Open"),
            (["esc"], "Dismiss"),
        ])
        for view in [headerDivider, columnDivider, footerDivider, hints] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }

        // The list is as tall as it needs to be, capped. Seven rows' worth of
        // panel opened for two windows holding one workspace each, and most of
        // what ⌘J showed was empty space with a hairline round it.
        let deepest = items.map(\.entries.count).max() ?? 0
        let rows = min(max(max(items.count, deepest), 1), Self.maxVisibleRows)
        // Where a row's contents actually start, so a header can line up with
        // the icons underneath it rather than with the panel's edge.
        let rowText = SwitcherPalette.contentInset - SwitcherPalette.rowInset

        NSLayoutConstraint.activate([
            // The panel *is* this view's size. The overlay places this view by
            // its centre and its top and gives it nothing else, so anything
            // that does not pin all four edges leaves a view with no width to
            // draw into — which is a panel that opens and shows nothing.
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),

            backdrop.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: panel.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: panel.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            windowsHeader.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor, constant: rowText),
            windowsHeader.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            entriesHeader.leadingAnchor.constraint(
                equalTo: detailScroll.leadingAnchor, constant: rowText),
            entriesHeader.firstBaselineAnchor.constraint(
                equalTo: windowsHeader.firstBaselineAnchor),

            headerDivider.topAnchor.constraint(equalTo: windowsHeader.bottomAnchor, constant: 12),
            headerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            scrollView.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: SwitcherPalette.rowInset),
            scrollView.widthAnchor.constraint(equalToConstant: Self.listWidth),
            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.heightAnchor.constraint(
                equalToConstant: CGFloat(rows) * Self.rowHeight + 12),

            columnDivider.leadingAnchor.constraint(
                equalTo: scrollView.trailingAnchor, constant: SwitcherPalette.rowInset),
            columnDivider.topAnchor.constraint(equalTo: scrollView.topAnchor),
            columnDivider.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            detailScroll.leadingAnchor.constraint(
                equalTo: columnDivider.trailingAnchor, constant: SwitcherPalette.rowInset),
            detailScroll.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -SwitcherPalette.rowInset),
            detailScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            footerDivider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9),
            hints.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -SwitcherPalette.contentInset),
            hints.leadingAnchor.constraint(
                greaterThanOrEqualTo: panel.leadingAnchor,
                constant: SwitcherPalette.contentInset),
            hints.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -9),
        ])

        let current = items.firstIndex(where: \.isCurrent) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
        syncActivePane()
    }

    @objc private func commit() {
        guard items.indices.contains(tableView.selectedRow) else { return }
        onCommit(tableView.selectedRow, rightPane ? detailTable.selectedRow : nil)
    }

    private func move(by delta: Int) {
        let table = rightPane ? detailTable : tableView
        guard table.numberOfRows > 0 else { return }
        let next = min(max(table.selectedRow + delta, 0), table.numberOfRows - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Say which column the arrow keys are in, without making the other one
    /// harder to read.
    ///
    /// This used to drop the idle table to 65% opacity, which faded its text
    /// along with its highlight — the column you were not in became the column
    /// you could not read, in a panel whose whole job is being read. Now the
    /// live column keeps the filled pill, the idle one gets an outline, and the
    /// header of whichever is live brightens.
    private func syncActivePane() {
        windowsHeader.textColor = rightPane ? PaletteStyle.tertiaryText : PaletteStyle.secondaryText
        entriesHeader.textColor = rightPane ? PaletteStyle.secondaryText : PaletteStyle.tertiaryText
        for (table, live) in [(tableView, !rightPane), (detailTable, rightPane)] {
            table.enumerateAvailableRowViews { view, _ in
                (view as? PaletteRowView)?.isDimmed = !live
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124:
            rightPane = event.keyCode == 124
            syncActivePane()
            onPreview(tableView.selectedRow, rightPane ? detailTable.selectedRow : nil)
        case 126: move(by: -1)          // up
        case 125: move(by: 1)           // down
        case 36, 76: commit()           // return, enter
        case 53: cancel()               // escape
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

extension WindowPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === detailTable ? (items[safe: self.tableView.selectedRow]?.entries.count ?? 0) : items.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        updating = true
        if notification.object as? NSTableView === tableView {
            rightPane = false
            detailTable.reloadData()
            let entries = items[safe: tableView.selectedRow]?.entries ?? []
            if !entries.isEmpty {
                detailTable.selectRowIndexes(IndexSet(integer: entries.firstIndex(where: \.isCurrent) ?? 0), byExtendingSelection: false)
            }
        } else {
            rightPane = true
        }
        updating = false
        syncActivePane()
        window?.makeFirstResponder(self)
        onPreview(tableView.selectedRow, rightPane ? detailTable.selectedRow : nil)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = PaletteRowView()
        view.isDimmed = (tableView === detailTable) != rightPane
        return view
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        if tableView === detailTable {
            guard let entry = items[safe: self.tableView.selectedRow]?.entries[safe: row] else { return nil }
            let name = NSTextField(labelWithString: entry.title)
            name.font = PaletteStyle.font(ofSize: 13, weight: .medium)
            name.textColor = PaletteStyle.primaryText
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(labelWithString: entry.subtitle)
            detail.font = PaletteStyle.font(ofSize: 11)
            detail.textColor = PaletteStyle.tertiaryText
            detail.lineBreakMode = .byTruncatingHead
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [name, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            let cluster = NSStackView()
            cluster.orientation = .horizontal
            cluster.alignment = .centerY
            cluster.spacing = 6
            if entry.isCurrent {
                cluster.addArrangedSubview(Chip(text: "current", emphasised: true))
            }
            // The same mark ⌘K puts on the row. Every tab in here used to be a
            // grey terminal glyph, so the one column that says *what* is in a
            // window said it in words only, and three rows of Claude looked
            // exactly like three rows of shell.
            return PaletteRow(
                icon: IconTile(image: entry.icon, symbol: "terminal"),
                text: text, cluster: cluster)
        }
        guard let item = items[safe: row] else { return nil }

        let heading = NSMutableAttributedString(string: item.title, attributes: [
            .font: PaletteStyle.font(ofSize: 13, weight: .medium),
            .foregroundColor: PaletteStyle.primaryText,
        ])
        // The count rides with the name rather than taking a chip of its own.
        // It is the least interesting thing on the row and was the widest.
        heading.append(NSAttributedString(
            string: item.workspaces.count == 1 ? "  1 workspace" : "  \(item.workspaces.count) workspaces",
            attributes: [
                .font: PaletteStyle.font(ofSize: 11),
                .foregroundColor: PaletteStyle.tertiaryText,
            ]))
        let name = NSTextField(labelWithAttributedString: heading)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // What the window is holding, named rather than counted. A count says
        // how much is in there; the names say whether it is the one you want.
        let subtitle = NSTextField(
            labelWithString: item.workspaces.joined(separator: "  ·  "))
        subtitle.font = PaletteStyle.font(ofSize: 11)
        subtitle.textColor = PaletteStyle.tertiaryText
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        // No activity here. This is a map of where things are, and ⌘K is where
        // you go to find out what any of them is doing — putting "working" on a
        // window makes the overview a second status board reporting a summary
        // of a summary.
        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 6
        if item.isCurrent {
            cluster.addArrangedSubview(Chip(text: "current", emphasised: true))
        }

        return PaletteRow(
            icon: IconTile(image: item.icon, symbol: "macwindow"),
            text: text, cluster: cluster)
    }
}
