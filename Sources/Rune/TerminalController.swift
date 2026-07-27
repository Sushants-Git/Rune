import Cocoa
import GhosttyKit

/// A group of tabs that share a tab strip. One workspace is on screen at a
/// time; ⌘K moves between them.
@MainActor
final class Workspace {
    let id = UUID()

    /// The tabs in this workspace, in creation order. The strip never reorders.
    private(set) var tabs: [Tab] = []
    /// The tab currently on screen when this workspace is the visible one.
    var activeTab: Tab?

    /// Tab IDs most-recently-used first. Only used to pick a survivor when a
    /// tab closes — nothing user-visible is ordered by it.
    private var mruOrder: [UUID] = []

    init(first tab: Tab) {
        add(tab)
        activeTab = tab
    }

    func add(_ tab: Tab) {
        tabs.append(tab)
        touch(tab)
    }

    func touch(_ tab: Tab) {
        mruOrder.removeAll { $0 == tab.id }
        mruOrder.insert(tab.id, at: 0)
    }

    func contains(_ tab: Tab) -> Bool {
        tabs.contains { $0 === tab }
    }

    /// The tab holding `surface`, if any.
    func tab(owning surface: GhosttySurfaceView) -> Tab? {
        tabs.first { $0.contains(surface) }
    }

    /// Remove `tab` and return the one that should take its place, if any.
    func remove(_ tab: Tab) -> Tab? {
        tabs.removeAll { $0 === tab }
        mruOrder.removeAll { $0 == tab.id }
        if activeTab === tab { activeTab = nil }
        return mruOrder.first.flatMap { id in tabs.first { $0.id == id } } ?? tabs.last
    }

    var isEmpty: Bool { tabs.isEmpty }

    /// Every terminal in the workspace, across all tabs and their splits.
    var surfaces: [GhosttySurfaceView] { tabs.flatMap(\.surfaces) }

    /// A name set with ⌘R. Nil means "whatever the terminal calls itself".
    var customName: String?

    /// What ⌘K calls this workspace.
    var title: String { customName ?? automaticTitle }

    /// The name the workspace would have without ⌘R — what its visible terminal
    /// is doing.
    var automaticTitle: String { activeTab?.title ?? "Terminal" }

    var directory: String? { activeTab?.directory }

    /// What ⌘K's filter matches: the name shown on the row, and nothing else.
    /// Matching against directories or background tabs made rows light up for
    /// reasons you couldn't see.
    var searchText: String { title }
}

/// One macOS window, holding any number of workspaces.
///
/// Rune has two axes and each list holds exactly one kind of thing:
///
/// - **Tabs** live in the strip inside the title bar, and belong to a
///   workspace. A workspace with a single tab shows no strip at all, just the
///   terminal's name centred where a title would go. A tab is itself a tree of
///   split panes — ⌘D and ⌘⇧D divide it.
/// - **Workspaces** are what ⌘K lists. ⌘N makes one; they all live in this same
///   window, so switching is instant and nothing moves on screen but the
///   terminal itself.
///
/// ⌘⇧N is the escape hatch to a genuinely separate macOS window.
@MainActor
final class TerminalController: NSWindowController, NSWindowDelegate {
    private let ghostty: GhosttyApp

    /// Every workspace in this window, in creation order — the order ⌘K lists
    /// them in, and it never changes as you move between them.
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspace: Workspace?

    /// Workspace IDs most-recently-used first, to pick a survivor on close.
    private var mruWorkspaces: [UUID] = []

    /// The tab on screen right now.
    var activeTab: Tab? { activeWorkspace?.activeTab }

    /// The focused terminal: the pane inside the visible tab that has the
    /// keyboard. Everything that acts on "the terminal" means this one.
    var activeSurface: GhosttySurfaceView? { activeTab?.focused }

    /// The strip's contents: the active workspace's tabs.
    var tabs: [Tab] { activeWorkspace?.tabs ?? [] }

    /// Every terminal in the window, across all workspaces, tabs and splits.
    var allSurfaces: [GhosttySurfaceView] { workspaces.flatMap(\.surfaces) }

    private let container = NSView()
    private let tabBar = TabBar()

    private var overlay: SwitcherOverlay?
    /// Where ⌘K was opened from. Arrow keys preview by actually swapping the
    /// workspace in, so cancelling has to put this one back.
    private weak var switcherOrigin: Workspace?

