import Cocoa

/// The Cmd-K tab switcher: a centered, translucent overlay with a filter field
/// and a list of open terminals.
///
/// This is how you move between tabs in kterm — there is no tab bar — so it
/// aims to be fast to use blind: it opens with the previously-used tab already
/// selected, so Cmd-K, Enter is a toggle.
@MainActor
final class TabPalette: NSView {
    let searchField = PaletteSearchField()

    private let tabs: [GhosttySurfaceView]
    private var filtered: [GhosttySurfaceView]
    private var selection = 0

    private let onComplete: (GhosttySurfaceView?) -> Void

    private let panel = NSVisualEffectView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private static let rowHeight: CGFloat = 44
    private static let panelWidth: CGFloat = 560
    private static let maxVisibleRows = 8

    init(tabs: [GhosttySurfaceView], onComplete: @escaping (GhosttySurfaceView?) -> Void) {
        self.tabs = tabs
        self.filtered = tabs
        self.onComplete = onComplete
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor

        buildPanel()
        // Preselect the first entry, which the controller orders as the
        // previously-used tab.
        selection = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildPanel() {
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        searchField.placeholderString = "Switch to terminal…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.palette = self
        panel.addSubview(searchField)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(divider)

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.addTableColumn(NSTableColumn(identifier: .init("tab")))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)

        let rows = min(max(filtered.count, 1), Self.maxVisibleRows)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            panel.widthAnchor.constraint(equalToConstant: Self.panelWidth),

            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: CGFloat(rows) * Self.rowHeight),
        ])

        tableView.reloadData()
        syncSelection()
    }

    // MARK: - Filtering

    func reload() {
        applyFilter(searchField.stringValue)
    }

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filtered = tabs
        } else {
            filtered = tabs
                .compactMap { tab -> (GhosttySurfaceView, Int)? in
                    let haystack = "\(tab.displayTitle) \(tab.pwd ?? "")"
                    guard let score = FuzzyMatch.score(needle: trimmed, haystack: haystack) else {
                        return nil
                    }
                    return (tab, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        selection = 0
        tableView.reloadData()
        syncSelection()
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = (selection + delta % filtered.count + filtered.count) % filtered.count
        syncSelection()
    }

    private func syncSelection() {
        guard !filtered.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    func commit() {
        guard filtered.indices.contains(selection) else {
            onComplete(nil)
            return
        }
        onComplete(filtered[selection])
    }

    func cancel() {
        onComplete(nil)
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else { return }
        onComplete(filtered[row])
    }

    // Clicking the dimmed backdrop dismisses.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { cancel() }
    }
}

// MARK: - Table data

extension TabPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let tab = filtered[row]

        let title = NSTextField(labelWithString: tab.displayTitle)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: tab.pwd.map(abbreviateHome) ?? "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if filtered.indices.contains(row) { selection = row }
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Search field

extension TabPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applyFilter(searchField.stringValue)
    }
}

/// Text field that routes navigation keys to the palette instead of letting
/// AppKit's field editor consume them.
@MainActor
final class PaletteSearchField: NSTextField {
    weak var palette: TabPalette?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: palette?.moveSelection(by: -1)   // up
        case 125: palette?.moveSelection(by: 1)    // down
        case 36, 76: palette?.commit()             // return, enter
        case 53: palette?.cancel()                 // escape
        default:
            // Ctrl-P / Ctrl-N for people who navigate that way.
            if event.modifierFlags.contains(.control),
               let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "p": palette?.moveSelection(by: -1); return
                case "n": palette?.moveSelection(by: 1); return
                default: break
                }
            }
            super.keyDown(with: event)
        }
    }
}

// MARK: - Fuzzy matching

enum FuzzyMatch {
    /// Score `needle` as a subsequence of `haystack`, or nil if it isn't one.
    /// Higher is better: consecutive matches and word-boundary hits score more.
    static func score(needle: String, haystack: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        guard !n.isEmpty else { return 0 }

        var score = 0
        var ni = 0
        var lastMatch = -1

        for (hi, ch) in h.enumerated() {
            guard ni < n.count, ch == n[ni] else { continue }

            score += 1
            if lastMatch == hi - 1 { score += 4 }
            if hi == 0 || h[hi - 1] == " " || h[hi - 1] == "/" || h[hi - 1] == "-" { score += 3 }

            lastMatch = hi
            ni += 1
        }

        return ni == n.count ? score : nil
    }
}
