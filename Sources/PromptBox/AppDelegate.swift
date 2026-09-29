import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PromptWindow!
    private var receivedURL = false

    /// Set up here, not in didFinishLaunching: a launch through promptbox:// delivers the URL
    /// before didFinishLaunching runs.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["PROMPTBOX_SELFTEST"] {
            SelfTest.run(into: URL(fileURLWithPath: dir))
            return
        }
        NSApp.mainMenu = buildMenu()
        window = PromptWindow()
        window.onHide = { [weak self] event in self?.notifyHammerspoon(event) }
        installTabKeys()
    }

    /// ⌃Tab and ⌃⇧Tab switch tabs. They're caught before the text view sees them, since a text
    /// view treats Tab as typing and never offers it to the menu.
    private func installTabKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window.panel, event.keyCode == 48,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .control else {
                return event
            }
            self.window.selectTab(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window != nil else { return }
        // Opened from Finder or `open` rather than a promptbox:// URL: show the window anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.receivedURL else { return }
                self.window.show(near: nil)
            }
        }
    }

    /// `promptbox://show`, `promptbox://hide` and `promptbox://toggle`. Show takes the centre of the
    /// focused window as `?x=&y=` in Hammerspoon coordinates (origin at the top left of the
    /// primary screen) and opens on that window's screen.
    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        for url in urls {
            switch url.host {
            case "show": window.show(near: anchor(from: url))
            case "hide": window.hide()
            case "toggle":
                if window.panel.isVisible && NSApp.isActive { window.hide() } else { window.show(near: anchor(from: url)) }
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show(near: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        window.saveNow()
    }

    private func anchor(from url: URL) -> NSPoint? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Double? { items.first { $0.name == name }?.value.flatMap(Double.init) }
        guard let x = value("x"), let y = value("y"), let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: x, y: primary.frame.maxY - y)
    }

    /// Tells Hammerspoon the window closed (refocus the previous window) or that a prompt is on
    /// the clipboard (refocus and paste). Without Hammerspoon this does nothing and the prompt
    /// stays on the clipboard.
    private func notifyHammerspoon(_ event: String) {
        guard let url = URL(string: "hammerspoon://\(event)"),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    // MARK: - Menu

    /// The menu bar stays hidden (LSUIElement), but its key equivalents still drive ⌘Z, ⌘C and
    /// the rest.
    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "PromptBox")
        app.addItem(withTitle: "Hide PromptBox", action: #selector(hideWindow), keyEquivalent: "h").target = self
        app.addItem(withTitle: "Quit PromptBox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Delete Line", action: #selector(EditorTextView.deleteLines(_:)), keyEquivalent: "K")
        edit.addItem(.separator())
        for (title, key, tag) in [("Find…", "f", NSTextFinder.Action.showFindInterface),
                                  ("Find and Replace…", "f", .showReplaceInterface),
                                  ("Find Next", "g", .nextMatch),
                                  ("Find Previous", "G", .previousMatch),
                                  ("Use Selection for Find", "e", .setSearchString)] {
            let item = edit.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = tag.rawValue
            if tag == .showReplaceInterface { item.keyEquivalentModifierMask = [.command, .option] }
        }

        let prompt = submenu(in: main, title: "Prompt")
        let send = prompt.addItem(withTitle: "Send to Previous Window", action: #selector(sendPrompt), keyEquivalent: "\r")
        send.target = self
        let copy = prompt.addItem(withTitle: "Copy and Hide", action: #selector(copyPrompt), keyEquivalent: "\r")
        copy.keyEquivalentModifierMask = [.command, .shift]
        copy.target = self
        prompt.addItem(.separator())
        prompt.addItem(withTitle: "Deleted Text", action: #selector(showDeleted), keyEquivalent: "d").target = self
        prompt.addItem(withTitle: "History", action: #selector(showHistory), keyEquivalent: "y").target = self

        let tabs = submenu(in: main, title: "Tab")
        tabs.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
        tabs.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "n").target = self
        tabs.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w").target = self
        tabs.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenTab), keyEquivalent: "T").target = self
        tabs.addItem(.separator())
        tabs.addItem(withTitle: "Find Tab…", action: #selector(findTab), keyEquivalent: "k").target = self
        let next = tabs.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        let previous = tabs.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        previous.target = self
        for number in 1...9 {
            let item = tabs.addItem(withTitle: number == 9 ? "Last Tab" : "Tab \(number)", action: #selector(selectNumberedTab(_:)),
                                    keyEquivalent: "\(number)")
            item.tag = number
            item.target = self
        }

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(biggerFont), keyEquivalent: "=").target = self
        view.addItem(withTitle: "Smaller", action: #selector(smallerFont), keyEquivalent: "-").target = self
        view.addItem(withTitle: "Default Size", action: #selector(defaultFont), keyEquivalent: "0").target = self
        return main
    }

    private func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }

    @objc private func hideWindow() { window.hide() }
    @objc private func sendPrompt() { window.send(paste: true) }
    @objc private func copyPrompt() { window.send(paste: false) }
    @objc private func newTab() { window.newTab() }
    @objc private func closeTab() { window.closeCurrentTab() }
    @objc private func reopenTab() { window.reopenClosedTab() }
    @objc private func findTab() { window.toggleSwitcher() }
    @objc private func nextTab() { window.selectTab(offset: 1) }
    @objc private func previousTab() { window.selectTab(offset: -1) }
    @objc private func selectNumberedTab(_ sender: NSMenuItem) { window.selectTab(number: sender.tag) }
    @objc private func showDeleted() { window.toggleSidebar(.deleted) }
    @objc private func showHistory() { window.toggleSidebar(.history) }
    @objc private func biggerFont() { window.changeFontSize(by: 1) }
    @objc private func smallerFont() { window.changeFontSize(by: -1) }
    @objc private func defaultFont() { window.changeFontSize(by: nil) }
}
