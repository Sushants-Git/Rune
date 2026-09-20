import Cocoa

/// ⌘; — the apps in the Dock, and a key to quit one.
///
/// The same panel as the other pickers, over a shorter question: what is
/// running, and get rid of it. `→` quits the highlighted app the way ⌘Q does;
/// an app that ignores that (a document with unsaved changes, something
/// wedged) is *said* to be ignoring it, and a second `→` forces it. Nothing
/// here kills without asking twice.
///
/// Rune itself is left out. Quitting the app you are quitting things from is
/// a trick, not a feature, and ⌘Q is right there.
@MainActor
final class AppsPalette: NSView, OverlayPanel {
    /// One row: the app, plus what the last `→` did to it.
    private struct Entry {
        let app: NSRunningApplication
        var asked: Date?
        var forced = false

        var id: pid_t { app.processIdentifier }
        /// Asked to quit and still here after a moment: it isn't going to.
        var isRefusing: Bool {
            guard let asked else { return false }
            return Date().timeIntervalSince(asked) > 2.5
        }
    }

    private let onCancel: () -> Void

    private var entries: [Entry] = []
    private var visible: [Entry] = []

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "No apps match")
    private let status = NSTextField(labelWithString: "")
    private var quitHint: HintPair!
    private var ticker: Timer?

    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 40
    private static let visibleRows = 9
    private static let cornerRadius: CGFloat = 8

    var focusView: NSView { field }

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        reload(keepSelection: false)

        // The list is live: apps come and go while it is open, and a row that
        // was asked to quit has to disappear when it does.
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            centre.addObserver(
                self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        // And a slow tick, because "it is refusing to quit" is a fact about
        // elapsed time that no notification announces.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepSelection: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        // The timer and the observers are dropped in `stop`, which every way
        // out of the panel goes through; `deinit` on a @MainActor type may not
        // touch either.
    }

    func cancel() {
        stop()
        onCancel()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, superview == nil { stop() }
    }

    // MARK: - Chrome

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous

        let backdrop = SwitcherPalette.makeBackdrop(cornerRadius: Self.cornerRadius)
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = PaletteStyle.scrim.cgColor
        scrim.layer?.cornerRadius = Self.cornerRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.layer?.borderColor = PaletteStyle.border.cgColor
        scrim.layer?.borderWidth = 1
        for view in [backdrop, scrim] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        field.font = PaletteStyle.font(ofSize: 15, weight: .regular)
        field.textColor = PaletteStyle.primaryText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderAttributedString = NSAttributedString(
            string: "Search open apps…",
            attributes: [
                .foregroundColor: PaletteStyle.tertiaryText,
                .font: PaletteStyle.font(ofSize: 15),
            ])
        field.setAccessibilityLabel("Search open apps")

        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.refusesFirstResponder = true
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)
        table.addTableColumn(NSTableColumn(identifier: .init("app")))
        table.setAccessibilityLabel("Open apps")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        empty.font = PaletteStyle.font(ofSize: 12)
        empty.textColor = PaletteStyle.tertiaryText
        empty.alignment = .center
        empty.isHidden = true

        status.font = PaletteStyle.font(ofSize: 10.5)
        status.textColor = PaletteStyle.tertiaryText
        status.lineBreakMode = .byTruncatingTail

        quitHint = HintPair(keys: ["→"], label: "Quit")
        let hints = NSStackView(views: [
            HintPair(keys: ["↵"], label: "Switch to"), quitHint,
            HintPair(keys: ["esc"], label: "Dismiss"),
        ])
        hints.orientation = .horizontal
        hints.spacing = 16
        hints.setContentHuggingPriority(.required, for: .horizontal)

        let headerDivider = Divider()
        let footerDivider = Divider()
        let prompt = PalettePrompt.make()
        addSubview(prompt)
        for view in [field, headerDivider, scroll, empty, footerDivider, status, hints] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let inset = SwitcherPalette.contentInset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            prompt.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 8),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            headerDivider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 15),
            headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(
                equalToConstant: CGFloat(Self.visibleRows) * Self.rowHeight + 12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            footerDivider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            status.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -12),
            hints.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            hints.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9),
            hints.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    // MARK: - The list

    @objc private func workspaceChanged() { reload(keepSelection: true) }

    /// The apps with a Dock icon, in name order, minus Rune.
    private func reload(keepSelection: Bool) {
        let selected = keepSelection ? visible[safe: table.selectedRow]?.id : nil
        let asked = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = ProcessInfo.processInfo.processIdentifier

        entries = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != mine }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "")
                    == .orderedAscending
            }
            .map { app in
                var entry = Entry(app: app)
                if let previous = asked[app.processIdentifier] {
                    entry.asked = previous.asked
                    entry.forced = previous.forced
                }
                return entry
            }

        applyFilter(selecting: selected)
    }

    private func applyFilter(selecting id: pid_t?) {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = query.isEmpty ? entries : entries.filter {
            AgentHistory.matchRanges(query, in: $0.app.localizedName ?? "") != nil
        }
        table.reloadData()
        if !visible.isEmpty {
            let row = visible.firstIndex { $0.id == id } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        empty.isHidden = !visible.isEmpty
        empty.stringValue = entries.isEmpty ? "Nothing else is running" : "No apps match"
        status.stringValue = "\(visible.count) \(visible.count == 1 ? "app" : "apps")"
        syncQuitHint()
    }

    /// The `→` hint says what the *next* press will do to the highlighted row.
    private func syncQuitHint() {
        guard let entry = visible[safe: table.selectedRow] else {
            quitHint.setLabel("Quit")
            return
        }
        quitHint.setLabel(entry.isRefusing ? "Force quit" : (entry.asked == nil ? "Quit" : "Quitting…"))
    }

    // MARK: - Doing things

    /// `→`: ask the app to quit; on a row that has been asked and stayed, and
    /// has had a moment to go, force it.
    private func quitSelected() {
        guard let row = visible.indices.contains(table.selectedRow) ? table.selectedRow : nil
        else { return }
        let entry = visible[row]
        guard !entry.app.isTerminated else { reload(keepSelection: true); return }

        if entry.isRefusing, !entry.forced {
            entry.app.forceTerminate()
            mark(entry.id) { $0.forced = true }
        } else if entry.asked == nil {
            entry.app.terminate()
            mark(entry.id) { $0.asked = Date() }
        } else {
            // Asked a moment ago and still closing: let it close.
            NSSound.beep()
        }
        applyFilter(selecting: entry.id)
    }

    private func mark(_ id: pid_t, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// `↵`: go to the app. Quitting things is what this list is for, but the
    /// answer to "what is this?" is often "show me".
    @objc private func activate() {
        guard let entry = visible[safe: table.selectedRow] else { return }
        entry.app.activate(options: [.activateAllWindows])
        cancel()
    }

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), visible.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        syncQuitHint()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 124: quitSelected()
        case 36, 76: activate()
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}