    init(ghostty: GhosttyApp) {
        self.ghostty = ghostty

        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Rune"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Deliberately NOT movableByWindowBackground: the terminal needs click
        // and drag for text selection.
        window.tabbingMode = .disallowed
        window.center()

        container.autoresizingMask = [.width, .height]
        // libghostty makes each surface view layer-hosting, which requires the
        // ancestor hierarchy to be layer-backed for anything to composite.
        container.wantsLayer = true
        window.contentView = container

        super.init(window: window)
        window.delegate = self
        window.controller = self

        tabBar.frame = NSRect(
            x: 0, y: container.bounds.height - TabBar.height,
            width: container.bounds.width, height: TabBar.height)
        tabBar.autoresizingMask = [.width, .minYMargin]
        tabBar.onSelect = { [weak self] tab in self?.select(tab) }
        tabBar.onClose = { [weak self] tab in self?.closeTab(tab) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        container.addSubview(tabBar)

        syncChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Height reserved at the top of the window. The title bar is transparent
    /// and the content is full-size, so the terminal has to keep clear of the
    /// window controls itself.
    private static let titlebarInset: CGFloat = 28

    /// The area a terminal surface occupies, below the window controls.
    private var terminalFrame: NSRect {
        var frame = container.bounds
        frame.size.height = max(0, frame.size.height - Self.titlebarInset)
        return frame
    }

    // MARK: - Making terminals

    /// Create a surface, wired up to keep the chrome in sync.
    private func makeSurface(workingDirectory: String?) -> GhosttySurfaceView? {
        // Inherit the cwd of the terminal you were in, which is what you almost
        // always want when opening a sibling.
        let cwd = workingDirectory ?? activeSurface?.pwd

        let view: GhosttySurfaceView
        do {
            view = try GhosttySurfaceView(app: ghostty, workingDirectory: cwd)
        } catch {
            log.error("failed to create surface: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(
                "Rune: failed to create surface for \(cwd ?? "~"): \(error)\n".data(using: .utf8)!)
            return nil
        }

        view.onFocusRequest = { [weak self, weak view] in
            guard let self, let view else { return }
            self.focus(view)
        }
        view.onMetadataChange = { [weak self, weak view] in
            guard let self, let view else { return }
            if view === self.activeSurface {
                self.syncWindowTitle()
                self.syncChrome()
            }
            self.syncTabBar()
            self.overlay?.palette.reload()
        }
        return view
    }

    /// ⌘T: another tab in the workspace you're looking at.
    @discardableResult
    func newTab(workingDirectory: String? = nil) -> Tab? {
        hideSwitcher()
        guard let workspace = activeWorkspace else {
            return newWorkspace(workingDirectory: workingDirectory)?.activeTab
        }
        guard let view = makeSurface(workingDirectory: workingDirectory) else { return nil }
        let tab = Tab(first: view)
        workspace.add(tab)
        select(tab)
        return tab
    }

    /// ⌘N: a new workspace in this same window, listed in ⌘K.
    @discardableResult
    func newWorkspace(workingDirectory: String? = nil) -> Workspace? {
        hideSwitcher()
        guard let view = makeSurface(workingDirectory: workingDirectory) else { return nil }
        let workspace = Workspace(first: Tab(first: view))
        workspaces.append(workspace)
        selectWorkspace(workspace)
        return workspace
    }

    /// ⌘D / ⌘⇧D: divide the focused pane.
    func splitActiveSurface(_ direction: SplitDirection) {
        hideSwitcher()
        guard let tab = activeTab, let surface = tab.focused else { return }
        guard let view = makeSurface(workingDirectory: surface.pwd) else { return }
        tab.split(surface, with: view, direction: direction)
        tab.applyDividerTint(dividerColor)
        tab.applyInactiveWash(inactivePaneWash)
        focus(view)
        syncTabBar()
        overlay?.palette.reload()
    }

    // MARK: - Closing

    /// ⌘W closes one terminal. Emptying a tab closes the tab, emptying a
    /// workspace closes the workspace, and emptying the window closes it —
    /// each level only collapses once the one below it is gone.
    func closeSurface(_ view: GhosttySurfaceView) {
        guard let workspace = workspaces.first(where: { $0.tab(owning: view) != nil }),
              let tab = workspace.tab(owning: view)
        else { return }

        let isVisible = tab === activeTab
        let successorSurface = tab.remove(view)
        view.close()

        if tab.isEmpty {
            closeTab(tab, in: workspace)
        } else if isVisible, let successorSurface {
            focus(successorSurface)
        }

        syncTabBar()
        overlay?.palette.reload()
    }

    /// Close a whole tab — every split in it.
    func closeTab(_ tab: Tab) {
        guard let workspace = workspaces.first(where: { $0.contains(tab) }) else { return }
        for surface in tab.surfaces {
            tab.remove(surface)
            surface.close()
        }
        closeTab(tab, in: workspace)
        syncTabBar()
        overlay?.palette.reload()
    }

    private func closeTab(_ tab: Tab, in workspace: Workspace) {
        tab.view.removeFromSuperview()
        let successor = workspace.remove(tab)

        if workspace.isEmpty {
            workspaces.removeAll { $0 === workspace }
            mruWorkspaces.removeAll { $0 == workspace.id }
            if activeWorkspace === workspace { activeWorkspace = nil }

            // Fall back to the most recently used surviving workspace.
            guard let next = mruWorkspaces.first
                .flatMap({ id in workspaces.first { $0.id == id } }) ?? workspaces.last
            else {
                window?.close()
                return
            }
            selectWorkspace(next)
        } else if workspace === activeWorkspace, let successor {
            select(successor)
        }
    }

    func closeActiveSurface() {
        guard let activeSurface else { return }
        closeSurface(activeSurface)
    }

    /// ⌘⇧W closes the whole window; ⌘W only ever closes one terminal.
    func closeWindow() {
        window?.performClose(nil)
    }

    // MARK: - Selecting

    /// Make `tab` the visible one and give its focused pane the keyboard.
    func select(_ tab: Tab) {
        hideSwitcher()
        guard let workspace = workspaces.first(where: { $0.contains(tab) }) else { return }
        workspace.activeTab = tab
        workspace.touch(tab)

        if workspace !== activeWorkspace { setActiveWorkspace(workspace) }
        showTab(tab)
        if let surface = tab.focused ?? tab.surfaces.first { focus(surface) }
    }

    /// Move the keyboard to a specific pane within the visible tab.
    func focus(_ surface: GhosttySurfaceView) {
        guard let tab = activeTab, tab.contains(surface) else { return }
        // Already settled — and the guard matters, because making a surface
        // first responder calls back in here through `becomeFirstResponder`.
        guard tab.focused !== surface || window?.firstResponder !== surface else { return }

        hideSwitcher()
        tab.focus(surface)
        window?.makeFirstResponder(surface)
        syncWindowTitle()
        syncChrome()
        syncTabBar()
    }

    /// ⌘K commits: switch to a workspace and take the keyboard with you.
    func selectWorkspace(_ workspace: Workspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        setActiveWorkspace(workspace)
        guard let tab = workspace.activeTab ?? workspace.tabs.first else { return }
        workspace.activeTab = tab
        showTab(tab)
        if let surface = tab.focused ?? tab.surfaces.first { focus(surface) }
    }

    /// ⌘K previews: show a workspace without touching focus or the MRU order,
    /// so the search field keeps the keyboard and nothing is committed until
    /// you press Enter.
    private func previewWorkspace(_ workspace: Workspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        activeWorkspace = workspace
        guard let tab = workspace.activeTab ?? workspace.tabs.first else { return }
        showTab(tab)
    }

    private func setActiveWorkspace(_ workspace: Workspace) {
        activeWorkspace = workspace
        mruWorkspaces.removeAll { $0 == workspace.id }
        mruWorkspaces.insert(workspace.id, at: 0)
    }

    /// Swap which tab is on screen. Everything else keeps running; hidden
    /// surfaces just stop rendering.
    private func showTab(_ tab: Tab) {
        for other in workspaces.flatMap(\.tabs) where other !== tab && other.view.superview != nil {
            other.view.removeFromSuperview()
            for surface in other.surfaces {
                // Note the argument is "visible", not "occluded".
                if let handle = surface.surface {
                    ghostty_surface_set_occlusion(handle, false)
                }
            }
        }

        // Add first, then size: a surface needs to be in a window before it can
        // resolve the backing scale factor for its framebuffer.
        if tab.view.superview !== container {
            container.addSubview(tab.view, positioned: .below, relativeTo: tabBar)
        }
        tab.view.frame = terminalFrame
        tab.view.layoutSubtreeIfNeeded()

        for surface in tab.surfaces {
            if let handle = surface.surface {
                ghostty_surface_set_occlusion(handle, true)
            }
            // A surface that comes back at exactly the size it left at gets no
            // resize notification, and so would sit showing whatever the
            // renderer last composited — which is how a switch could appear not
            // to happen at all. Ask for a frame explicitly.
            surface.requestRender()
        }
        tab.syncFocusBorders()

        syncWindowTitle()
        syncTabBar()
        syncChrome()
    }

    /// ⌘1–⌘9 index the ⌘K list.
    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaces[index])
    }

