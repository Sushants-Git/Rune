import Cocoa

/// Cmd-L's native palette. The controller supplies live rows (Session.live),
/// presents this in SwitcherOverlay, and handles the selected row:
/// - liveTarget != nil: focus that exact surface, without launching anything.
/// - otherwise: launch resume.shellCommand in a new terminal.
/// Discovery, search and preview never read terminal surfaces or run commands.
///
/// Laid out as a picker rather than as a form. What was here before was a
/// search box, two bordered AppKit push buttons, a status line, a short list, a
/// heading, and a grey wall of monospace — six stacked strips, none of which
/// looked like the ⌘K panel it opens next to. It is now the same panel: one
/// bare field at the top, rows on the left, what the row *is* on the right, and
/// the keys along the bottom.
@MainActor
final class SessionPalette: NSView, OverlayPanel {
    private let supplied: [AgentHistory.Session]
    private let onSelect: (AgentHistory.Session) -> Void
    private let onCancel: () -> Void
    private var sessions: [AgentHistory.Session]
    private var visible: [AgentHistory.Session] = []
    /// What the search matched, before the agent tab narrows it — kept so
    /// switching tabs doesn't have to search again, and so each tab can say
    /// how many of the matches are its own.
    private var matched: [AgentHistory.Session] = []
    private var agentTab: AgentHistory.Agent?
    private let tabs = AgentTabs()
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

    private let field = NSTextField()
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let listEmpty = NSTextField(labelWithString: "")
    private let previewScroll = NSScrollView()
    private let previewText = NSTextView()
    private let status = NSTextField(labelWithString: "Discovering saved sessions…")
    private let previewHeading = NSTextField(labelWithString: "")
    private let previewIcon = NSImageView()
    private var commitHint: HintPair!

