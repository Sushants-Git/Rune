import Cocoa
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate {
    private var ghostty: GhosttyApp?
    private var controllers: [TerminalController] = []

    private var keyController: TerminalController? {
        if let window = NSApp.keyWindow as? TerminalWindow, let c = window.controller { return c }
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
        let controller = newWindow()
        NSApp.activate(ignoringOtherApps: true)

        // Development aid: KTERM_DEMO=<n> opens n extra tabs and drops straight
        // into the switcher, so the tab UI can be exercised without driving the
        // app through synthetic keystrokes.
        if let demo = ProcessInfo.processInfo.environment["KTERM_DEMO"],
           let extra = Int(demo), extra > 0, let controller {
            for dir in ["/tmp", "/usr/local", NSHomeDirectory()].prefix(extra) {
                controller.newTab(workingDirectory: dir)
            }
            controller.showTabPalette()
            // Float the window so it stays capturable while being inspected.
            controller.window?.level = .floating
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ghostty?.shutdown()
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
        alert.messageText = "Quit kterm?"
        alert.informativeText = "A process is still running in one of your terminals."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "kterm couldn't start"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Windows and tabs

    @discardableResult
    func newWindow(workingDirectory: String? = nil) -> TerminalController? {
        guard let ghostty else { return nil }
        let controller = TerminalController(ghostty: ghostty)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.newTab(workingDirectory: workingDirectory)
        return controller
    }

    func controllerWillClose(_ controller: TerminalController) {
        controllers.removeAll { $0 === controller }
    }

    private func controller(owning surface: ghostty_surface_t?) -> TerminalController? {
        guard let view = ghostty?.view(for: surface) else { return keyController }
        return controllers.first { $0.tabs.contains(where: { $0 === view }) } ?? keyController
    }

    // MARK: - GhosttyAppDelegate

    func ghosttyNewTab(from surface: ghostty_surface_t?) {
        controller(owning: surface)?.newTab()
    }

    func ghosttyNewWindow(from surface: ghostty_surface_t?) {
        newWindow(workingDirectory: ghostty?.view(for: surface)?.pwd)
    }

    func ghosttyCloseSurface(_ view: GhosttySurfaceView, processAlive: Bool) {
        guard let controller = controllers.first(where: { c in
            c.tabs.contains(where: { $0 === view })
        }) else { return }
        controller.closeTab(view)
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
        controller(owning: surface)?.toggleTabPalette()
    }

    // MARK: - Menu actions

    @objc private func newWindowAction(_ sender: Any?) { newWindow() }
    @objc private func newTabAction(_ sender: Any?) { keyController?.newTab() }
    @objc private func closeTabAction(_ sender: Any?) { keyController?.closeActiveTab() }
    @objc private func switchTabAction(_ sender: Any?) { keyController?.toggleTabPalette() }
    @objc private func nextTabAction(_ sender: Any?) { keyController?.selectRelativeTab(offset: 1) }
    @objc private func prevTabAction(_ sender: Any?) { keyController?.selectRelativeTab(offset: -1) }
    @objc private func copyAction(_ sender: Any?) { keyController?.performSurfaceAction("copy_to_clipboard") }
    @objc private func pasteAction(_ sender: Any?) { keyController?.performSurfaceAction("paste_from_clipboard") }
    @objc private func selectAllAction(_ sender: Any?) { keyController?.performSurfaceAction("select_all") }
    @objc private func increaseFontAction(_ sender: Any?) { keyController?.performSurfaceAction("increase_font_size:1") }
    @objc private func decreaseFontAction(_ sender: Any?) { keyController?.performSurfaceAction("decrease_font_size:1") }
    @objc private func resetFontAction(_ sender: Any?) { keyController?.performSurfaceAction("reset_font_size") }

    @objc private func selectTabByIndex(_ sender: NSMenuItem) {
        keyController?.selectTab(at: sender.tag)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About kterm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide kterm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit kterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Shell menu — tab lifecycle lives here.
        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        add(to: shellMenu, "New Window", #selector(newWindowAction(_:)), "n")
        add(to: shellMenu, "New Tab", #selector(newTabAction(_:)), "t")
        add(to: shellMenu, "Close Tab", #selector(closeTabAction(_:)), "w")
        shellItem.submenu = shellMenu
        mainMenu.addItem(shellItem)

        // Edit menu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(to: editMenu, "Copy", #selector(copyAction(_:)), "c")
        add(to: editMenu, "Paste", #selector(pasteAction(_:)), "v")
        add(to: editMenu, "Select All", #selector(selectAllAction(_:)), "a")
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

        // Tabs menu — this is the heart of kterm's navigation.
        let tabsItem = NSMenuItem()
        let tabsMenu = NSMenu(title: "Tabs")
        add(to: tabsMenu, "Switch to Tab…", #selector(switchTabAction(_:)), "k")
        tabsMenu.addItem(.separator())
        let next = add(to: tabsMenu, "Next Tab", #selector(nextTabAction(_:)), "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let prev = add(to: tabsMenu, "Previous Tab", #selector(prevTabAction(_:)), "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        tabsMenu.addItem(.separator())
        for i in 1...9 {
            let item = add(to: tabsMenu, "Tab \(i)", #selector(selectTabByIndex(_:)), "\(i)")
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
}
