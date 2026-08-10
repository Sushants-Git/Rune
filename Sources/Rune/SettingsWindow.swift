import Cocoa

/// The settings window: Rune's colours, Rune's key bindings, and Ghostty's
/// config file.
///
/// One window, kept alive for the life of the app. Reopening it should land you
/// where you left off rather than resetting to the first pane, and the controls
/// bind straight to `Settings` — there is no apply button and nothing to
/// discard, so every change is visible in the terminal behind it immediately.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabs = NSSegmentedControl(
        labels: ["Appearance", "Shortcuts", "Ghostty"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let panes = NSView()
    private let resetButton = NSButton()

    private var appearance: NSView!
    private var shortcuts: NSView!
    private var ghostty: NSView!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Rune Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        build()
        select(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
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

        panes.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panes)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetPane)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(resetButton)

        appearance = makeAppearancePane()
        shortcuts = makeShortcutsPane()
        ghostty = makeGhosttyPane()
        for pane in [appearance!, shortcuts!, ghostty!] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            panes.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: panes.topAnchor),
                pane.leadingAnchor.constraint(equalTo: panes.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            ])
        }
        // Appearance is a short list and stops where it stops; pinning its
        // bottom too made the stack fill the window and space its rows out
        // across half a screen of nothing. Shortcuts owns a scroll view, which
        // does want every pixel it can get.
        appearance.bottomAnchor.constraint(lessThanOrEqualTo: panes.bottomAnchor).isActive = true
        shortcuts.bottomAnchor.constraint(equalTo: panes.bottomAnchor).isActive = true
        ghostty.bottomAnchor.constraint(equalTo: panes.bottomAnchor).isActive = true

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            panes.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 16),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -12),

            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func tabChanged() {
        select(tabs.selectedSegment)
    }

    private func select(_ index: Int) {
        appearance.isHidden = index != 0
        shortcuts.isHidden = index != 1
        ghostty.isHidden = index != 2
        // Named for what it will do, so it cannot be mistaken for a button that
        // throws away every pane at once.
        resetButton.title = ["Reset Appearance", "Reset Shortcuts", "Reset Ghostty Settings"][index]
        if index == 2 { reloadGhosttyRows() }
        resize(to: index)
    }

    /// Appearance is a short pane and shortcuts is a long one; a window sized
    /// for the longer leaves the shorter sitting in a field of nothing. Settings
    /// windows on macOS resize between tabs, so this one does too.
    private func resize(to index: Int) {
        guard let window else { return }
        let pane = [appearance!, shortcuts!, ghostty!][index]
        pane.layoutSubtreeIfNeeded()
        // 16 above the tabs, the tabs, 16 below, the pane, 12, the button, 16.
        let height = index == 0
            ? 16 + tabs.fittingSize.height + 16 + pane.fittingSize.height
                + 12 + resetButton.fittingSize.height + 16
            : 640
        var frame = window.frame
        let size = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: 520, height: height)).size
        // Grow downward from the title bar rather than from the bottom edge, so
        // the window does not appear to jump when the pane changes.
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func resetPane() {
        switch tabs.selectedSegment {
        case 0:
            Settings.shared.resetAppearance()
            syncAppearance()
        case 1:
            Settings.shared.resetShortcuts()
            recorders.forEach { $0.refresh() }
        default:
            resetGhostty()
        }
    }

    // MARK: - Appearance

    private let accentWell = NSColorWell()
    private let panelWell = NSColorWell()
    private let dimSlider = NSSlider()
    private let dimLabel = NSTextField(labelWithString: "")
    private let systemAccent = NSButton(checkboxWithTitle: "Use the system accent colour", target: nil, action: nil)

    private func makeAppearancePane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 4, right: 20)

        accentWell.target = self
        accentWell.action = #selector(accentChanged)
        systemAccent.target = self
        systemAccent.action = #selector(systemAccentToggled)
        stack.addArrangedSubview(
            row("Accent", accentWell,
                note: "Marks the active tab, the update pill and the switcher's focus ring."))
        stack.addArrangedSubview(indented(systemAccent))

        panelWell.target = self
        panelWell.action = #selector(panelChanged)
        stack.addArrangedSubview(
            row("Switcher panel", panelWell,
                note: "The ⌘K panel's background. It stays dark on purpose — the window's "
                    + "appearance follows your terminal theme, and a light one would take "
                    + "the panel's text with it."))

        dimSlider.minValue = 0
        dimSlider.maxValue = 1
        dimSlider.target = self
        dimSlider.action = #selector(dimChanged)
        dimSlider.translatesAutoresizingMaskIntoConstraints = false
        dimSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        dimLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimLabel.textColor = .secondaryLabelColor
        let dim = NSStackView(views: [dimSlider, dimLabel])
        dim.spacing = 8
        stack.addArrangedSubview(
            row("Backdrop dim", dim,
                note: "How much of the terminal the switcher's backdrop carries away."))

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let terminalNote = NSTextField(wrappingLabelWithString:
            "Terminal colours — the palette, the background, the font — come from your "
            + "Ghostty config, which Rune reads on launch. Rune does not keep a second copy "
            + "of them, so there is only ever one file to edit. The Ghostty tab edits it "
            + "for you.")
        terminalNote.font = .systemFont(ofSize: 11)
        terminalNote.textColor = .secondaryLabelColor
        terminalNote.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(terminalNote)

        let openConfig = NSButton(
            title: "Open Ghostty Config", target: self, action: #selector(openGhosttyConfig))
        openConfig.bezelStyle = .rounded
        stack.addArrangedSubview(openConfig)

        syncAppearance()
        return stack
    }

    private func row(_ title: String, _ control: NSView, note: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let caption = NSTextField(wrappingLabelWithString: note)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 460

        let head = NSStackView(views: [label, control])
        head.spacing = 12
        head.alignment = .centerY

        let stack = NSStackView(views: [head, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func indented(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        return stack
    }

    private func syncAppearance() {
        let settings = Settings.shared
        accentWell.color = settings.effectiveAccent
        accentWell.isEnabled = settings.accent != nil
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
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        NSWorkspace.shared.open(url)
    }


    // MARK: - Ghostty

    private var ghosttyRows: [GhosttyOptionRow] = []
    private let configPathLabel = NSTextField(labelWithString: "")
    private let configWarning = NSTextField(labelWithString: "")

    /// Edits waiting to be written, keyed by config key. A `nil` value means
    /// "take the key out".
    ///
    /// Coalesced rather than written per keystroke: dragging an opacity slider
    /// fires continuously, and each write is a file replace plus a full
    /// libghostty config rebuild pushed to every surface.
    private var pendingEdits: [String: String?] = [:]
    private var flushWork: DispatchWorkItem?

    private func makeGhosttyPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 12, right: 20)

        for group in GhosttyOptions.groups {
            let heading = NSTextField(labelWithString: group.name.uppercased())
            heading.font = .systemFont(ofSize: 10, weight: .semibold)
            heading.textColor = .tertiaryLabelColor
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
            list.addArrangedSubview(spacer)
            list.addArrangedSubview(heading)

            for option in group.options {
                let row = GhosttyOptionRow(option: option)
                row.onChange = { [weak self] value in self?.edit(option.key, to: value) }
                ghosttyRows.append(row)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true

                if let note = option.note {
                    let caption = NSTextField(wrappingLabelWithString: note)
                    caption.font = .systemFont(ofSize: 10)
                    caption.textColor = .secondaryLabelColor
                    caption.preferredMaxLayoutWidth = 440
                    list.addArrangedSubview(caption)
                }
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        configPathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle

        configWarning.font = .systemFont(ofSize: 11)
        configWarning.textColor = .systemOrange
        configWarning.maximumNumberOfLines = 3

        let open = NSButton(
            title: "Open in Editor", target: self, action: #selector(openGhosttyConfig))
        open.bezelStyle = .rounded
        let reveal = NSButton(
            title: "Reveal in Finder", target: self, action: #selector(revealGhosttyConfig))
        reveal.bezelStyle = .rounded
        let buttons = NSStackView(views: [open, reveal])
        buttons.spacing = 8

        let footer = NSStackView(views: [configPathLabel, configWarning, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        for view in [configPathLabel, configWarning, footer] {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        configPathLabel.translatesAutoresizingMaskIntoConstraints = false
        configPathLabel.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -40).isActive = true

        reloadGhosttyRows()
        return stack
    }

    /// Read the file and put every row back in step with it.
    ///
    /// Called whenever the pane is shown, not only after an edit: the file is a
    /// file, and someone may well have opened it in an editor since.
    private func reloadGhosttyRows() {
        let file = GhosttyConfigFile()
        for row in ghosttyRows { row.show(file.value(for: row.option.key)) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        configPathLabel.stringValue = file.url.path.replacingOccurrences(
            of: home, with: "~")

        var warnings: [String] = []
        if GhosttyConfigFile.hasMultipleFiles {
            warnings.append(
                "More than one Ghostty config file exists. Ghostty loads them all and the "
                + "last one wins, which is the one shown above.")
        }
        warnings.append(contentsOf: NSApp.ghosttyApp?.configDiagnostics() ?? [])
        configWarning.stringValue = warnings.joined(separator: "\n")
        configWarning.isHidden = warnings.isEmpty
    }

    private func edit(_ key: String, to value: String?) {
        pendingEdits[key] = value
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushEdits() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
            configWarning.stringValue = "Could not write \(file.url.path): \(error.localizedDescription)"
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
        alert.messageText = "Remove \(present.count) setting\(present.count == 1 ? "" : "s") from your Ghostty config?"
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

    @objc private func revealGhosttyConfig() {
        let url = GhosttyConfigFile.location
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Shortcuts

    private var recorders: [ShortcutRecorder] = []
    private let conflictLabel = NSTextField(labelWithString: "")

    private func makeShortcutsPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 12, right: 20)

        for group in ShortcutAction.grouped {
            let heading = NSTextField(labelWithString: group.name.uppercased())
            heading.font = .systemFont(ofSize: 10, weight: .semibold)
            heading.textColor = .tertiaryLabelColor
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
            list.addArrangedSubview(spacer)
            list.addArrangedSubview(heading)

            for action in group.actions {
                let recorder = ShortcutRecorder(action: action)
                recorder.onRecorded = { [weak self] chord in self?.bind(chord, to: action) }
                recorders.append(recorder)

                let label = NSTextField(labelWithString: action.title)
                label.font = .systemFont(ofSize: 12)
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let row = NSStackView(views: [label, recorder])
                row.alignment = .centerY
                row.distribution = .fill
                row.translatesAutoresizingMaskIntoConstraints = false
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed

        let hint = NSTextField(labelWithString:
            "Click a shortcut and press the new keys. Escape cancels, Delete restores the default.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [scroll, hint, conflictLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // The scroll view is the one thing here that should give up height —
        // it has a scroller for exactly that. Left at the default priorities it
        // claimed its whole content instead, ran off the bottom of the window,
        // and drew the tail of the list straight over the hint text.
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for label in [hint, conflictLabel] {
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        return stack
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
}

/// The click-then-type control for one binding.
///
/// While recording it takes key events from a local monitor rather than from
/// `keyDown`. Menu key equivalents are matched before the responder chain runs,
/// so pressing ⌘T to bind it would open a tab and the recorder would never hear
/// the key at all.
@MainActor
private final class ShortcutRecorder: NSButton {
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
        target = self
        self.action = #selector(beginRecording)
        font = .systemFont(ofSize: 12)
        alignment = .center
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        title = recording ? "Type a shortcut…" : Settings.shared.chord(for: binding).display
        contentTintColor = recording ? .controlAccentColor : nil
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