    private static let width: CGFloat = 760
    private static let listWidth: CGFloat = 330
    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 7
    /// Whole rows, plus the scroll view's own padding. An arbitrary height
    /// leaves a row sliced through the middle at the bottom of the list, which
    /// reads as a rendering fault rather than as "there is more below".
    private static let bodyHeight: CGFloat = CGFloat(visibleRows) * rowHeight + 12
    private static let cornerRadius: CGFloat = 8

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
        FFF.warm(AgentHistory.transcriptFolders(AgentHistory.Roots()))
        discoveryTask = Task { [weak self] in
            let result = await AgentHistory.discover()
            guard !Task.isCancelled, let self, !self.dismissed else { return }
            self.discovering = false
            self.discoveryNotes = result.notes.joined(separator: " ")
            self.sessions = AgentHistory.merge(self.supplied, with: result.sessions)
            // Anything already found was found in a smaller corpus.
            self.search()
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

        // The same field ⌘K has: big, bare, and the only thing in the header.
        field.font = PaletteStyle.font(ofSize: 15, weight: .regular)
        field.textColor = PaletteStyle.primaryText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderAttributedString = NSAttributedString(
            string: "Search sessions and what was said in them…",
            attributes: [
                .foregroundColor: PaletteStyle.tertiaryText,
                .font: PaletteStyle.font(ofSize: 15),
            ])
        field.setAccessibilityLabel("Search agent sessions")


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
        table.doubleAction = #selector(commit)
        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.setAccessibilityLabel("Live and saved sessions")

        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false
        listScroll.autohidesScrollers = true
        listScroll.automaticallyAdjustsContentInsets = false
        listScroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        listEmpty.font = PaletteStyle.font(ofSize: 12)
        listEmpty.textColor = PaletteStyle.tertiaryText
        listEmpty.alignment = .center
        listEmpty.isHidden = true

        // What Return will do to the highlighted row, stated as a heading over
        // the thing it will do it to.
        previewHeading.font = PaletteStyle.font(ofSize: 11, weight: .semibold)
        previewHeading.textColor = PaletteStyle.secondaryText
        previewHeading.lineBreakMode = .byTruncatingTail
        previewIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        previewIcon.contentTintColor = PaletteStyle.tertiaryText
        previewIcon.setContentHuggingPriority(.required, for: .horizontal)

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.isRichText = false
        previewText.isAutomaticLinkDetectionEnabled = false
        previewText.isAutomaticDataDetectionEnabled = false
        previewText.drawsBackground = false
        previewText.font = PaletteStyle.font(ofSize: 12)
        previewText.textColor = PaletteStyle.secondaryText
        previewText.textContainerInset = NSSize(width: 2, height: 4)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewText.textContainer?.containerSize = NSSize(
            width: Self.width - Self.listWidth, height: .greatestFiniteMagnitude)
        previewText.setAccessibilityLabel("Plain text transcript preview")
        previewScroll.documentView = previewText
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.scrollerStyle = .overlay
        previewScroll.autohidesScrollers = true

        status.font = PaletteStyle.font(ofSize: 10.5)
        status.textColor = PaletteStyle.tertiaryText
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commitHint = HintPair(keys: ["⏎"], label: "Resume")
        let hints = NSStackView(views: [
            commitHint, HintPair(keys: ["⇥"], label: "Agent"),
            HintPair(keys: ["esc"], label: "Dismiss"),
        ])
        hints.orientation = .horizontal
        hints.spacing = 14
        hints.setContentHuggingPriority(.required, for: .horizontal)

        let headerDivider = Divider()
        let tabsDivider = Divider()
        let bodyDivider = Divider(vertical: true)
        tabs.onSelect = { [weak self] agent in self?.selectTab(agent) }
        let footerDivider = Divider()

        let prompt = PalettePrompt.make()
        addSubview(prompt)
        for view in [field, headerDivider, tabs, tabsDivider, listScroll, listEmpty, bodyDivider,
                     previewIcon, previewHeading, previewScroll, footerDivider, status, hints] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let inset = SwitcherPalette.contentInset
        let previewLeading = bodyDivider.trailingAnchor
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

            listScroll.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: SwitcherPalette.rowInset),
            listScroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            tabs.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset - 8),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            tabsDivider.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            tabsDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabsDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            listScroll.topAnchor.constraint(equalTo: tabsDivider.bottomAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: Self.bodyHeight),
            listEmpty.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            listEmpty.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),

            bodyDivider.leadingAnchor.constraint(
                equalTo: listScroll.trailingAnchor, constant: SwitcherPalette.rowInset),
            bodyDivider.topAnchor.constraint(equalTo: listScroll.topAnchor),
            bodyDivider.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),

            previewIcon.leadingAnchor.constraint(equalTo: previewLeading, constant: inset),
            previewIcon.centerYAnchor.constraint(equalTo: previewHeading.centerYAnchor),
            previewHeading.leadingAnchor.constraint(
                equalTo: previewIcon.trailingAnchor, constant: 6),
            previewHeading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            previewHeading.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 14),

            previewScroll.leadingAnchor.constraint(equalTo: previewLeading, constant: inset - 2),
            previewScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            previewScroll.topAnchor.constraint(
                equalTo: previewHeading.bottomAnchor, constant: 8),
            previewScroll.bottomAnchor.constraint(
                equalTo: listScroll.bottomAnchor, constant: -8),

            footerDivider.topAnchor.constraint(equalTo: listScroll.bottomAnchor),
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

    // MARK: - Filtering

    /// Every keystroke: the titles, folders and accounts straight away, then
    /// — once typing pauses — the transcripts themselves, through fff.
    ///
    /// Sessions matched only by what was said in them are added below the
    /// ones matched by name, so what you'd have found before stays on top, and
    /// the preview opens on the matching lines. This replaced a ⌃F mode that
    /// searched transcripts *instead* of titles: two searches you had to pick
    /// between, when with fff the second costs well under a second.
    private func search() {
        generation += 1
        let version = generation
        searchTask?.cancel()
        filtering = true
        searching = false
        contentIncomplete = false
        let query = field.stringValue
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // One character matches nearly every transcript on the machine.
        let content = needle.count >= 2 ? needle : nil
        let corpus = sessions
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { AgentHistory.filter(corpus, query: query) }
            let titles = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, !self.dismissed, self.generation == version else { return }
            self.filtering = false
            self.excerpts = [:]
            self.contentQuery = content
            self.searching = content != nil
            self.apply(titles)
            guard let content else { return }

            // A little longer, so a word still being typed isn't searched for
            // a letter at a time.
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            let result = await AgentHistory.searchContent(content, sessions: corpus, grep: FFF.historyGrep)
            guard !Task.isCancelled, !self.dismissed, self.generation == version else { return }
            self.searching = false
            self.contentIncomplete = result.incomplete
            self.excerpts = result.excerpts
            let named = Set(titles.map(\.id))
            self.apply(titles + result.sessions.filter { !named.contains($0.id) })
        }
        updateStatus()
    }

    /// Show one agent's sessions, or everyone's.
    private func selectTab(_ agent: AgentHistory.Agent?) {
        guard agent != agentTab else { return }
        agentTab = agent
        apply(matched)
    }

    /// ⇥ and ⇧⇥ walk the tabs, wrapping. ← and → did too for a while, and
    /// were taken out: in a field you are typing a query into, the arrows are
    /// how you get back through what you typed.
    private func cycleTab(by step: Int) {
        let order: [AgentHistory.Agent?] = [nil] + AgentHistory.Agent.allCases
        let index = order.firstIndex { $0 == agentTab } ?? 0
        selectTab(order[(index + step + order.count) % order.count])
    }

    private func apply(_ matches: [AgentHistory.Session]) {
        let oldID = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].id : nil
        matched = matches
        var counts: [AgentHistory.Agent?: Int] = [nil: matches.count]
        for session in matches { if let agent = session.agent { counts[agent, default: 0] += 1 } }
        tabs.update(selected: agentTab, counts: counts)
        visible = agentTab.map { agent in matches.filter { $0.agent == agent } } ?? matches
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
        if filtering { status.stringValue = "Filtering…" }
        else if contentQuery != nil {
            status.stringValue = "\(visible.count) "
                + (visible.count == 1 ? "session" : "sessions")
                + (searching ? " · searching transcripts…" : "")
                + (contentIncomplete ? " · partial scan" : "")
        } else {
            let total = agentTab.map { agent in sessions.filter { $0.agent == agent }.count } ?? sessions.count
            status.stringValue = "\(visible.count) of \(total) sessions"
                + (discovering ? " · reading saved history…" : "")
                + (discoveryNotes.isEmpty ? "" : " · some history unavailable")
        }
        status.toolTip = contentIncomplete
            ? "Search reached a time/size limit or encountered unreadable records. Some matches may be missing. " + discoveryNotes
            : discoveryNotes

        // The empty list has to say *why* it is empty: still looking, nothing
        // matched, or nothing found at all.
        listEmpty.isHidden = !visible.isEmpty
        if visible.isEmpty {
            listEmpty.stringValue = searching || filtering || discovering
                ? "Looking…"
                : (field.stringValue.isEmpty ? "No sessions found" : "No sessions match")
        }
    }

    private func loadPreview() {
        previewGeneration += 1
        let version = previewGeneration
        previewTask?.cancel()
        guard visible.indices.contains(table.selectedRow) else {
            previewIcon.image = nil
            previewHeading.stringValue = ""
            previewText.string = ""
            commitHint.setLabel("Resume")
            return
        }
        let session = visible[table.selectedRow]
        let live = session.isLive
        previewIcon.image = NSImage(
            systemSymbolName: live ? "bolt.horizontal.circle" : "clock.arrow.circlepath",
            accessibilityDescription: nil)
        previewHeading.stringValue = live
            ? "Live terminal — Return jumps to it"
            : (session.resume == nil
                ? "Saved session — no transcript to resume from"
                : "Saved session — Return resumes it in a new workspace")
        commitHint.setLabel(live ? "Focus" : "Resume")
        previewText.string = "Loading preview…"
        let excerpt = excerpts[session.id]
        previewTask = Task { [weak self] in
            let body = await AgentHistory.preview(session)
            guard !Task.isCancelled, let self, !self.dismissed, self.previewGeneration == version else { return }
            let text = (excerpt.map { "\($0)\n\n────────\n\n" } ?? "") + body
            self.previewText.textStorage?.setAttributedString(
                Self.highlighted(text, query: self.contentQuery))
            self.previewText.scrollToBeginningOfDocument(nil)
        }
    }

    /// Return.
    ///
    /// `filtering` is deliberately not a blocker. It is set for the 90ms the
    /// metadata debounce is in flight, and a Return that lands inside that
    /// window used to be swallowed — you typed a query, saw the row you wanted
    /// already highlighted, pressed Return and nothing at all happened. The
    /// highlighted row is a real row either way; only a content search, which
    /// empties the list while it runs, has nothing to commit.
    @objc private func commit() {
        guard !dismissed, visible.indices.contains(table.selectedRow) else { return }
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

extension SessionPalette: NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    func controlTextDidChange(_ obj: Notification) { search() }

    /// The panel is dark whatever the terminal's theme is, and the shared field
    /// editor inherits the *window's* appearance — so on a light colourscheme
    /// both the caret and the selection have to be stated or they come out
    /// black on black. Same reasoning as ⌘K.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = PaletteStyle.primaryText
        editor.selectedTextAttributes = [
            .backgroundColor: Settings.shared.effectiveAccent.withAlphaComponent(0.5),
            .foregroundColor: PaletteStyle.primaryText,
        ]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        // ⌃F. The field editor turns it into forward-one-character, which is
        // the one emacs binding worth spending here: this field is a query, not
        // a document, and transcript search needs a key that isn't already ⌘F
        // in the terminal underneath.
        case #selector(NSResponder.insertTab(_:)): cycleTab(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): cycleTab(by: -1)
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

        let name = NSTextField(labelWithString: AgentHistory
            .display(session.title, limit: 180)
            .replacingOccurrences(of: "\n", with: " "))
        name.font = PaletteStyle.font(ofSize: 13, weight: .medium)
        name.textColor = PaletteStyle.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Agent, directory and date on one line, in that order — what it was,
        // where it was, when it was. The path is abbreviated at the front
        // because the tail is the part that identifies the project.
        let directory = AgentHistory
            .display(session.directory, limit: 300)
            .replacingOccurrences(of: "\n", with: " ")
        // Where it was, and on which account when it isn't the default one —
        // that decides which login a resume lands in. The agent is already
        // the row's icon (and the tab), and the time sits on the right.
        let detail = [session.account.map { AgentHistory.display($0, limit: 24) } ?? "",
                      Self.abbreviate(directory)]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = PaletteStyle.font(ofSize: 11)
        subtitle.textColor = PaletteStyle.tertiaryText
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        // Only live rows are chipped. "saved" on every other row was a label
        // saying what the list is, repeated once per line; live is the one that
        // changes what Return does.
        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 6
        if session.isLive {
            cluster.addArrangedSubview(Chip(text: "live", emphasised: true))
        } else {
            if session.resume == nil {
                cluster.addArrangedSubview(
                    Chip(symbol: "slash.circle", hint: "No transcript to resume from"))
            }
            let time = NSTextField(labelWithString: Self.when(session.updatedAt))
            time.font = PaletteStyle.font(ofSize: 12)
            time.textColor = PaletteStyle.tertiaryText
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            cluster.addArrangedSubview(time)
        }

        let dark = !PaletteStyle.isLight
        let image: NSImage?
        switch session.agent {
        case .claude: image = AgentIcon.claude.image(onDark: dark)
        case .codex: image = AgentIcon.codex.image(onDark: dark)
        case .openCode: image = AgentIcon.openCode.image(onDark: dark)
        case .pi: image = AgentIcon.pi.image(onDark: dark)
        case nil: image = nil
        }
        let view = PaletteRow(icon: IconTile(image: image, symbol: "terminal"), text: text, cluster: cluster)
        view.toolTip = "\(name.stringValue)\n"
            + [session.agent?.name ?? "Terminal", session.account.map { "account \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            + "\n\(directory)\n\(session.resume?.sessionID ?? session.id)"
        return view
    }

    /// Just the folder's own name — `site`, not `~/Workspace/@devfolio/site`.
    /// The rest of the path is in the tooltip; the name is what you'd look
    /// for in a list.
    private static func abbreviate(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The preview with what the query matched picked out — every place it
    /// matches, by the same rule the list was searched with.
    private static func highlighted(_ text: String, query: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: PaletteStyle.font(ofSize: 12),
            .foregroundColor: PaletteStyle.secondaryText,
        ])
        guard let query, !query.isEmpty else { return result }
        let mark: [NSAttributedString.Key: Any] = [
            .backgroundColor: PaletteStyle.accent.withAlphaComponent(
                Settings.shared.highlight == .grey ? 0.45 : 0.32),
            .foregroundColor: PaletteStyle.primaryText,
            .font: PaletteStyle.font(ofSize: 12, weight: .bold),
        ]
        // Match after match, a line at a time, so a long preview isn't one
        // search over the whole of it that stops at the first hit.
        var lineStart = text.startIndex
        var marked = 0
        while lineStart < text.endIndex, marked < 200 {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            var cursor = line.startIndex
            while cursor < line.endIndex,
                  let ranges = AgentHistory.matchRanges(query, in: String(line[cursor...])) {
                let piece = String(line[cursor...])
                for range in ranges {
                    let lower = text.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: cursor)
                        + piece.distance(from: piece.startIndex, to: range.lowerBound))
                    let upper = text.index(lower, offsetBy: piece.distance(from: range.lowerBound, to: range.upperBound))
                    result.addAttributes(mark, range: NSRange(lower..<upper, in: text))
                    marked += 1
                }
                guard let last = ranges.map(\.upperBound).max() else { break }
                cursor = line.index(cursor, offsetBy: piece.distance(from: piece.startIndex, to: last))
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return result
    }

    /// Today and yesterday by name, this week by weekday, older by date. A
    /// column of identical "11 Sep 2026"s tells you nothing about which session
    /// is the one you were just in.
    private static func when(_ date: Date) -> String {
        guard date != .distantPast else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The row of agent tabs across ⌘L: all, then one per agent, each with how
/// many of the current matches it holds. A second account's sessions live
/// under their agent's tab, marked on the row, rather than getting a tab of
/// their own — which agent it is decides how it resumes; the account is a
/// detail of that.
@MainActor
final class AgentTabs: NSView {
    var onSelect: ((AgentHistory.Agent?) -> Void)?

    private let stack = NSStackView()
    private var buttons: [(agent: AgentHistory.Agent?, view: AgentTab)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for agent in [nil] + AgentHistory.Agent.allCases {
            let tab = AgentTab(title: agent?.name.lowercased() ?? "all")
            tab.onClick = { [weak self] in self?.onSelect?(agent) }
            buttons.append((agent, tab))
            stack.addArrangedSubview(tab)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Agents")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(selected: AgentHistory.Agent?, counts: [AgentHistory.Agent?: Int]) {
        for (agent, view) in buttons {
            view.set(selected: agent == selected, count: counts[agent] ?? 0)
        }
    }
}

/// One of those tabs: its name, a count, and an accent underline when it is
/// the one showing.
@MainActor
final class AgentTab: NSView {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let underline = NSView()
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        label.stringValue = title
        for field in [label, count] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        underline.wantsLayer = true
        underline.layer?.backgroundColor = PaletteStyle.accent.cgColor
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            count.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        set(selected: false, count: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(selected: Bool, count value: Int) {
        label.font = PaletteStyle.font(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = selected ? PaletteStyle.primaryText : PaletteStyle.secondaryText
        count.font = PaletteStyle.font(ofSize: 12)
        count.textColor = PaletteStyle.tertiaryText
        count.stringValue = "\(value)"
        underline.isHidden = !selected
        setAccessibilityLabel("\(title), \(value) sessions")
        setAccessibilityValue(selected)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