    /// ⌘1–⌘9 index the strip.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// ⌘⇧[ / ⌘⇧] cycle the strip, wrapping at both ends.
    func selectRelativeTab(offset: Int) {
        let tabs = self.tabs
        guard !tabs.isEmpty else { return }
        guard let activeTab, let current = tabs.firstIndex(where: { $0 === activeTab }) else {
            select(offset >= 0 ? tabs[0] : tabs[tabs.count - 1])
            return
        }
        let next = (current + offset % tabs.count + tabs.count) % tabs.count
        select(tabs[next])
    }

    // MARK: - Splits

    /// ⌘⌥arrows: move the keyboard to the pane in that direction.
    func focusSplit(_ direction: SplitDirection) {
        guard let tab = activeTab, let surface = tab.focused,
              let target = tab.neighbor(of: surface, direction: direction)
        else { return }
        focus(target)
    }

    /// ⌘⌥[ / ⌘⌥] cycle panes in layout order.
    func focusRelativeSplit(offset: Int) {
        guard let tab = activeTab, let surface = tab.focused,
              let target = tab.relativeSurface(from: surface, offset: offset)
        else { return }
        focus(target)
    }

    func resizeSplit(_ direction: SplitDirection, amount: CGFloat) {
        guard let tab = activeTab, let surface = tab.focused else { return }
        tab.resize(surface, direction: direction, amount: amount)
    }

