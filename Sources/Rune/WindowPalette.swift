import Cocoa

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
    }

    private let panel = NSView()
    private let backdrop = NSVisualEffectView()
    private let scrim = NSView()
    private let title = NSTextField(labelWithString: "Windows")
    private let subtitle = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let items: [Item]
    private let onCommit: (Int) -> Void
    private let onCancel: () -> Void

    private static let cornerRadius: CGFloat = 12
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 7

    var focusView: NSView { tableView }

    init(items: [Item], onCommit: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.items = items
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func cancel() { onCancel() }

    private func build() {
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Self.cornerRadius
        panel.layer?.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(backdrop)

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = PaletteStyle.background.cgColor
        scrim.layer?.cornerRadius = Self.cornerRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.layer?.borderWidth = 1
        scrim.layer?.borderColor = PaletteStyle.border.cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrim, positioned: .above, relativeTo: backdrop)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = PaletteStyle.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = PaletteStyle.tertiaryText
        subtitle.stringValue = items.count == 1
            ? "1 window"
            : "\(items.count) windows"
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(subtitle)

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(commit)
        tableView.addTableColumn(NSTableColumn(identifier: .init("window")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = items.count > Self.maxVisibleRows
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        let rows = min(max(items.count, 1), Self.maxVisibleRows)
        NSLayoutConstraint.activate([
            // The panel *is* this view's size. The overlay places this view by
            // its centre and its top and gives it nothing else, so anything
            // that does not pin all four edges leaves a view with no width to
            // draw into — which is a panel that opens and shows nothing.
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 460),

            backdrop.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: panel.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: panel.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scrollView.heightAnchor.constraint(
                equalToConstant: CGFloat(rows) * (Self.rowHeight + 2) + 12),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])

        let current = items.firstIndex(where: \.isCurrent) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
    }

    @objc private func commit() {
        guard items.indices.contains(tableView.selectedRow) else { return }
        onCommit(tableView.selectedRow)
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
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
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let item = items[safe: row] else { return nil }

        let name = NSTextField(labelWithString: item.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = PaletteStyle.primaryText

        // What the window is actually holding, named rather than counted. A
        // number tells you how much is in there; the names tell you whether it
        // is the one you are looking for.
        let contents = NSTextField(labelWithString: item.workspaces.joined(separator: " · "))
        contents.font = .systemFont(ofSize: 11)
        contents.textColor = PaletteStyle.tertiaryText
        contents.lineBreakMode = .byTruncatingTail
        contents.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, contents])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.spacing = 6
        cluster.addArrangedSubview(Chip(text: item.workspaces.count == 1
            ? "1 workspace"
            : "\(item.workspaces.count) workspaces"))
        if item.isCurrent {
            cluster.addArrangedSubview(Chip(text: "current", emphasised: true))
        }

        let icon = IconTile(image: nil as NSImage?, symbol: "macwindow")
        return PaletteRow(icon: icon, text: text, cluster: cluster)
    }
}
