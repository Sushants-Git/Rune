import Cocoa

/// Cmd-L's native palette. The controller supplies live rows (Session.live),
/// presents this in SwitcherOverlay, and handles the selected row:
/// - liveTarget != nil: focus that exact surface, without launching anything.
/// - otherwise: launch resume.shellCommand in a new terminal.
/// Discovery, search and preview never read terminal surfaces or run commands.
@MainActor
final class SessionPalette: NSView, OverlayPanel {
    private let supplied: [AgentHistory.Session]
    private let onSelect: (AgentHistory.Session) -> Void
    private let onCancel: () -> Void
    private var sessions: [AgentHistory.Session]
    private var visible: [AgentHistory.Session] = []
    private var excerpts: [String: String] = [:]
    private var discoveryNotes = ""
    private var discovering = true
    private var searching = false
    private var filtering = false
    private var contentQuery: String?
    private var contentIncomplete = false
    private var dismissed = false
    private var generation = 0
    private var previewGeneration = 0
    private var discoveryTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    private let field = NSSearchField()
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let previewScroll = NSScrollView()
    private let previewText = NSTextView()
    private let status = NSTextField(labelWithString: "Discovering saved sessions...")
    private let previewHeading = NSTextField(labelWithString: "Transcript Preview")
    private let searchButton = NSButton(title: "Search Content", target: nil, action: nil)
    private let resetButton = NSButton(title: "Metadata", target: nil, action: nil)
    private let hints = NSTextField(labelWithString: "Return: focus / resume    Control-F: search content    Esc: close")

    var focusView: NSView { field }

