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

    /// The loudest thing anything in this workspace is doing.
    var status: Status { Status.loudest(of: surfaces.map(\.status)) }

    /// A name set with ⌘R. Nil means "whatever the terminal calls itself".
    var customName: String?

    /// What ⌘K calls this workspace.
    var title: String { customName ?? automaticTitle }

    /// The name the workspace would have without ⌘R — what its visible terminal
    /// is doing.
    ///
    /// Codex's spinner is taken off here and nowhere else. The title bar and
    /// the tab chip want it — that's the terminal's own liveness, shown where
    /// it put it. A ⌘K row doesn't: the list is something you read and filter
    /// while arrowing through it, and a name that rewrites itself five times a
    /// second is a name you can't read. The row already says "working" in
    /// words, which is the same fact standing still.
    var automaticTitle: String {
        CodexTitle.withoutSpinner(activeTab?.title ?? "Terminal")
    }

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

    /// Workspace IDs pinned to the top of ⌘K, **in the order they were pinned**.
    /// Appending is the whole feature: pins stack, so the first thing you pin
    /// stays first and you can build the order you want by pinning in it.
    private var pinnedWorkspaces: [UUID] = []

    /// The order workspaces are actually presented in: pinned ones first, in
    /// the order they were pinned, then everything else in creation order.
    ///
    /// This — not `workspaces` — is what ⌘K lists and what ⌘1–⌘9 address, so
    /// the number you press is always the position you can see. Every index
    /// that crosses the palette boundary is an index into this.
    var orderedWorkspaces: [Workspace] {
        let pinned = pinnedWorkspaces.compactMap { id in workspaces.first { $0.id == id } }
        let rest = workspaces.filter { !pinnedWorkspaces.contains($0.id) }
        return pinned + rest
    }

    func isPinned(_ workspace: Workspace) -> Bool {
        pinnedWorkspaces.contains(workspace.id)
    }

    /// ⌘P: pin or unpin. Pinning appends rather than inserting at the front, so
    /// pinning A then B leaves A above B — the order you pinned them in, which
    /// is the order you were thinking in.
    func togglePin(_ workspace: Workspace) {
        if let existing = pinnedWorkspaces.firstIndex(of: workspace.id) {
            pinnedWorkspaces.remove(at: existing)
        } else {
            pinnedWorkspaces.append(workspace.id)
        }
    }

    /// The tab on screen right now.
    var activeTab: Tab? { activeWorkspace?.activeTab }

    /// The focused terminal: the pane inside the visible tab that has the
    /// keyboard. Everything that acts on "the terminal" means this one.
    var activeSurface: GhosttySurfaceView? { activeTab?.focused }

    /// The strip's contents: the active workspace's tabs.
    var tabs: [Tab] { activeWorkspace?.tabs ?? [] }

    /// Every terminal in the window, across all workspaces, tabs and splits.
    var allSurfaces: [GhosttySurfaceView] { workspaces.flatMap(\.surfaces) }

    private let container = ContainerView()
    private let tabBar = TabBar()

    private(set) var overlay: SwitcherOverlay?

    /// The diff, when it is open. Nil is the normal state.
    private var diffPanel: DiffPanel?
    private var diffWidth: CGFloat = 0
    /// The width the panel had before ⌘⇧↵ filled the window with it, so putting
    /// it back means putting it back exactly.
    private var diffWidthBeforeZoom: CGFloat?
    /// Watches the repository the diff is showing, so it keeps up with whoever
    /// else is writing to it.
    private var diffWatcher: RepositoryWatcher?
    private var diffWatchedRoot: String?
    private var activityTimer: Timer?

    /// Reads agent state off the main thread. See `AgentSession.swift`.
    private let monitor = AgentMonitor()
    /// One poll in flight at a time — the log reads are cheap but not free, and
    /// stacking them up behind a slow disk would help nobody.
    private var isPolling = false

    /// Set when something asked for the chrome to be brought up to date, and
    /// cleared on the next runloop pass when it actually is.
    ///
    /// Metadata arrives at whatever rate the program feels like writing escape
    /// sequences — an agent that spins in the window title emits dozens of
    /// title changes a second — and every one of them used to rebuild the tab
    /// strip and re-derive the window appearance synchronously. Coalescing
    /// means a burst costs one rebuild.
    private var chromeSyncScheduled = false
    private var pendingChrome: ChromeWork = []

    private struct ChromeWork: OptionSet {
        let rawValue: Int
        static let title = ChromeWork(rawValue: 1 << 0)
        static let colors = ChromeWork(rawValue: 1 << 1)
        static let tabBar = ChromeWork(rawValue: 1 << 2)
        static let palette = ChromeWork(rawValue: 1 << 3)
    }

    /// The last colour the chrome was painted with, so a sync that changes
    /// nothing costs a comparison instead of a window-wide invalidation.
    private var appliedChromeColor: NSColor?
    private var appliedOpacity: Double?
    private var appliedDarkAppearance: Bool?
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

        // After `super.init`, since it captures self. The terminal area and the
        // diff panel share this space, and two siblings autoresizing
        // independently would both claim the full width — so one place decides,
        // on every resize.
        container.onLayout = { [weak self] in self?.layoutContent() }

        // A reloaded config can change the terminal's colours without any
        // surface reporting a change, and `syncChrome` short-circuits when the
        // colour it computes matches the one it last painted. Clearing that
        // memory first is what makes the repaint actually happen.
        NotificationCenter.default.addObserver(
            forName: GhosttyApp.configReloaded, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.invalidateChromeColor()
                    self?.syncChromeNow([.title, .colors, .tabBar, .palette])
                }
            }
        window.delegate = self
        window.controller = self

        tabBar.frame = NSRect(
            x: 0, y: container.bounds.height - TabBar.height,
            width: container.bounds.width, height: TabBar.height)
        tabBar.autoresizingMask = [.width, .minYMargin]
        tabBar.onSelect = { [weak self] tab in self?.select(tab) }
        tabBar.onClose = { [weak self] tab in self?.closeTab(tab) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onResetZoom = { [weak self] in self?.toggleSplitZoom() }
        container.addSubview(tabBar)

        syncChrome()
        startActivityTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// What a terminal is doing is partly a question about elapsed time, so
    /// nothing pushes a change when one goes quiet — the chrome has to re-ask.
    ///
    /// This is the only place the expensive part happens: reading the
    /// foreground process and the rendered screen. Everything else in Rune
    /// reads the answer this leaves behind.
    private func startActivityTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActivity() }
        }
        // Slack, because this is housekeeping: letting the runloop fold it in
        // with work it was doing anyway beats waking the CPU for it. And left
        // in the default mode on purpose, so it stays out of the way while
        // you're dragging a divider or resizing the window.
        timer.tolerance = 0.4
        activityTimer = timer
    }

    /// The main thread's entire share of working out what the agents are doing:
    /// one `tcgetpgrp` per terminal. Identifying the process, finding its
    /// session log and reading it all happen on the monitor's own queue, so
    /// none of it can land in the middle of a scroll.
    private func refreshActivity() {
        guard !isPolling else { return }
        let surfaces = allSurfaces
        guard !surfaces.isEmpty else { return }

        let probes = surfaces.map { surface in
            AgentProbe(
                surface: surface.id, pid: surface.foregroundPID,
                directory: surface.workingDirectory, title: surface.title)
        }

        isPolling = true
        monitor.probe(probes) { [weak self] verdicts in
            guard let self else { return }
            self.isPolling = false
            self.apply(verdicts)
        }
    }

    private func apply(_ verdicts: [AgentVerdict]) {
        let byID = Dictionary(verdicts.map { ($0.surface, $0) }, uniquingKeysWith: { a, _ in a })

        var changed = false
        for surface in allSurfaces {
            guard let verdict = byID[surface.id] else { continue }
            // Not `||`, which would short-circuit and stop updating the rest.
            if surface.apply(verdict) { changed = true }
        }
        guard changed else { return }

        // Not the palette while a row is being renamed: reloading rebuilds the
        // table and would tear the field editor out from under the cursor.
        var work: ChromeWork = [.tabBar]
        if overlay?.palette?.isRenaming != true { work.insert(.palette) }
        scheduleChromeSync(work)
    }

    // MARK: - Chrome scheduling

    /// Ask for chrome work to happen once, on the next runloop pass.
    private func scheduleChromeSync(_ work: ChromeWork) {
        pendingChrome.formUnion(work)
        guard !chromeSyncScheduled else { return }
        chromeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushChromeSync() }
    }

    private func flushChromeSync() {
        chromeSyncScheduled = false
        let work = pendingChrome
        pendingChrome = []

        if work.contains(.title) { syncWindowTitle() }
        if work.contains(.colors) { syncChrome() }
        if work.contains(.tabBar) { syncTabBar() }
        if work.contains(.palette), overlay?.palette?.isRenaming != true {
            overlay?.palette?.reload()
        }
    }

    /// Do the pending chrome work now rather than next pass. For the moments
    /// where the next thing to happen is user-visible and must not flash — a
    /// tab switch, a new window — and one runloop turn late would show.
    private func syncChromeNow(_ work: ChromeWork) {
        pendingChrome.formUnion(work)
        flushChromeSync()
    }

    /// Height reserved at the top of the window. The title bar is transparent
    /// and the content is full-size, so the terminal has to keep clear of the
    /// window controls itself.
    private static let titlebarInset: CGFloat = 28

    /// The area a terminal surface occupies, below the window controls.
    private var terminalFrame: NSRect {
        var frame = container.bounds
        frame.size.height = max(0, frame.size.height - Self.titlebarInset)
        frame.size.width = max(0, frame.size.width - diffWidth)
        return frame
    }

    /// The strip down the right, when the diff is open.
    /// Whether the keyboard is inside the diff panel, which is what decides
    /// who ⌘⇧↵ is talking to.
    var isDiffFocused: Bool {
        guard let panel = diffPanel, let responder = window?.firstResponder as? NSView
        else { return false }
        return responder === panel || responder.isDescendant(of: panel)
    }

    /// ⌘⇧↵ with the diff focused: fill the window with it, or put the terminal
    /// back. The same key zooms a split pane when a terminal has the keyboard,
    /// which is the same idea applied to whichever thing you are reading.
    func toggleDiffZoom() {
        guard diffPanel != nil else { return }
        if let previous = diffWidthBeforeZoom {
            diffWidth = previous
            diffWidthBeforeZoom = nil
        } else {
            diffWidthBeforeZoom = diffWidth
            diffWidth = container.bounds.width
        }
        layoutContent()
    }

    private var diffFrame: NSRect {
        NSRect(
            x: container.bounds.width - diffWidth, y: 0,
            width: diffWidth, height: max(0, container.bounds.height - Self.titlebarInset))
    }

    private func layoutContent() {
        activeTab?.view.frame = terminalFrame
        diffPanel?.frame = diffFrame
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
            var work: ChromeWork = [.tabBar, .palette]
            if view === self.activeSurface { work.formUnion([.title, .colors]) }
            self.scheduleChromeSync(work)
        }
        // Set here rather than when a bar is created: this one has to be live
        // *before* there is any UI, because it is how libghostty asks for the
        // UI in the first place.
        view.onSearchStart = { [weak self, weak view] needle in
            guard let self, let view else { return }
            self.beginSearch(on: view, needle: needle)
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
        overlay?.palette?.reload()
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
        monitor.forget(view.id)

        if tab.isEmpty {
            closeTab(tab, in: workspace)
        } else if isVisible, let successorSurface {
            focus(successorSurface)
        }

        syncTabBar()
        overlay?.palette?.reload()
    }

    /// Close a whole tab — every split in it.
    func closeTab(_ tab: Tab) {
        guard let workspace = workspaces.first(where: { $0.contains(tab) }) else { return }
        for surface in tab.surfaces {
            tab.remove(surface)
            surface.close()
            monitor.forget(surface.id)
        }
        closeTab(tab, in: workspace)
        syncTabBar()
        overlay?.palette?.reload()
    }

    private func closeTab(_ tab: Tab, in workspace: Workspace) {
        tab.view.removeFromSuperview()
        let successor = workspace.remove(tab)

        if workspace.isEmpty {
            workspaces.removeAll { $0 === workspace }
            mruWorkspaces.removeAll { $0 == workspace.id }
            pinnedWorkspaces.removeAll { $0 == workspace.id }
            if activeWorkspace === workspace { activeWorkspace = nil }

            // Fall back to the most recently used surviving workspace.
            guard let next = mruWorkspaces.first
                .flatMap({ id in workspaces.first { $0.id == id } }) ?? workspaces.last
            else {
                window?.close()
                return
            }
            if isSwitcherVisible {
                // ⌘C closed a row. Only re-point the view if the closed
                // workspace was the one showing behind the panel — and *preview*
                // it rather than select it, because selecting takes focus, and
                // taking focus dismisses the switcher. Closing a row isn't
                // choosing one.
                if activeWorkspace == nil { previewWorkspace(next) }
            } else {
                selectWorkspace(next)
            }
        } else if workspace === activeWorkspace, let successor {
            if isSwitcherVisible {
                workspace.activeTab = successor
                showTab(successor)
            } else {
                select(successor)
            }
        }
    }

    func closeActiveSurface() {
        guard let activeSurface else { return }
        closeSurface(activeSurface)
    }

    /// Close a whole workspace — every tab in it, and every split in those.
    ///
    /// Goes through `closeTab` per tab rather than tearing the workspace out
    /// directly, so the bookkeeping that already exists — telling libghostty a
    /// surface is gone, forgetting it in the activity monitor, picking the
    /// successor workspace, closing the window when the last one goes — happens
    /// exactly once each and in the right order.
    func closeWorkspace(_ workspace: Workspace) {
        for tab in workspace.tabs { closeTab(tab) }
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
        surface.clearAttention()
        window?.makeFirstResponder(surface)
        // The focused pane decides the chrome colour, so the cached one is
        // stale by definition here.
        invalidateChromeColor()
        syncChromeNow([.title, .colors, .tabBar])
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

        // A different tab means different panes to tint and wash, even when the
        // colour itself hasn't moved.
        invalidateChromeColor()
        syncChromeNow([.title, .colors, .tabBar])
    }

    /// ⌘1–⌘9 index the ⌘K list.
    func selectWorkspace(at index: Int) {
        // Addressed by what ⌘K shows, so ⌘2 is the second row you can see even
        // when pinning has moved it there.
        guard let workspace = orderedWorkspaces[safe: index] else { return }
        selectWorkspace(workspace)
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

    /// ⌘⇧↵: fill the tab with the focused pane, or put the layout back.
    func toggleSplitZoom() {
        // The diff answers this key when it is the thing you are reading.
        if isDiffFocused {
            toggleDiffZoom()
            return
        }
        hideSwitcher()
        guard let tab = activeTab, tab.surfaces.count > 1 else { return }
        tab.toggleZoom()
        // The zoomed pane is a new view in the hierarchy, so it has to be told
        // it still has the keyboard.
        if let surface = tab.focused { window?.makeFirstResponder(surface) }
        // The title bar's zoom indicator is the only thing that distinguishes a
        // zoomed pane from a tab that simply has one terminal in it.
        syncTabBar()
    }

    // MARK: - Chrome

    private func syncTabBar() {
        tabBar.update(
            tabs: tabs,
            active: activeTab,
            workspaceName: activeWorkspace?.customName,
            isZoomed: activeTab?.isZoomed ?? false)
    }

    /// What an idle split pane is washed with: the terminal's own background,
    /// pushed darker and left partly transparent so the pane's text fades into
    /// it. Mixed from the background rather than being flat black so it still
    /// reads on a theme that's already near-black.
    ///
    /// Light on purpose. The wash answers "which pane am I typing in" and
    /// nothing more — at the weight it used to be, the panes beside the live
    /// one were too dim to read, which defeats having split them.
    private var inactivePaneWash: NSColor {
        let background = activeSurface?.backgroundColor ?? ghostty.backgroundColor
        let sunk = background.blended(withFraction: 0.35, of: .black) ?? .black
        return sunk.withAlphaComponent(0.3)
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
    ///
    /// Every branch here is guarded on the colour having actually changed,
    /// which it almost never has. Assigning `window.appearance` in particular
    /// invalidates the appearance of every view in the window and forces the
    /// lot to redraw — doing that on each incoming title change is what made
    /// a busy terminal feel like it was dragging.
    private func syncChrome() {
        let color = activeSurface?.backgroundColor ?? ghostty.backgroundColor
        // Opacity is watched alongside the colour because it can change on its
        // own — the colour is identical either side of dragging the slider, and
        // guarding on the colour alone is why the setting appeared to do
        // nothing at all.
        let opacity = ghostty.backgroundOpacity
        guard color != appliedChromeColor || opacity != appliedOpacity else { return }
        appliedChromeColor = color
        appliedOpacity = opacity

        // An opaque window composites whatever the surface drew against a solid
        // sheet of this colour, so a renderer faithfully drawing at 70% alpha
        // still comes out looking like 100%. The window has to be told.
        let translucent = opacity < 0.999
        let sheet = translucent ? color.withAlphaComponent(opacity) : color
        window?.isOpaque = !translucent
        window?.backgroundColor = sheet
        container.layer?.backgroundColor = sheet.cgColor
        tabBar.backgroundColor = sheet
        activeTab?.applyDividerTint(dividerColor)
        activeTab?.applyInactiveWash(inactivePaneWash)
        activeTab?.applySearchTint(color)

        // Keep the traffic lights and the switcher's vibrancy legible against
        // whatever the terminal theme is. Only when the bucket flips: a new
        // NSAppearance is a new object even for the same name, and setting one
        // costs the whole window a redraw.
        let dark = color.isDark
        if dark != appliedDarkAppearance {
            appliedDarkAppearance = dark
            window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }

    /// Repaint the chrome even if the colour is unchanged — for when the thing
    /// that changed is *which* views need painting, not what colour they are.
    private func invalidateChromeColor() {
        appliedChromeColor = nil
        appliedOpacity = nil
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
                return self.orderedWorkspaces.map { workspace in
                    PaletteItem(
                        title: workspace.title,
                        subtitle: Self.subtitle(for: workspace),
                                        badge: Self.badge(for: workspace),
                        isCurrent: workspace === origin,
                        isPinned: self.isPinned(workspace),
                        isZoomed: workspace.activeTab?.isZoomed ?? false,
                        icon: Self.icon(for: workspace),
                        status: workspace.status,
                        searchText: workspace.searchText,
                        editableName: workspace.customName ?? "",
                        automaticTitle: workspace.automaticTitle)
                }
            },
            onPreview: { [weak self] index in
                guard let self, let workspace = self.orderedWorkspaces[safe: index] else { return }
                self.previewWorkspace(workspace)
            },
            onCommit: { [weak self] index in
                guard let self else { return }
                let target = self.orderedWorkspaces[safe: index]
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

        palette.onTogglePin = { [weak self] index in
            guard let self, let workspace = self.orderedWorkspaces[safe: index] else { return }
            self.togglePin(workspace)
            // The row just moved. Follow it, so pinning leaves you on the thing
            // you pinned rather than on whatever slid into its old position.
            let destination = self.orderedWorkspaces.firstIndex { $0 === workspace }
            self.overlay?.palette?.reload(selecting: destination)
        }

        palette.onCloseItem = { [weak self] index in
            guard let self, let workspace = self.orderedWorkspaces[safe: index] else { return }
            // Escape means "put me back where ⌘K was opened from", and that
            // can't be a workspace this just closed.
            if self.switcherOrigin === workspace { self.switcherOrigin = nil }
            self.closeWorkspace(workspace)

            // Land on a neighbour, not the top. `reload` anchors on the
            // selected row's index, and the row just closed no longer resolves
            // to anything — so it fell through to zero and threw you back to
            // the first workspace every time you closed the last one.
            //
            // Clamping to the new end gives the row that slid up into this
            // slot, or the one above when there is nothing below. Previewed,
            // because the terminal behind should agree with the highlight; it
            // used to keep showing the workspace you were looking at before.
            let remaining = self.orderedWorkspaces.count
            guard remaining > 0 else { return }
            // Closing the last one takes the window, and the overlay with it.
            self.overlay?.palette?.reload(selecting: min(index, remaining - 1), preview: true)
        }

        palette.onRename = { [weak self] index, name in
            guard let self, let workspace = self.orderedWorkspaces[safe: index] else { return }
            workspace.customName = name.isEmpty ? nil : name
            self.syncTabBar()
            self.syncWindowTitle()
        }

        present(palette)
    }

    /// Float a panel on the backdrop, taking whatever was already there down.
    private func present(_ panel: some OverlayPanel) {
        let overlay = SwitcherOverlay(panel: panel)
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        window?.makeFirstResponder(panel.focusView)
    }

    // MARK: - Todos

    var isTodosVisible: Bool { overlay?.panel is TodoPalette }

    /// ⌘J, when it's switched on in Settings.
    ///
    /// Opening it takes the switcher down if that was up, because they share
    /// the one panel — and because they are two answers to the same question at
    /// different scopes, so wanting both at once is not a state worth having.
    func toggleTodos() {
        guard Settings.shared.todosEnabled else { return }
        if isTodosVisible {
            closeSwitcher()
            return
        }
        if isSwitcherVisible { dismissSwitcher() }
        present(TodoPalette(onDismiss: { [weak self] in self?.closeSwitcher() }))
    }

    /// ⌘E: the uncommitted changes where the focused terminal is standing,
    /// beside it rather than over it. Pressing it again puts the width back.
    func toggleDiff() {
        if diffPanel != nil {
            closeDiff()
        } else {
            openDiff()
        }
    }

    private func openDiff() {
        let panel = DiffPanel()
        panel.autoresizingMask = []
        panel.onClose = { [weak self] in self?.closeDiff() }
        // Quiet: this fires because the panel just staged something, and it
        // already knows it did. A loud reload blanks the diff to "Reading…"
        // and paints it again, which for a keystroke that changed one line
        // reads as the whole panel flashing.
        panel.onNeedsReload = { [weak self] in self?.reloadDiff(quiet: true) }
        panel.onResize = { [weak self] width in
            guard let self else { return }
            let most = max(DiffPanel.minimumWidth, self.container.bounds.width - 300)
            self.diffWidth = min(max(width, DiffPanel.minimumWidth), most)
            self.layoutContent()
        }
        container.addSubview(panel, positioned: .below, relativeTo: tabBar)
        diffPanel = panel
        diffWidth = min(
            max(DiffPanel.minimumWidth, container.bounds.width * 0.52),
            max(DiffPanel.minimumWidth, container.bounds.width - 300))
        layoutContent()
        panel.takeFocus()
        reloadDiff()
    }

    /// Watch the repository the panel is currently showing.
    ///
    /// Guarded on the root because this is called after every reload, including
    /// the ones the watcher itself asked for: tearing the stream down and
    /// building it again every time is how you miss the write that lands in
    /// between.
    private func watchDiffRepository(root: String) {
        guard root != diffWatchedRoot else { return }
        diffWatchedRoot = root
        diffWatcher?.stop()
        diffWatcher = RepositoryWatcher(root: root) { [weak self] in
            MainActor.assumeIsolated { self?.reloadDiff(quiet: true) }
        }
    }

    private func closeDiff() {
        diffWatcher?.stop()
        diffWatcher = nil
        diffWatchedRoot = nil
        diffPanel?.removeFromSuperview()
        diffPanel = nil
        diffWidth = 0
        diffWidthBeforeZoom = nil
        layoutContent()
        if let surface = activeSurface { window?.makeFirstResponder(surface) }
    }

    /// Where the terminal is standing. OSC 7 when the shell says so, and the
    /// kernel's answer for the shell's own process when it doesn't — which is
    /// most shells, since Ghostty's integration has to be installed.
    private var diffDirectory: String? {
        guard let surface = activeSurface else { return nil }
        if let pwd = surface.pwd { return pwd }
        return GitDiff.workingDirectory(ofProcess: surface.foregroundPID)
    }

    /// - Parameter quiet: a reload nobody asked for — the watcher noticed a
    ///   write. It must not announce itself, must not throw away the selection,
    ///   and must not scroll you back to the top of a diff you were reading.
    func reloadDiff(quiet: Bool = false) {
        guard let panel = diffPanel else { return }
        guard let directory = diffDirectory else {
            panel.showMessage("Could not tell where this terminal is.")
            return
        }
        if !quiet { panel.showMessage("Reading…") }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GitDiff.uncommitted(in: directory) }
            let root = GitDiff.repositoryRoot(of: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let files):
                        panel.show(
                            files: files, root: root, directory: directory,
                            preservingScroll: quiet)
                        if let root { self.watchDiffRepository(root: root) }
                    case .failure(GitDiff.Failure.notARepository):
                        panel.showMessage("\(directory) is not in a git repository.")
                    case .failure(let error):
                        panel.showMessage("git: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// The diff's own keys, routed here because the panel is not in the
    /// responder chain the menu talks to.
    ///
    /// Only while the keyboard is inside the panel — the same rule the todo
    /// list follows, so a terminal never loses a keystroke to a panel it is
    /// merely sitting next to.
    func handleDiffKey(_ event: NSEvent) -> Bool {
        guard isDiffFocused, let panel = diffPanel else { return false }
        switch event.charactersIgnoringModifiers {
        // In the list a file is the unit; in the diff the selection is. Same
        // key, because it is the same intention either side of the seam.
        // Space moves things across in both halves: the file under the
        // highlight, or the lines under the selection. Already staged, and it
        // comes back out — which is the file list's rule, applied to lines.
        case " ":
            if panel.isReadingDiff {
                panel.stageSelectedLines()
            } else {
                panel.toggleStageSelection()
            }
        case "u":
            if panel.isReadingDiff {
                panel.stageSelectedLines(reverse: true)
            } else {
                panel.toggleStageSelection()
            }
        case "\t": panel.switchSide()
        case "b": panel.toggleSidebar()
        case "s": panel.stageHunk()
        case "S": panel.stageHunk(reverse: true)
        case "v": panel.toggleViewedSelection()
        case "h": panel.toggleHiddenSelection()
        case "c": panel.focusCommitMessage()
        case "n": panel.goToHunk(1)
        case "p": panel.goToHunk(-1)
        case "j": panel.moveInList(by: 1)
        case "k": panel.moveInList(by: -1)
        case "r": reloadDiff()
        default: return false
        }
        return true
    }

    /// ⌘W with the todo list up: delete the highlighted one.
    func deleteTodoSelection() {
        (overlay?.panel as? TodoPalette)?.deleteSelected()
    }

    /// Close the switcher without selecting, returning to where it was opened.
    func dismissSwitcher() {
        overlay?.palette?.cancel()
    }

    /// ⌘W in the switcher: close the highlighted workspace, stay open.
    func closeSwitcherSelection() {
        overlay?.palette?.closeSelected()
    }

    /// ⌘P in the switcher: pin the highlighted workspace to the top, or unpin.
    func togglePinOnSwitcherSelection() {
        overlay?.palette?.togglePinOnSelected()
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

    /// How many tabs a workspace has, when it has more than one.
    ///
    /// Panes are deliberately not counted here. A ⌘K row answers "where do I go
    /// next", and how a workspace happens to be divided up inside doesn't bear
    /// on that — you'll see the layout the moment you arrive. Tabs are worth
    /// saying because they're the thing hidden behind the one on screen.
    private static func badge(for workspace: Workspace) -> String? {
        workspace.tabs.count > 1 ? "\(workspace.tabs.count) tabs" : nil
    }

    // MARK: - Renaming

    var isRenaming: Bool { overlay?.palette?.isRenaming ?? false }

    /// ⌘R names a workspace, editing the ⌘K row in place. If the switcher
    /// isn't up it opens first — the name lives in that list, so that's where
    /// you should be looking while you change it.
    func renameWorkspace() {
        // ⌘R renames the row you are looking at, whichever list that is. With
        // the todo list up it would otherwise reach a switcher that isn't on
        // screen and do nothing at all.
        if let todos = overlay?.panel as? TodoPalette {
            todos.beginRename()
            return
        }
        if overlay == nil { showSwitcher() }
        overlay?.palette?.beginRename()
    }

    func cancelRename() {
        overlay?.palette?.cancelRename()
    }

    /// What marks the row: the agent running there if Rune knows it, else the
    /// project's own icon, else nothing and the row falls back to a glyph.
    /// What a ⌘K row shows, most specific first: the agent running in it, then
    /// any other program worth recognising, then the project's own icon.
    ///
    /// Shells come last, behind the project icon. A shell is the foreground
    /// process of every idle terminal, so ranking it normally would replace
    /// every project icon in the list with the same fish — a row that used to
    /// tell you *which* project you were looking at would stop doing so.
    private static func icon(for workspace: Workspace) -> NSImage? {
        let surface = workspace.activeTab?.focused
        if let agent = surface?.agent { return agent.image }
        let program = surface?.program
        if let program, !program.isAmbient { return program.image }
        if let project = workspace.directory.flatMap(ProjectIcon.image(forDirectory:)) {
            return project
        }
        return program?.image
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
    // MARK: - Find

    /// ⌘F. Opens the bar on the pane you are in, or re-focuses it if it is
    /// already there so the next thing typed replaces the last needle.
    func toggleSearch() {
        activeTab?.focusedPane?.showSearch()
    }

    /// ⌘G and ⇧⌘G. Deliberately does nothing without a bar up: stepping through
    /// results you cannot see, with no count and no way out, is worse than the
    /// key doing nothing at all.
    func navigateSearch(next: Bool) {
        guard let pane = activeTab?.focusedPane, pane.searchBar != nil else { return }
        pane.surface.navigateSearch(next: next)
    }

    func endSearch() {
        activeTab?.focusedPane?.hideSearch()
    }

    /// libghostty asked for the search UI — `search_selection`, or a
    /// `start_search` keybind in the user's own Ghostty config. It can name a
    /// surface that is not the focused one, so the pane is looked up rather
    /// than assumed.
    func beginSearch(on surface: GhosttySurfaceView, needle: String) {
        for workspace in workspaces {
            guard let tab = workspace.tab(owning: surface) else { continue }
            tab.pane(showing: surface)?.showSearch(needle: needle)
            return
        }
    }

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
        activityTimer?.invalidate()
        activityTimer = nil
        for surface in allSurfaces {
            surface.close()
            monitor.forget(surface.id)
        }
        workspaces.removeAll()
        mruWorkspaces.removeAll()
        activeWorkspace = nil
        (NSApp.delegate as? AppDelegate)?.controllerWillClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activeSurface?.setFocus(true)

        // Whichever panel is up owns the keyboard for as long as it's on
        // screen, and that has to survive leaving the app and coming back.
        // Becoming key installs the window's *initial* first responder — a
        // terminal — so without this the panel stayed up while ↑ and ↓ went to
        // the pane behind it, which reads as the app ignoring the keys.
        //
        // Asked of the panel rather than of the switcher specifically. It was
        // written when the switcher was the only panel there could be, and the
        // todo list came back from a trip to another app with no caret and its
        // typing going into the terminal underneath.
        if let field = overlay?.panelFocusView {
            // A rename owns its own field; the search field must not take it
            // back mid-edit. Only the switcher has renames.
            if overlay?.palette?.isRenaming == true { return }
            // An editing text field is represented by the shared field editor,
            // not by itself, so "is the panel's field focused" is a question
            // about who that editor is working for.
            let editor = window?.firstResponder as? NSTextView
            if editor?.delegate !== field {
                window?.makeFirstResponder(field)
            }
            return
        }

        // Becoming key makes AppKit install the window's *initial* first
        // responder, which is whatever view happens to be first in the key
        // loop. Put the keyboard back on the pane the tab says is focused,
        // otherwise the two drift apart and clicking a split stops working.
        if let surface = activeSurface, window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        activeSurface?.setFocus(false)
    }
}

/// ⌥1–⌥9, jumping straight to a tab in the current workspace.
///
/// This can't be an NSMenuItem key equivalent, and it can't live in
/// `performKeyEquivalent` either: AppKit only runs key-equivalent processing
/// for Command-modified events, so an Option chord goes straight down the
/// responder chain to the terminal and libghostty types `¡` instead. A local
/// event monitor sees it first. Matching is by key code, which is positional
/// and so means the same thing on every keyboard layout.
enum DigitShortcut {
    static func index(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
        else { return nil }
        return digitKeyCodes[event.keyCode]
    }

    /// `kVK_ANSI_1` … `kVK_ANSI_9`. 5/6 and 7/8/9 aren't in numeric order —
    /// that's the hardware layout, not a typo.
    private static let digitKeyCodes: [UInt16: Int] = [
        0x12: 0, 0x13: 1, 0x14: 2, 0x15: 3, 0x17: 4,
        0x16: 5, 0x1A: 6, 0x1C: 7, 0x19: 8,
    ]
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

