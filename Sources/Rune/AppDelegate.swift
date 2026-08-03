import Cocoa
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate {
    private var ghostty: GhosttyApp?
    private var controllers: [TerminalController] = []
    private var tabKeyMonitor: Any?

    private var keyController: TerminalController? {
        if let window = NSApp.keyWindow as? TerminalWindow, let c = window.controller { return c }
        if let window = NSApp.mainWindow as? TerminalWindow, let c = window.controller { return c }
        return controllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let ghostty = try GhosttyApp()
            ghostty.delegate = self
            self.ghostty = ghostty
        } catch {
            presentFatal(error)
            return
        }

        buildMenu()
        installTabShortcuts()
        installCommandLineListener()
        // `rune <path>` on a cold launch says where the first window belongs.
        let controller = newWindow(workingDirectory: CLI.startupDirectory)
        NSApp.activate(ignoringOtherApps: true)

        // Deliberately after the window is up. The check is a network round
        // trip that has nothing to do with Rune being ready to type into, and
        // it stays quiet unless it finds something. `start` also schedules the
        // repeat, without which a window left open for a week never looks again.
        Updater.shared.start()

        if PromoFilm.enabled, let controller {
            PromoFilm.run(controller: controller)
            return
        }

        if PromoShot.enabled {
            PromoShot.run()
            return
        }

        if ZoomScrollTest.enabled, let controller {
            ZoomScrollTest.run(controller: controller)
            return
        }

        if UpdateTest.enabled {
            UpdateTest.run()
            return
        }

        // Development aid: RUNE_DEMO=<n> floats the window so it stays
        // capturable while being inspected, and opens n extra workspaces (some
        // with a second tab) before dropping into the switcher — so the UI can
        // be exercised without driving the app through synthetic keystrokes.
        // RUNE_DEMO=0 just floats a plain window.
        if let demo = ProcessInfo.processInfo.environment["RUNE_DEMO"],
           let extra = Int(demo), let controller {
            controller.window?.level = .floating
            guard extra > 0 else { return }
            for (i, dir) in ["/tmp", "/usr/local", "/etc", "/var/log"].prefix(extra).enumerated() {
                controller.newWorkspace(workingDirectory: dir)
                // Give some of them a second tab so both the strip and the
                // single-tab title are represented.
                if i.isMultiple(of: 2) { controller.newTab(workingDirectory: "/usr") }
            }
            controller.showSwitcher()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let tabKeyMonitor {
            NSEvent.removeMonitor(tabKeyMonitor)
            self.tabKeyMonitor = nil
        }
        ghostty?.shutdown()
    }

    /// The shortcuts that have to be caught before anything else sees them.
    ///
    /// ⌥1–⌥9 would otherwise reach the terminal and be forwarded to libghostty
    /// as ordinary input — see `DigitShortcut` for why neither the menu nor
    /// `performKeyEquivalent` can do this.
    ///
    /// ⌘C is the Edit menu's Copy, and a menu key equivalent is matched before
    /// the responder chain ever runs, so a handler on the window or the palette
    /// would never see it. Intercepting here is also what keeps the override
    /// honest: it applies only while the ⌘K switcher is up and not renaming, so
    /// copying out of a terminal — the thing a terminal must never lose — is
    /// untouched everywhere else. ⌘P rides along for the same reason: a
    /// terminal may want it, and the switcher's claim on it is temporary.
    private func installTabShortcuts() {
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self, NSApp.keyWindow is TerminalWindow,
                  let controller = self.keyController
            else { return event }

            if let index = DigitShortcut.index(for: event, modifiers: [.option]) {
                controller.selectTab(at: index)
                return nil
            }

            // ⌘C and ⌘P only mean anything with the switcher up and no rename
            // in progress; everywhere else they stay Copy and whatever the
            // terminal wants them to be.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               controller.isSwitcherVisible, !controller.isRenaming {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    controller.closeSwitcherSelection()
                    return nil
                case "p":
                    controller.togglePinOnSwitcherSelection()
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    /// `rune <path>` run against an already-running Rune arrives here.
    ///
    /// A new *workspace* rather than a new window: everything Rune does lives in
    /// one window on purpose, and a command run in a terminal is asking for a
    /// place to work, not for another window to arrange.
    private func installCommandLineListener() {
        DistributedNotificationCenter.default().addObserver(
            forName: CLI.openNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Read the path out here: a Notification isn't Sendable, so it must
            // not cross into the isolated closure, but a String happily does.
            let path = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let path else { return }
                if let controller = self.keyController {
                    controller.newWorkspace(workingDirectory: path)
                } else {
                    self.newWindow(workingDirectory: path)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ghostty?.setFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        ghostty?.setFocus(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ghostty?.needsConfirmQuit == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Rune?"
        alert.informativeText = "A process is still running in one of your terminals."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Rune couldn't start"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Windows and tabs

    @discardableResult
    func newWindow(workingDirectory: String? = nil) -> TerminalController? {
        guard let ghostty else { return nil }
        // The window you're leaving shouldn't be left with ⌘K still up behind
        // the new one.
        keyController?.hideSwitcher()
        let controller = TerminalController(ghostty: ghostty)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.newWorkspace(workingDirectory: workingDirectory)
        return controller
    }

    func controllerWillClose(_ controller: TerminalController) {
        controllers.removeAll { $0 === controller }
    }

    private func controller(owning surface: ghostty_surface_t?) -> TerminalController? {
        guard let view = ghostty?.view(for: surface) else { return keyController }
        return controllers.first { $0.owns(view) } ?? keyController
    }

    // MARK: - GhosttyAppDelegate

    func ghosttyNewTab(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.newTab()
    }

    /// libghostty's `new_window` binding means ⌘N here, which in Rune makes a
    /// workspace rather than a macOS window. ⌘⇧K is the one that makes a window.
    func ghosttyNewWindow(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.newWorkspace()
    }

    func ghosttyCloseSurface(_ view: GhosttySurfaceView, processAlive: Bool) {
        controllers.first { $0.owns(view) }?.closeSurface(view)
    }

    func ghosttyQuit() {
        NSApp.terminate(nil)
    }

    func ghosttyGotoTab(_ target: ghostty_action_goto_tab_e, from surface: ghostty_surface_t?) {
        guard let controller = controller(owning: surface) else { return }
        switch target {
        case GHOSTTY_GOTO_TAB_PREVIOUS: controller.selectRelativeTab(offset: -1)
        case GHOSTTY_GOTO_TAB_NEXT: controller.selectRelativeTab(offset: 1)
        case GHOSTTY_GOTO_TAB_LAST: controller.selectTab(at: controller.tabs.count - 1)
        default:
            // The remaining values are 1-based tab indices.
            let index = Int(target.rawValue)
            if index > 0 { controller.selectTab(at: index - 1) }
        }
    }

    func ghosttyToggleCommandPalette(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.toggleSwitcher()
    }

    /// The order `focusSplitAction`'s menu tags are in.
    fileprivate static let splitDirections: [SplitDirection] = [.left, .right, .up, .down]

    func ghosttyNewSplit(
        _ direction: ghostty_action_split_direction_e,
        from surface: ghostty_surface_t?
    ) {
        let split: SplitDirection = switch direction {
        case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
        case GHOSTTY_SPLIT_DIRECTION_UP: .up
        default: .right
        }
        controller(owning: surface)?.splitActiveSurface(split)
    }

    func ghosttyGotoSplit(
        _ target: ghostty_action_goto_split_e,
        from surface: ghostty_surface_t?
    ) {
        guard let controller = controller(owning: surface) else { return }
        switch target {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: controller.focusRelativeSplit(offset: -1)
        case GHOSTTY_GOTO_SPLIT_NEXT: controller.focusRelativeSplit(offset: 1)
        case GHOSTTY_GOTO_SPLIT_LEFT: controller.focusSplit(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: controller.focusSplit(.right)
        case GHOSTTY_GOTO_SPLIT_UP: controller.focusSplit(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: controller.focusSplit(.down)
        default: break
        }
    }

    func ghosttyResizeSplit(
        _ direction: ghostty_action_resize_split_direction_e,
        amount: UInt16,
        from surface: ghostty_surface_t?
    ) {
        let split: SplitDirection = switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: .left
        default: .right
        }
        controller(owning: surface)?.resizeSplit(split, amount: CGFloat(amount))
    }

    func ghosttyToggleSplitZoom(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.toggleSplitZoom()
    }

    func ghosttyEqualizeSplits(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.equalizeSplits()
    }

    // MARK: - Menu actions

    /// A new window inherits the cwd of the terminal you were in, same as a new
    /// tab or workspace does.
    @objc private func newWindowAction(_ sender: Any?) {
        newWindow(workingDirectory: keyController?.activeSurface?.pwd)
    }

    @objc private func newTabAction(_ sender: Any?) { keyController?.newTab() }
    @objc private func newWorkspaceAction(_ sender: Any?) { keyController?.newWorkspace() }
    @objc private func closeTabAction(_ sender: Any?) { keyController?.closeActiveSurface() }
    @objc private func splitRightAction(_ sender: Any?) { keyController?.splitActiveSurface(.right) }
    @objc private func splitDownAction(_ sender: Any?) { keyController?.splitActiveSurface(.down) }
    @objc private func equalizeSplitsAction(_ sender: Any?) { keyController?.equalizeSplits() }
    @objc private func toggleSplitZoomAction(_ sender: Any?) { keyController?.toggleSplitZoom() }

    @objc private func focusSplitAction(_ sender: NSMenuItem) {
        guard let direction = Self.splitDirections[safe: sender.tag] else { return }
        keyController?.focusSplit(direction)
    }
    @objc private func closeWindowAction(_ sender: Any?) { keyController?.closeWindow() }
    @objc private func switchWorkspaceAction(_ sender: Any?) { keyController?.toggleSwitcher() }
    @objc private func renameWorkspaceAction(_ sender: Any?) { keyController?.renameWorkspace() }
    @objc private func nextTabAction(_ sender: Any?) { keyController?.selectRelativeTab(offset: 1) }
    @objc private func prevTabAction(_ sender: Any?) { keyController?.selectRelativeTab(offset: -1) }
    @objc private func increaseFontAction(_ sender: Any?) { keyController?.performSurfaceAction("increase_font_size:1") }
    @objc private func decreaseFontAction(_ sender: Any?) { keyController?.performSurfaceAction("decrease_font_size:1") }
    @objc private func resetFontAction(_ sender: Any?) { keyController?.performSurfaceAction("reset_font_size") }

    @objc private func checkForUpdatesAction(_ sender: Any?) { Updater.shared.checkNow() }

    @objc private func selectWorkspaceByIndex(_ sender: NSMenuItem) {
        keyController?.selectWorkspace(at: sender.tag)
    }

    @objc private func selectTabByIndex(_ sender: NSMenuItem) {
        keyController?.selectTab(at: sender.tag)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Rune", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(to: appMenu, "Check for Updates…", #selector(checkForUpdatesAction(_:)), "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Rune", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Rune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Shell menu — the two axes Rune navigates: tabs within a workspace,
        // and workspaces within a window.
        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        add(to: shellMenu, "New Tab", #selector(newTabAction(_:)), "t")
        add(to: shellMenu, "New Workspace", #selector(newWorkspaceAction(_:)), "n")
        shellMenu.addItem(.separator())
        // Everything stays in one window until you explicitly ask for another.
        add(to: shellMenu, "New Window", #selector(newWindowAction(_:)), "N")
            .keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(.separator())
        add(to: shellMenu, "Close Terminal", #selector(closeTabAction(_:)), "w")
        add(to: shellMenu, "Close Window", #selector(closeWindowAction(_:)), "W")
            .keyEquivalentModifierMask = [.command, .shift]
        shellItem.submenu = shellMenu
        mainMenu.addItem(shellItem)

        // Edit menu
        let editItem = NSMenuItem()
        // These go to the first responder, not to a fixed target: with the ⌘K
        // switcher open its search field should get them, not the terminal
        // behind it. GhosttySurfaceView implements the same selectors.
        let editMenu = NSMenu(title: "Edit")
        addResponderItem(to: editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        addResponderItem(to: editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        addResponderItem(to: editMenu, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(to: viewMenu, "Increase Font Size", #selector(increaseFontAction(_:)), "+")
        add(to: viewMenu, "Decrease Font Size", #selector(decreaseFontAction(_:)), "-")
        add(to: viewMenu, "Reset Font Size", #selector(resetFontAction(_:)), "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Splits menu — dividing a tab, and moving between the pieces.
        let splitItem = NSMenuItem()
        let splitMenu = NSMenu(title: "Splits")
        add(to: splitMenu, "Split Right", #selector(splitRightAction(_:)), "d")
        add(to: splitMenu, "Split Down", #selector(splitDownAction(_:)), "D")
            .keyEquivalentModifierMask = [.command, .shift]
        splitMenu.addItem(.separator())
        // ⌘⌥arrow rather than ⌘arrow: the terminal needs the plain arrows, and
        // ⌘arrow is line-start/end in a shell's editing mode.
        for (i, spec) in [
            ("Focus Split Left", "\u{2190}"),
            ("Focus Split Right", "\u{2192}"),
            ("Focus Split Up", "\u{2191}"),
            ("Focus Split Down", "\u{2193}"),
        ].enumerated() {
            let item = add(to: splitMenu, spec.0, #selector(focusSplitAction(_:)), spec.1)
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = i
        }
        splitMenu.addItem(.separator())
        // ⌘⇧↵, the same chord Ghostty uses for it.
        add(to: splitMenu, "Zoom Split", #selector(toggleSplitZoomAction(_:)), "\r")
            .keyEquivalentModifierMask = [.command, .shift]
        add(to: splitMenu, "Equalize Splits", #selector(equalizeSplitsAction(_:)), "=")
            .keyEquivalentModifierMask = [.command, .option]
        splitItem.submenu = splitMenu
        mainMenu.addItem(splitItem)

        // Workspaces menu — ⌘K moves between workspaces; the strip in the title
        // bar moves between the tabs of the one you're in.
        let tabsItem = NSMenuItem()
        let tabsMenu = NSMenu(title: "Workspaces")
        add(to: tabsMenu, "Switch to Workspace…", #selector(switchWorkspaceAction(_:)), "k")
        add(to: tabsMenu, "Rename Workspace…", #selector(renameWorkspaceAction(_:)), "r")
        tabsMenu.addItem(.separator())
        let next = add(to: tabsMenu, "Next Tab", #selector(nextTabAction(_:)), "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let prev = add(to: tabsMenu, "Previous Tab", #selector(prevTabAction(_:)), "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        tabsMenu.addItem(.separator())
        // ⌘1–⌘9 address the ⌘K list…
        for i in 1...9 {
            let item = add(
                to: tabsMenu, "Workspace \(i)", #selector(selectWorkspaceByIndex(_:)), "\(i)")
            item.tag = i - 1
        }
        tabsMenu.addItem(.separator())
        // …and ⌥1–⌥9 the tabs in the one you're in. The key equivalent here is
        // for *display* only; `installTabShortcuts` does the matching.
        for i in 1...9 {
            let item = add(to: tabsMenu, "Tab \(i)", #selector(selectTabByIndex(_:)), "\(i)")
            item.keyEquivalentModifierMask = [.option]
            item.tag = i - 1
        }
        tabsItem.submenu = tabsMenu
        mainMenu.addItem(tabsItem)

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    /// Add an item with no explicit target, so AppKit dispatches it down the
    /// responder chain to whatever currently has focus.
    @discardableResult
    private func addResponderItem(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        menu.addItem(item)
        return item
    }
}