    func equalizeSplits() {
        activeTab?.equalize()
    }

    // MARK: - Chrome

    private func syncTabBar() {
        tabBar.update(
            tabs: tabs, active: activeTab, workspaceName: activeWorkspace?.customName)
    }

    /// What an idle split pane is washed with: the terminal's own background,
    /// pushed darker and left partly transparent so the pane's text fades into
    /// it. Mixed from the background rather than being flat black so it still
    /// reads on a theme that's already near-black.
    private var inactivePaneWash: NSColor {
        let background = activeSurface?.backgroundColor ?? ghostty.backgroundColor
        let sunk = background.blended(withFraction: 0.4, of: .black) ?? .black
        return sunk.withAlphaComponent(0.66)
    }

    /// Split dividers are a seam in the terminal, not window chrome, so they're
    /// a hair lighter or darker than the background rather than a grey line.
    private var dividerColor: NSColor {
        let background = activeSurface?.backgroundColor ?? ghostty.backgroundColor
        return background.isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.16)
    }

    /// Paint the title bar area in the terminal's own background colour so the
    /// window reads as one surface instead of a terminal with a grey hat.
    private func syncChrome() {
        let color = activeSurface?.backgroundColor ?? ghostty.backgroundColor
        window?.backgroundColor = color
        container.layer?.backgroundColor = color.cgColor
        tabBar.backgroundColor = color
        activeTab?.applyDividerTint(dividerColor)
        activeTab?.applyInactiveWash(inactivePaneWash)
        // Keep the traffic lights and the switcher's vibrancy legible against
        // whatever the terminal theme is.
        window?.appearance = NSAppearance(named: color.isDark ? .darkAqua : .aqua)
    }

    private func syncWindowTitle() {
        if let name = activeWorkspace?.customName {
            window?.title = name
            return
        }
        guard let surface = activeSurface else { return }
        window?.title = surface.shortTitle
    }

    // MARK: - Switcher

    var isSwitcherVisible: Bool { overlay != nil }

    func toggleSwitcher() {
        if isSwitcherVisible { dismissSwitcher() } else { showSwitcher() }
    }

    func showSwitcher() {
        guard overlay == nil, !workspaces.isEmpty else { return }

        let origin = activeWorkspace
        switcherOrigin = origin

        let palette = SwitcherPalette(
            items: { [weak self] in
                guard let self else { return [] }
                return self.workspaces.map { workspace in
                    PaletteItem(
                        title: workspace.title,
                        subtitle: Self.subtitle(for: workspace),
                                        badge: Self.badge(for: workspace),
                        isCurrent: workspace === origin,
                        icon: Self.icon(for: workspace),
                        searchText: workspace.searchText,
                        editableName: workspace.customName ?? "",
                        automaticTitle: workspace.automaticTitle)
                }
            },
            onPreview: { [weak self] index in
                guard let self, let workspace = self.workspaces[safe: index] else { return }
                self.previewWorkspace(workspace)
            },
            onCommit: { [weak self] index in
                guard let self else { return }
                let target = self.workspaces[safe: index]
                self.closeSwitcher()
                if let target { self.selectWorkspace(target) }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                // Nothing chosen means go back to where ⌘K was opened from,
                // undoing whatever the arrow keys previewed.
                let target = self.switcherOrigin
                self.closeSwitcher()
                if let target { self.selectWorkspace(target) }
            })

        palette.onRename = { [weak self] index, name in
            guard let self, let workspace = self.workspaces[safe: index] else { return }
            workspace.customName = name.isEmpty ? nil : name
            self.syncTabBar()
            self.syncWindowTitle()
        }

        let overlay = SwitcherOverlay(palette: palette)
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        window?.makeFirstResponder(palette.searchField)
    }

    /// Close the switcher without selecting, returning to where it was opened.
    func dismissSwitcher() {
        overlay?.palette.cancel()
    }

    /// Put the switcher away because something else is about to take over the
    /// screen — a new tab, a split, a different window. Unlike ⎋ this doesn't
    /// rewind to where ⌘K was opened from: you asked for the new thing while
    /// looking at the previewed workspace, so that's where it belongs.
    func hideSwitcher() {
        closeSwitcher()
    }

    /// Tear the overlay down. Selection and restore are the caller's business.
    private func closeSwitcher() {
        guard let overlay else { return }
        overlay.removeFromSuperview()
        self.overlay = nil
        switcherOrigin = nil
        if let surface = activeSurface { window?.makeFirstResponder(surface) }
    }

    /// Count whichever thing there's more than one of — tabs if the workspace
    /// has several, otherwise panes if the single tab is split.
    private static func badge(for workspace: Workspace) -> String? {
        if workspace.tabs.count > 1 { return "\(workspace.tabs.count) tabs" }
        let panes = workspace.surfaces.count
        return panes > 1 ? "\(panes) panes" : nil
    }

    // MARK: - Renaming

    var isRenaming: Bool { overlay?.palette.isRenaming ?? false }

    /// ⌘R names a workspace, editing the ⌘K row in place. If the switcher
    /// isn't up it opens first — the name lives in that list, so that's where
    /// you should be looking while you change it.
    func renameWorkspace() {
        if overlay == nil { showSwitcher() }
        overlay?.palette.beginRename()
    }

    func cancelRename() {
        overlay?.palette.cancelRename()
    }

    /// What marks the row: the agent running there if Rune knows it, else the
    /// project's own icon, else nothing and the row falls back to a glyph.
    private static func icon(for workspace: Workspace) -> NSImage? {
        if let agent = workspace.activeTab?.focused?.agent { return agent.image }
        return workspace.directory.flatMap(ProjectIcon.image(forDirectory:))
    }

    /// The row's second line: where the workspace *is*, not what it's called.
    /// The name is already the last component, so repeating the whole path
    /// would just say the same thing twice.
    private static func subtitle(for workspace: Workspace) -> String {
        guard let path = workspace.directory else { return "" }
        let home = NSHomeDirectory()
        let abbreviated = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parent = (abbreviated as NSString).deletingLastPathComponent
        return parent == "/" || parent.isEmpty ? "" : parent
    }

    // MARK: - Forwarding to the active surface

    /// Trigger a libghostty keybinding action (e.g. "copy_to_clipboard") on the
    /// active surface. See Ghostty's docs for the action grammar.
    func performSurfaceAction(_ action: String) {
        guard let surface = activeSurface?.surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Whether a surface belongs to this window.
    func owns(_ view: GhosttySurfaceView) -> Bool {
        workspaces.contains { $0.tab(owning: view) != nil }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for surface in allSurfaces { surface.close() }
        workspaces.removeAll()
        mruWorkspaces.removeAll()
        activeWorkspace = nil
        (NSApp.delegate as? AppDelegate)?.controllerWillClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Becoming key makes AppKit install the window's *initial* first
        // responder, which is whatever view happens to be first in the key
        // loop. Put the keyboard back on the pane the tab says is focused,
        // otherwise the two drift apart and clicking a split stops working.
        if let surface = activeSurface, window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
        }
        activeSurface?.setFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        activeSurface?.setFocus(false)
    }
}

/// NSWindow subclass that gives the controller first crack at key equivalents
/// the menu doesn't claim, and that can become key without a title bar.
final class TerminalWindow: NSWindow {
    weak var controller: TerminalController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Escape closes the switcher before anything else sees it: with the
        // search field empty, AppKit routes it here rather than to the field
        // editor's cancelOperation:.
        if event.keyCode == 53 {
            if controller?.isRenaming == true {
                controller?.cancelRename()
                return true
            }
            if controller?.isSwitcherVisible == true {
                controller?.dismissSwitcher()
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}

