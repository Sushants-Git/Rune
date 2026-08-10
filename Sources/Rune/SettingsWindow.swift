import Cocoa

/// The settings window: Rune's colours, Rune's key bindings, and Ghostty's
/// config file.
///
/// Every pane is an `NSGridView`, and that is most of why it reads as a
/// settings window rather than a pile of controls. Built as rows of stack
/// views, each row packs its control immediately after its own label, so the
/// controls land wherever the label happens to end — down the Ghostty pane the
/// revert buttons sat at x = 266, 154, 98, 269. A grid gives every label one
/// right-aligned column and every control the next, and the alignment falls out
/// of the geometry instead of out of guessed constants.
///
/// One window, kept alive for the life of the app, and the controls bind
/// straight to their stores — no apply button and nothing to discard.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private enum Pane: Int, CaseIterable {
        case appearance, shortcuts, ghostty

        var title: String {
            switch self {
            case .appearance: "Appearance"
            case .shortcuts: "Shortcuts"
            case .ghostty: "Ghostty"
            }
        }

        var reset: String {
            switch self {
            case .appearance: "Reset Appearance"
            case .shortcuts: "Reset Shortcuts"
            case .ghostty: "Reset Ghostty Settings"
            }
        }
    }

    private let tabs = NSSegmentedControl(
        labels: Pane.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let panes = NSView()
    private let resetButton = NSButton()
    private var views: [Pane: NSView] = [:]

    /// Metrics shared by all three panes, so nothing drifts.
    private enum Metric {
        static let width: CGFloat = 560
        static let margin: CGFloat = 24
        static let rowSpacing: CGFloat = 10
        static let columnSpacing: CGFloat = 12
        /// Gap above a section heading — enough to group what follows it.
        static let sectionGap: CGFloat = 18
        static let labelColumn: CGFloat = 140
        static let captionWidth: CGFloat = 300
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Rune Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        build()
        select(.appearance)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Chrome

    private func build() {
        guard let content = window?.contentView else { return }

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)

        // Hairlines above and below the content. They do the work a settings
        // window's structure otherwise leaves to guesswork: the tabs belong to
        // the window, the footer belongs to the window, the middle is the pane.
        let topRule = rule()
        let bottomRule = rule()
        content.addSubview(topRule)
        content.addSubview(bottomRule)

        panes.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panes)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetPane)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(resetButton)

        views[.appearance] = makeAppearancePane()
        views[.shortcuts] = makeShortcutsPane()
        views[.ghostty] = makeGhosttyPane()
        for pane in Pane.allCases {
            guard let view = views[pane] else { continue }
            view.translatesAutoresizingMaskIntoConstraints = false
            panes.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: panes.topAnchor),
                view.leadingAnchor.constraint(equalTo: panes.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
                // Appearance is short and stops where it stops; the other two
                // own scroll views and want every pixel.
                pane == .appearance
                    ? view.bottomAnchor.constraint(lessThanOrEqualTo: panes.bottomAnchor)
                    : view.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            topRule.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 18),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            panes.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 20),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -16),

            bottomRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -14),

            resetButton.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Metric.margin),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    private func rule() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    @objc private func tabChanged() {
        guard let pane = Pane(rawValue: tabs.selectedSegment) else { return }
        select(pane)
    }

    private func select(_ pane: Pane) {
        for candidate in Pane.allCases { views[candidate]?.isHidden = candidate != pane }
        tabs.selectedSegment = pane.rawValue
        // Named for what it will do, so it cannot be mistaken for a button that
        // throws away every pane at once.
        resetButton.title = pane.reset
        // The file is a file; someone may have edited it since this was last on
        // screen.
        if pane == .ghostty { reloadGhosttyRows() }
        resize(to: pane)
    }

    /// Appearance is a short pane and the others are long; a window sized for
    /// the longest leaves the shortest in a field of nothing. Settings windows
    /// on macOS resize between tabs, so this one does too.
    private func resize(to pane: Pane) {
        guard let window, let view = views[pane] else { return }
        view.layoutSubtreeIfNeeded()
        let chrome = 18 + tabs.fittingSize.height + 18 + 1 + 20
            + 16 + 1 + 14 + resetButton.fittingSize.height + 18
        let height: CGFloat = pane == .appearance ? chrome + view.fittingSize.height : 640

        var frame = window.frame
        let size = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: Metric.width, height: height)).size
        // Grow downward from the title bar rather than from the bottom edge, so
        // the window does not appear to jump when the pane changes.
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func resetPane() {
        switch Pane(rawValue: tabs.selectedSegment) ?? .appearance {
        case .appearance:
            Settings.shared.resetAppearance()
            syncAppearance()
        case .shortcuts:
            Settings.shared.resetShortcuts()
            recorders.forEach { $0.refresh() }
        case .ghostty:
            resetGhostty()
        }
    }

    // MARK: - Sections

    /// A left-aligned heading over a card of rows.
    ///
    /// Sentence case, not shouted uppercase — a heading is a label for the
    /// group under it, and there are five of them down a pane.
    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, SettingsCard(rows: rows)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews where view is SettingsCard {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The column of sections that makes up a pane.
    private func column(_ sections: [NSView]) -> NSStackView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in sections {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func scrolling(_ content: NSView) -> NSScrollView {
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(
                equalTo: document.leadingAnchor, constant: Metric.margin),
            content.trailingAnchor.constraint(
                equalTo: document.trailingAnchor, constant: -Metric.margin),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // The scroll view is the one thing that should give up height — it has
        // a scroller for exactly that. At default priorities it claims its whole
        // content, runs off the bottom of the window, and draws the tail of the
        // list over whatever is beneath it.
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    /// A scrolling pane, optionally with something fixed above and below it.
    private func pane(
        _ scroll: NSScrollView, footer: NSView? = nil, header: NSView? = nil
    ) -> NSView {
        let stack = NSStackView(views: [scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        for (view, index) in [(header, 0), (footer, stack.arrangedSubviews.count)] {
            guard let view else { continue }
            stack.insertArrangedSubview(view, at: index)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            // Only the scroll view gives up height; the fixed furniture keeps
            // whatever it needs.
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }

    // MARK: - Appearance

    private let accentWell = NSColorWell()
    private let panelWell = NSColorWell()
    private let dimSlider = NSSlider()
    private let dimLabel = NSTextField(labelWithString: "")
    private let systemAccent = NSButton(
        checkboxWithTitle: "Follow the system accent colour", target: nil, action: nil)

    private func makeAppearancePane() -> NSView {
        configure(accentWell, action: #selector(accentChanged))
        systemAccent.target = self
        systemAccent.action = #selector(systemAccentToggled)
        systemAccent.title = ""
        configure(panelWell, action: #selector(panelChanged))

        dimSlider.minValue = 0
        dimSlider.maxValue = 1
        dimSlider.controlSize = .small
        dimSlider.target = self
        dimSlider.action = #selector(dimChanged)
        dimSlider.translatesAutoresizingMaskIntoConstraints = false
        dimSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        dimLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimLabel.textColor = .secondaryLabelColor
        dimLabel.alignment = .right
        dimLabel.translatesAutoresizingMaskIntoConstraints = false
        dimLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let dim = NSStackView(views: [dimSlider, dimLabel])
        dim.spacing = 8

        let openConfig = NSButton(
            title: "Open Config File", target: self, action: #selector(openGhosttyConfig))
        openConfig.bezelStyle = .rounded
        openConfig.controlSize = .small

        let content = column([
            section("Rune", [
                SettingsRow(
                    title: "Accent",
                    caption: "Marks the active tab, the update pill and the switcher's "
                        + "focus ring.",
                    control: accentWell),
                SettingsRow(
                    title: "Follow the system accent",
                    caption: nil, control: systemAccent),
                SettingsRow(
                    title: "Switcher panel",
                    caption: "The ⌘K panel's background. It stays dark on purpose — the "
                        + "window's appearance follows your terminal theme, and a light one "
                        + "would take the panel's text with it.",
                    control: panelWell),
                SettingsRow(
                    title: "Backdrop dim",
                    caption: "How much of the terminal the switcher's backdrop carries away.",
                    control: dim),
            ]),
            section("Terminal", [
                SettingsRow(
                    title: "Ghostty config",
                    caption: "Colours, font and everything else about the terminal itself "
                        + "come from your Ghostty config. Rune keeps no second copy, so "
                        + "there is only ever one file to edit — and the Ghostty tab edits "
                        + "it for you.",
                    control: openConfig),
            ]),
        ])

        syncAppearance()

        let holder = NSView()
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.leadingAnchor.constraint(
                equalTo: holder.leadingAnchor, constant: Metric.margin),
            content.trailingAnchor.constraint(
                equalTo: holder.trailingAnchor, constant: -Metric.margin),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    private func configure(_ well: NSColorWell, action: Selector) {
        well.target = self
        well.action = action
        Self.style(well)
    }

    /// A bordered swatch rather than the default well. Half these colours are
    /// near-black sitting on a near-black pane, and without an edge an unset
    /// background swatch is indistinguishable from a hole in the window.
    static func style(_ well: NSColorWell) {
        well.colorWellStyle = .minimal
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        well.wantsLayer = true
        well.layer?.cornerRadius = 5
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1
        well.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func syncAppearance() {
        let settings = Settings.shared
        accentWell.color = settings.effectiveAccent
        accentWell.isEnabled = settings.accent != nil
        accentWell.alphaValue = settings.accent != nil ? 1 : 0.4
        systemAccent.state = settings.accent == nil ? .on : .off
        panelWell.color = settings.panelBackground
        dimSlider.doubleValue = Double(settings.backdropDim)
        dimLabel.stringValue = "\(Int(settings.backdropDim * 100))%"
    }

    @objc private func accentChanged() {
        Settings.shared.accent = accentWell.color
        syncAppearance()
    }

    @objc private func systemAccentToggled() {
        // Unticking has to leave a colour behind, or the well would go on
        // showing the system accent while claiming to be an override.
        Settings.shared.accent = systemAccent.state == .on ? nil : accentWell.color
        syncAppearance()
    }

    @objc private func panelChanged() {
        Settings.shared.panelBackground = panelWell.color
    }

    @objc private func dimChanged() {
        Settings.shared.backdropDim = CGFloat(dimSlider.doubleValue)
        dimLabel.stringValue = "\(Int(Settings.shared.backdropDim * 100))%"
    }

    /// Ghostty reads several paths; this opens the one it actually uses,
    /// creating it if it isn't there — `open` on a missing file does nothing at
    /// all, which reads as a broken button.
    @objc private func openGhosttyConfig() {
        let url = GhosttyConfigFile.location
        ensureExists(url)
        NSWorkspace.shared.open(url)
    }

    @objc private func revealGhosttyConfig() {
        let url = GhosttyConfigFile.location
        ensureExists(url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func ensureExists(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // MARK: - Shortcuts

    private var recorders: [ShortcutRecorder] = []
    private let conflictLabel = NSTextField(labelWithString: "")

    private func makeShortcutsPane() -> NSView {
        let sections = ShortcutAction.grouped.map { group in
            section(group.name, group.actions.map { action in
                let recorder = ShortcutRecorder(action: action)
                recorder.onRecorded = { [weak self] chord in self?.bind(chord, to: action) }
                recorders.append(recorder)
                return SettingsRow(title: action.title, caption: nil, control: recorder)
            })
        }

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed

        let hint = NSTextField(labelWithString:
            "Click a shortcut and press the new keys. Escape cancels, Delete restores the default.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [hint, conflictLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 4
        footer.edgeInsets = NSEdgeInsets(
            top: 0, left: Metric.margin, bottom: 0, right: Metric.margin)
        return pane(scrolling(column(sections)), footer: footer)
    }

    /// Refuse rather than steal. Two items sharing a key equivalent is not an
    /// error AppKit reports — it picks one and the other quietly stops working,
    /// which is a far worse thing to discover later.
    private func bind(_ chord: KeyChord?, to action: ShortcutAction) {
        defer { recorders.forEach { $0.refresh() } }

        guard let chord else {
            Settings.shared.setChord(nil, for: action)
            conflictLabel.stringValue = ""
            return
        }
        if let other = Settings.shared.conflict(with: chord, ignoring: action) {
            conflictLabel.stringValue = "\(chord.display) is already \(other.title)."
            NSSound.beep()
            return
        }
        conflictLabel.stringValue = ""
        Settings.shared.setChord(chord, for: action)
    }

    // MARK: - Ghostty

    private var ghosttyControls: [GhosttyOptionControl] = []
    private let configPathLabel = NSTextField(labelWithString: "")
    private let configWarning = NSTextField(wrappingLabelWithString: "")
    private let configSummary = NSTextField(labelWithString: "")

    /// Edits waiting to be written, keyed by config key. A `nil` value means
    /// "take the key out".
    ///
    /// Coalesced rather than written per keystroke: dragging an opacity slider
    /// fires continuously, and each write is a file replace plus a full
    /// libghostty config rebuild pushed to every surface.
    private var pendingEdits: [String: String?] = [:]
    private var flushWork: DispatchWorkItem?

    private func makeGhosttyPane() -> NSView {
        let sections = GhosttyOptions.groups.map { group in
            section(group.name, group.options.map { option in
                let row = GhosttyOptionControl(option: option)
                row.onChange = { [weak self] value in self?.edit(option.key, to: value) }
                ghosttyControls.append(row)
                return row.row
            })
        }

        // The file goes at the top, not in a footer. This pane is a view onto
        // one file and nothing else, and the first question anyone asks of it
        // is "which file, and is it mine?" — burying the answer under a
        // scrolling list is how a pane full of correct values still reads as
        // though it has not loaded anything.
        configPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle

        configSummary.font = .systemFont(ofSize: 11)
        configSummary.textColor = .tertiaryLabelColor

        configWarning.font = .systemFont(ofSize: 11)
        configWarning.textColor = .systemOrange
        configWarning.preferredMaxLayoutWidth = Metric.width - Metric.margin * 2

        let open = NSButton(
            title: "Open in Editor", target: self, action: #selector(openGhosttyConfig))
        let reveal = NSButton(
            title: "Reveal in Finder", target: self, action: #selector(revealGhosttyConfig))
        for button in [open, reveal] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }

        let pathRow = NSStackView(views: [configPathLabel, NSView(), open, reveal])
        pathRow.spacing = 8
        pathRow.alignment = .centerY
        configPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [pathRow, configSummary, configWarning])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(
            top: 0, left: Metric.margin, bottom: 0, right: Metric.margin)
        header.translatesAutoresizingMaskIntoConstraints = false
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        pathRow.widthAnchor.constraint(
            equalTo: header.widthAnchor, constant: -Metric.margin * 2).isActive = true

        reloadGhosttyRows()
        return pane(scrolling(column(sections)), header: header)
    }

    /// Read the file and put every row back in step with it.
    private func reloadGhosttyRows() {
        let file = GhosttyConfigFile()
        for row in ghosttyControls { row.show(file.value(for: row.option.key)) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        configPathLabel.stringValue = file.url.path.replacingOccurrences(of: home, with: "~")

        // Say how many of these settings the file actually sets. Most of a
        // fresh config is Ghostty's defaults, and a page of greyed-out rows is
        // indistinguishable from a page that failed to load one.
        let set = GhosttyOptions.all.filter { file.value(for: $0.key) != nil }.count
        let exists = FileManager.default.fileExists(atPath: file.url.path)
        configSummary.stringValue = !exists
            ? "This file does not exist yet — changing anything here will create it."
            : "\(set) of \(GhosttyOptions.all.count) shown below are set in this file; "
                + "the rest are Ghostty's defaults."

        var warnings: [String] = []
        let competing = GhosttyConfigFile.competingFiles
        if !competing.isEmpty {
            let names = competing
                .map { $0.path.replacingOccurrences(of: home, with: "~") }
                .joined(separator: ", ")
            warnings.append(
                "Ghostty also loads \(names), which sets values of its own. Where the two "
                + "disagree, the later file wins.")
        }
        warnings.append(contentsOf: NSApp.ghosttyApp?.configDiagnostics() ?? [])
        configWarning.stringValue = warnings.joined(separator: "\n")
        configWarning.isHidden = warnings.isEmpty
    }

    /// Queue a change, unless it is not one.
    ///
    /// A control that lands on the value the file already holds must write
    /// nothing. Without this, brushing a slider rewrote `background-opacity = 1`
    /// as `1.00`, and any control that fires on its own — focus moving, a pane
    /// being shown — would leave a diff in a file the user never meant to
    /// touch. The safest write is the one that does not happen.
    private func edit(_ key: String, to value: String?) {
        let current = GhosttyConfigFile().value(for: key)
        if Self.same(current, value) {
            pendingEdits.removeValue(forKey: key)
            return
        }
        // Writing a key that is absent, at the value Ghostty already uses, adds
        // a line that changes nothing. `font-thicken = false` is how a config
        // acquires clutter it did not ask for — and it is exactly the line that
        // turned up in a real file here.
        if current == nil,
           let option = GhosttyOptions.all.first(where: { $0.key == key }),
           Self.same(option.default.isEmpty ? nil : option.default, value) {
            pendingEdits.removeValue(forKey: key)
            return
        }
        pendingEdits[key] = value
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushEdits() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Equal as Ghostty would read them. `1` and `1.00` are the same opacity,
    /// and rewriting one as the other is churn in someone's file.
    private static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            if x == y { return true }
            if let left = Double(x), let right = Double(y) { return left == right }
            return x.caseInsensitiveCompare(y) == .orderedSame
        default: return false
        }
    }

    private func flushEdits() {
        guard !pendingEdits.isEmpty else { return }
        var file = GhosttyConfigFile()
        for (key, value) in pendingEdits { file.set(key, to: value) }
        pendingEdits = [:]

        do {
            try file.save()
        } catch {
            configWarning.isHidden = false
            configWarning.stringValue =
                "Could not write \(file.url.path): \(error.localizedDescription)"
            return
        }
        NSApp.ghosttyApp?.reloadConfig()
        reloadGhosttyRows()
    }

    /// Remove every key this pane manages, and nothing else.
    ///
    /// Behind a confirmation because it is the one reset in this window that
    /// edits a file the user wrote by hand — and it cannot know which of those
    /// lines they typed themselves.
    private func resetGhostty() {
        let file = GhosttyConfigFile()
        let present = GhosttyOptions.all.map(\.key).filter { file.value(for: $0) != nil }
        guard !present.isEmpty else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText =
            "Remove \(present.count) setting\(present.count == 1 ? "" : "s") from your Ghostty config?"
        alert.informativeText =
            "This deletes these lines from \(configPathLabel.stringValue):\n\n"
            + present.joined(separator: ", ")
            + "\n\nEverything else in the file — comments, keys Rune does not show — is left "
            + "alone, and the original was copied to a .rune-backup file the first time Rune "
            + "wrote to it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for key in present { pendingEdits[key] = String?.none }
        flushEdits()
    }
}

/// The click-then-type control for one binding.
///
/// While recording it takes key events from a local monitor rather than from
/// `keyDown`. Menu key equivalents are matched before the responder chain runs,
/// so pressing ⌘T to bind it would open a tab and the recorder would never hear
/// the key at all.
@MainActor
final class ShortcutRecorder: NSButton {
    /// Not `action` — `NSButton` already has one, and shadowing it puts the
    /// selector this button fires out of reach.
    private let binding: ShortcutAction
    var onRecorded: ((KeyChord?) -> Void)?

    private var monitor: Any?
    private var recording = false { didSet { refresh() } }

    init(action: ShortcutAction) {
        self.binding = action
        super.init(frame: .zero)

        bezelStyle = .rounded
        controlSize = .small
        target = self
        self.action = #selector(beginRecording)
        font = .systemFont(ofSize: 12)
        alignment = .center
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 132).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        title = recording ? "Type a shortcut…" : Settings.shared.chord(for: binding).display
        contentTintColor = recording ? Settings.shared.effectiveAccent : nil
    }

    @objc private func beginRecording() {
        guard !recording else { return stopRecording() }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
        // A monitor left installed would swallow every key in the app. Clicking
        // away is the one way out of recording that does not go through a key
        // press, so it has to end it too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stopRecording),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func stopRecording() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: window)
        recording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape leaves it as it was; Delete puts back whatever Rune ships.
        switch event.keyCode {
        case 53: stopRecording(); return
        case 51, 117:
            stopRecording()
            onRecorded?(nil)
            return
        default: break
        }
        guard let chord = KeyChord.from(event) else {
            // A bare letter is typing, not a shortcut. Say so by beeping rather
            // than by silently sitting in recording mode.
            NSSound.beep()
            return
        }
        stopRecording()
        onRecorded?(chord)
    }
}