    init(sessions: [AgentHistory.Session],
         onSelect: @escaping (AgentHistory.Session) -> Void,
         onCancel: @escaping () -> Void) {
        supplied = sessions
        self.sessions = AgentHistory.merge(sessions, with: [])
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        apply(self.sessions)
        discoveryTask = Task { [weak self] in
            let result = await AgentHistory.discover()
            guard !Task.isCancelled, let self, !self.dismissed else { return }
            self.discovering = false
            self.discoveryNotes = result.notes.joined(separator: " ")
            self.sessions = AgentHistory.merge(self.supplied, with: result.sessions)
            if let query = self.contentQuery {
                // Content results were computed over an older corpus. Re-run
                // only the explicitly requested query, never a new typed query.
                self.runContentSearch(query)
            } else {
                self.filterMetadata()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        discoveryTask?.cancel()
        searchTask?.cancel()
        previewTask?.cancel()
    }

    func cancel() {
        guard !dismissed else { return }
        stop()
        onCancel()
    }

    private func stop() {
        dismissed = true
        generation += 1
        previewGeneration += 1
        discoveryTask?.cancel()
        searchTask?.cancel()
        previewTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Replacement by another overlay need not call cancel().
        if window == nil, superview == nil { stop() }
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        let backdrop = SwitcherPalette.makeBackdrop(cornerRadius: 12)
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = PaletteStyle.scrim.cgColor
        scrim.layer?.cornerRadius = 12
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

        field.placeholderString = "Search sessions by title, agent, or directory"
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Search agent sessions")

        searchButton.target = self
        searchButton.action = #selector(searchContent)
        searchButton.bezelStyle = .rounded
        searchButton.controlSize = .small
        searchButton.keyEquivalent = "f"
        searchButton.keyEquivalentModifierMask = .control
        searchButton.toolTip = "Search saved conversation text for the current query (Control-F)."
        resetButton.target = self
        resetButton.action = #selector(resetMetadata)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.isHidden = true

        for label in [status, previewHeading, hints] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = PaletteStyle.tertiaryText
            label.lineBreakMode = .byTruncatingTail
        }
        previewHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        previewHeading.textColor = PaletteStyle.secondaryText

        table.headerView = nil
        table.rowHeight = 46
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(commit)
        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.setAccessibilityLabel("Live and saved sessions")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.autohidesScrollers = true

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.isRichText = false
        previewText.isAutomaticLinkDetectionEnabled = false
        previewText.isAutomaticDataDetectionEnabled = false
        previewText.drawsBackground = false
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textColor = PaletteStyle.secondaryText
        previewText.textContainerInset = NSSize(width: 8, height: 8)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewText.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        previewText.setAccessibilityLabel("Plain text transcript preview")
        previewScroll.documentView = previewText
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true

        let divider = Divider()
        for view in [field, searchButton, resetButton, status, listScroll, divider, previewHeading, previewScroll, hints] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SwitcherPalette.width),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            field.heightAnchor.constraint(equalToConstant: 26),
            searchButton.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            searchButton.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            resetButton.leadingAnchor.constraint(equalTo: searchButton.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            status.topAnchor.constraint(equalTo: searchButton.bottomAnchor, constant: 6),
            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherPalette.rowInset),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SwitcherPalette.rowInset),
            listScroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            listScroll.heightAnchor.constraint(equalToConstant: 184),
            divider.topAnchor.constraint(equalTo: listScroll.bottomAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewHeading.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            previewHeading.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            previewHeading.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            previewScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            previewScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            previewScroll.topAnchor.constraint(equalTo: previewHeading.bottomAnchor, constant: 4),
            previewScroll.heightAnchor.constraint(equalToConstant: 132),
            hints.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            hints.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: 8),
            hints.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func filterMetadata() {
        generation += 1
        let version = generation
        searchTask?.cancel()
        searching = false
        filtering = true
        contentQuery = nil
        contentIncomplete = false
        excerpts = [:]
        resetButton.isHidden = true
        let query = field.stringValue
        let corpus = sessions
        // Metadata itself can be large. Debounce and score on a worker too.
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { AgentHistory.filter(corpus, query: query) }
            let matches = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, !self.dismissed, self.generation == version else { return }
            self.filtering = false
            self.apply(matches)
        }
        updateStatus()
    }

    @objc private func searchContent() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        runContentSearch(query)
    }

    private func runContentSearch(_ query: String) {
        generation += 1
        let version = generation
        searchTask?.cancel()
        contentQuery = query
        contentIncomplete = false
        searching = true
        filtering = false
        excerpts = [:]
        resetButton.isHidden = false
        apply([])
        let corpus = sessions
        searchTask = Task { [weak self] in
            let result = await AgentHistory.searchContent(query, sessions: corpus)
            guard !Task.isCancelled, let self, !self.dismissed, self.generation == version else { return }
            self.searching = false
            self.excerpts = result.excerpts
            self.contentIncomplete = result.incomplete
            self.apply(result.sessions)
        }
    }

    @objc private func resetMetadata() { filterMetadata() }

    private func apply(_ matches: [AgentHistory.Session]) {
        let oldID = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].id : nil
        visible = matches
        table.reloadData()
        if !visible.isEmpty {
            let row = visible.firstIndex { $0.id == oldID } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
        updateStatus()
        loadPreview()
    }

    private func updateStatus() {
        if filtering { status.stringValue = "Filtering session metadata..." }
        else if searching { status.stringValue = "Searching conversation text..." }
        else if let contentQuery {
            status.stringValue = "\(visible.count) content matches for \(AgentHistory.display(contentQuery, limit: 60))"
                + (contentIncomplete ? " (partial scan)" : "")
        } else {
            status.stringValue = "\(visible.count) of \(sessions.count) sessions"
                + (discovering ? " - discovering saved history..." : "")
                + (discoveryNotes.isEmpty ? "" : " - some history unavailable")
        }
        status.toolTip = contentIncomplete
            ? "Search reached a time/size limit or encountered unreadable records. Some matches may be missing. " + discoveryNotes
            : discoveryNotes
    }

    private func loadPreview() {
        previewGeneration += 1
        let version = previewGeneration
        previewTask?.cancel()
        guard visible.indices.contains(table.selectedRow) else {
            previewHeading.stringValue = "Transcript Preview"
            previewText.string = searching ? "Searching saved transcripts..." : "No matching sessions."
            return
        }
        let session = visible[table.selectedRow]
        previewHeading.stringValue = session.isLive ? "Live Terminal - Return to Focus" : "Saved Session - Return to Resume"
        previewText.string = "Loading preview..."
        let excerpt = excerpts[session.id]
        previewTask = Task { [weak self] in
            let body = await AgentHistory.preview(session)
            guard !Task.isCancelled, let self, !self.dismissed, self.previewGeneration == version else { return }
            self.previewText.string = (excerpt.map { "CONTENT MATCH\n\($0)\n\n" } ?? "") + body
            self.previewText.scrollToBeginningOfDocument(nil)
        }
    }

    @objc private func commit() {
        guard !dismissed, !searching, !filtering, visible.indices.contains(table.selectedRow) else { return }
        let session = visible[table.selectedRow]
        guard session.isLive || session.resume != nil else { NSSound.beep(); return }
        stop()
        onSelect(session)
    }

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), visible.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 36, 76: commit()
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}

extension SessionPalette: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    func controlTextDidChange(_ obj: Notification) { filterMetadata() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableViewSelectionDidChange(_ notification: Notification) { loadPreview() }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let session = visible[row]
        let name = NSTextField(labelWithString: AgentHistory.display(session.title, limit: 180).replacingOccurrences(of: "\n", with: " "))
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = PaletteStyle.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let directory = AgentHistory.display(session.directory, limit: 300).replacingOccurrences(of: "\n", with: " ")
        let date = session.updatedAt == .distantPast ? "" : session.updatedAt.formatted(date: .abbreviated, time: .omitted)
        let subtitle = NSTextField(labelWithString: "\(session.agent?.name ?? "Terminal")  \(directory)  \(date)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = PaletteStyle.tertiaryText
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let cluster = NSStackView(views: [Chip(text: session.isLive ? "live" : "saved", emphasised: session.isLive)])
        let image: NSImage?
        switch session.agent {
        case .claude: image = AgentIcon.claude.image
        case .codex: image = AgentIcon.codex.image
        case .openCode: image = AgentIcon.openCode.image
        case nil: image = nil
        }
        let view = PaletteRow(icon: IconTile(image: image, symbol: "terminal"), text: text, cluster: cluster)
        view.toolTip = "\(name.stringValue)\n\(directory)\n\(session.resume?.sessionID ?? session.id)"
        return view
    }
}
