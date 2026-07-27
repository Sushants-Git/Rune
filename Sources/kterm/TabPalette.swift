import Cocoa

/// The Cmd-K tab switcher: a centered, translucent overlay with a filter field
/// and a list of open terminals.
///
/// This is how you move between tabs in kterm — there is no tab bar — so it
/// aims to be fast to use blind: it opens with the previously-used tab already
/// selected, so Cmd-K, Enter is a toggle.
@MainActor
final class TabPalette: NSView {
    let searchField = NSTextField()

    /// Pulled fresh rather than snapshotted: a background shell can exit while
    /// the switcher is open, and selecting a closed tab would resurrect a dead
    /// surface.
    private let currentTabs: () -> [GhosttySurfaceView]
    private var filtered: [GhosttySurfaceView]
    private var selection = 0

    private let onComplete: (GhosttySurfaceView?) -> Void

    private let panel = NSVisualEffectView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private static let rowHeight: CGFloat = 34
    private static let panelWidth: CGFloat = 460
    private static let maxVisibleRows = 9

    init(
        tabs: @escaping () -> [GhosttySurfaceView],
        onComplete: @escaping (GhosttySurfaceView?) -> Void
    ) {
        self.currentTabs = tabs
        self.filtered = tabs()
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
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
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

            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 9),
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
        let tabs = currentTabs()
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

        // One dense line per terminal: title, then the directory, then a badge
        // for the ⌘N terminals that have no chip in the tab strip.
        // The name, then the directory. Shell titles are `user@host:/the/path`,
        // so showing the full title next to the path would print the same thing
        // twice — `shortTitle` collapses that, and leaves real command titles
        // (vim, ssh, …) intact.
        let name = tab.shortTitle
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let directory = tab.pwd.map(abbreviateHome) ?? ""
        let path = NSTextField(labelWithString: directory == name ? "" : directory)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, path])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        if tab.kind == .background {
            let badge = NSTextField(labelWithString: "⌘K")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(NSView())  // spacer
            stack.addArrangedSubview(badge)
        }

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
