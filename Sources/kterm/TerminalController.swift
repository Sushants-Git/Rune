import Cocoa
import GhosttyKit

/// A window holding any number of terminal surfaces, exactly one of which is
/// visible at a time.
///
/// There is deliberately no tab bar: tabs are reached through the Cmd-K
/// switcher instead of by clicking. Everything here is built around that —
/// tabs are ordered most-recently-used so Cmd-K, Enter toggles between the two
/// terminals you're actually working in.
@MainActor
final class TerminalController: NSWindowController, NSWindowDelegate {
    private let ghostty: GhosttyApp

    /// Tabs in creation order. This is the stable order shown in the switcher.
    private(set) var tabs: [GhosttySurfaceView] = []
    /// Tab IDs in most-recently-used order, newest first.
    private var mruOrder: [UUID] = []

    private(set) var activeTab: GhosttySurfaceView?

    private let container = NSView()
    private var palette: TabPalette?

    init(ghostty: GhosttyApp) {
        self.ghostty = ghostty

        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "kterm"
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

    // MARK: - Tabs

    @discardableResult
    func newTab(workingDirectory: String? = nil) -> GhosttySurfaceView? {
        // Inherit the cwd of the tab you were in, which is what you almost
        // always want when opening a sibling terminal.
        let cwd = workingDirectory ?? activeTab?.pwd

        let view: GhosttySurfaceView
        do {
            view = try GhosttySurfaceView(app: ghostty, workingDirectory: cwd)
        } catch {
            log.error("failed to create surface: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(
                "kterm: failed to create surface for \(cwd ?? "~"): \(error)\n".data(using: .utf8)!)
            return nil
        }

        view.onMetadataChange = { [weak self, weak view] in
            guard let self, let view else { return }
            if view === self.activeTab { self.syncWindowTitle() }
            self.palette?.reload()
        }

        tabs.append(view)
        select(view)
        return view
    }

    func closeTab(_ view: GhosttySurfaceView) {
        guard let index = tabs.firstIndex(where: { $0 === view }) else { return }

        tabs.remove(at: index)
        mruOrder.removeAll { $0 == view.id }
        palette?.reload()
        if view === activeTab {
            activeTab = nil
            view.removeFromSuperview()
        }
        view.close()

        // Fall back to the most recently used surviving tab.
        if let next = mruOrder.first.flatMap({ id in tabs.first { $0.id == id } }) ?? tabs.last {
            select(next)
        } else {
            window?.close()
        }
    }

    func closeActiveTab() {
        guard let activeTab else { return }
        closeTab(activeTab)
    }

    func select(_ view: GhosttySurfaceView) {
        guard view !== activeTab else { return }

        if let activeTab {
            // Hidden surfaces keep running, they just stop rendering. Note the
            // argument is "visible", not "occluded".
            activeTab.removeFromSuperview()
            if let surface = activeTab.surface {
                ghostty_surface_set_occlusion(surface, false)
            }
        }

        // Add first, then size: the surface needs to be in a window before it
        // can resolve the backing scale factor for its framebuffer.
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .below, relativeTo: palette)
        view.frame = terminalFrame
        if let surface = view.surface {
            ghostty_surface_set_occlusion(surface, true)
        }

        activeTab = view
        window?.makeFirstResponder(view)

        mruOrder.removeAll { $0 == view.id }
        mruOrder.insert(view.id, at: 0)

        syncWindowTitle()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectRelativeTab(offset: Int) {
        guard let activeTab, let current = tabs.firstIndex(where: { $0 === activeTab }),
              !tabs.isEmpty else { return }
        let next = (current + offset % tabs.count + tabs.count) % tabs.count
        select(tabs[next])
    }

    /// Tabs ordered for the switcher: most recently used first, but with the
    /// *current* tab demoted so Enter goes straight to the previous one.
    var switcherOrder: [GhosttySurfaceView] {
        var ordered = mruOrder.compactMap { id in tabs.first { $0.id == id } }
        for tab in tabs where !ordered.contains(where: { $0 === tab }) {
            ordered.append(tab)
        }
        if ordered.count > 1, let first = ordered.first, first === activeTab {
            ordered.removeFirst()
            ordered.append(first)
        }
        return ordered
    }

    private func syncWindowTitle() {
        guard let activeTab else { return }
        let count = tabs.count
        window?.title = count > 1
            ? "\(activeTab.displayTitle) — \(count) tabs"
            : activeTab.displayTitle
    }

    // MARK: - Switcher

    func toggleTabPalette() {
        if palette != nil {
            dismissTabPalette()
        } else {
            showTabPalette()
        }
    }

    func showTabPalette() {
        guard palette == nil, !tabs.isEmpty else { return }

        // The order is captured once, so the list doesn't reshuffle under the
        // cursor, but membership is re-read on every filter so a tab that
        // closes meanwhile drops out.
        let order = switcherOrder
        let palette = TabPalette(
            tabs: { [weak self] in
                guard let self else { return [] }
                return order.filter { tab in self.tabs.contains(where: { $0 === tab }) }
            },
            onComplete: { [weak self] selected in
                self?.dismissTabPalette()
                if let selected { self?.select(selected) }
            })
        palette.frame = container.bounds
        palette.autoresizingMask = [.width, .height]
        container.addSubview(palette, positioned: .above, relativeTo: nil)
        self.palette = palette
        window?.makeFirstResponder(palette.searchField)
    }

    func dismissTabPalette() {
        guard let palette else { return }
        palette.removeFromSuperview()
        self.palette = nil
        if let activeTab { window?.makeFirstResponder(activeTab) }
    }

    var isTabPaletteVisible: Bool { palette != nil }

    // MARK: - Forwarding to the active surface

    /// Trigger a libghostty keybinding action (e.g. "copy_to_clipboard") on the
    /// active surface. See Ghostty's docs for the action grammar.
    func performSurfaceAction(_ action: String) {
        guard let surface = activeTab?.surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for tab in tabs { tab.close() }
        tabs.removeAll()
        mruOrder.removeAll()
        activeTab = nil
        (NSApp.delegate as? AppDelegate)?.controllerWillClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.setFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        activeTab?.setFocus(false)
    }
}

/// NSWindow subclass that gives the controller first crack at key equivalents
/// that the menu doesn't claim, and that can become key without a title bar.
final class TerminalWindow: NSWindow {
    weak var controller: TerminalController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Escape closes the switcher before anything else sees it.
        if event.keyCode == 53, controller?.isTabPaletteVisible == true {
            controller?.dismissTabPalette()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