extension AppsPalette: NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applyFilter(selecting: visible[safe: table.selectedRow]?.id)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = PaletteStyle.accent
        editor.selectedTextAttributes = [
            .backgroundColor: PaletteStyle.accent.withAlphaComponent(0.4),
            .foregroundColor: PaletteStyle.primaryText,
        ]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)): activate()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.moveRight(_:)):
            // Only where it would do nothing in the text, as ⌘K's keys are.
            let caret = textView.selectedRange()
            guard caret.length == 0, caret.location >= (textView.string as NSString).length
            else { return false }
            quitSelected()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableViewSelectionDidChange(_ notification: Notification) { syncQuitHint() }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = visible[safe: row] else { return nil }
        let app = entry.app

        let icon = NSImageView()
        icon.image = app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let name = NSTextField(labelWithString: app.localizedName ?? "Unnamed")
        name.font = PaletteStyle.font(ofSize: 13)
        name.textColor = PaletteStyle.primaryText
        name.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name])
        text.orientation = .horizontal
        text.alignment = .centerY
        text.spacing = 9

        if app.isHidden {
            let hidden = NSTextField(labelWithString: "hidden")
            hidden.font = PaletteStyle.font(ofSize: 11)
            hidden.textColor = PaletteStyle.tertiaryText
            text.addArrangedSubview(hidden)
        }

        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 8
        if entry.forced {
            cluster.addArrangedSubview(Chip(text: "forced"))
        } else if entry.isRefusing {
            cluster.addArrangedSubview(Chip(text: "→ again to force", emphasised: true))
        } else if entry.asked != nil {
            cluster.addArrangedSubview(Chip(text: "quitting…"))
        }
        if app.isActive {
            cluster.addArrangedSubview(CurrentMark("The app you were in"))
        }

        let view = PaletteRow(icon: icon, text: text, cluster: cluster)
        view.toolTip = [app.localizedName, app.bundleIdentifier, "pid \(app.processIdentifier)"]
            .compactMap { $0 }.joined(separator: "\n")
        return view
    }
}
