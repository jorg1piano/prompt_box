import AppKit
import PromptBoxCore

/// The floating editor window: tabs on top, the editor with its sidebar of deleted text and sent
/// prompts, the image strip, and a status line. The pinned transcript tab swaps the editor for
/// the transcript panel.
@MainActor
final class PromptWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    enum SidebarMode: Int { case deleted, history }

    let panel: NSPanel
    let textView = EditorTextView(usingTextLayoutManager: false)
    let strip = ImageStrip()
    let tabBar = TabBar()
    let switcher = TabSwitcher()
    private let scrollView = NSScrollView()
    private let sidebar: Sidebar
    private let status = NSTextField(labelWithString: "")
    let transcript: TranscriptPanel
    /// Nil for the self-test, which never opens the microphone.
    let listener: Listener?

    let history: EntryStore
    let deleted: EntryStore
    private let tabFiles: TabFiles
    /// False for the self-test: nothing is read from or written to disk.
    private let persist: Bool

    private(set) var tabs: [Tab] = []
    /// The prompt tab in the editor, or the one to go back to while the transcript shows.
    private(set) var current: Tab!
    private(set) var showingTranscript = false
    /// Prompts from tabs closed this session, for ⌘⇧T.
    private var closedTabs: [Prompt] = []

    private var coalescer = DeletionCoalescer()
    private var openDeletionID: String?
    private var suppressDeletionLog = false
    private var saveWork: DispatchWorkItem?
    private var shownTitles: [String] = []

    /// Called with the Hammerspoon event to send after the window hides.
    var onHide: ((String) -> Void)?

    private static let fontSizeKey = "fontSize"
    private static let transcriptKey = "showingTranscript"
    private static let widthKey = "widthFraction"
    private static let heightKey = "heightFraction"
    /// The window never opens smaller than a third of the screen's width and half its height.
    private static let minWidthFraction: CGFloat = 1.0 / 3.0
    private static let minHeightFraction: CGFloat = 0.5

    private var fontSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: Self.fontSizeKey) as? Double ?? 14) }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.fontSizeKey) }
    }

    /// Font, colour and line spacing for every character in every tab.
    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    var prompt: Prompt { current.prompt }

    init(persist: Bool = true) {
        self.persist = persist
        let root = persist ? Paths.support : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        history = EntryStore(directory: root.appendingPathComponent("history"), limit: 500)
        deleted = EntryStore(directory: root.appendingPathComponent("deleted"), limit: 1000)
        tabFiles = TabFiles(directory: root.appendingPathComponent("tabs"))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        sidebar = Sidebar(history: history, deleted: deleted)
        let transcripts = root.appendingPathComponent("transcripts")
        let log = TranscriptLog(directory: transcripts)
        listener = persist ? Listener(log: log) : nil
        transcript = TranscriptPanel(log: log, store: CandidateStore(url: transcripts.appendingPathComponent("prompts.json")),
                                     listener: listener)
        super.init()

        panel.title = "PromptBox"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.delegate = self

        setUpTextView()
        setUpLayout()
        textView.onImages = { [weak self] pngs in
            guard let self else { return }
            self.insertImages(pngs, at: self.strip.images.count)
        }
        strip.onRemove = { [weak self] index in self?.removeImageByUser(at: index) }
        sidebar.onActivate = { [weak self] mode, id in self?.activate(mode: mode, id: id) }
        sidebar.onCancel = { [weak self] in self?.focusEditor() }
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onClose = { [weak self] i in
            guard let self, i < self.tabs.count else { return }
            self.close(self.tabs[i])
        }
        tabBar.onNew = { [weak self] in self?.newTab() }
        tabBar.onSelectTranscript = { [weak self] in self?.showTranscript() }
        transcript.onOpen = { [weak self] text in self?.newTab(with: Prompt(text: text)) }
        transcript.onCancel = { [weak self] in self?.hide() }
        transcript.onListenerChange = { [weak self] in
            guard let self else { return }
            if case .listening = self.listener?.state { self.tabBar.listening = true } else { self.tabBar.listening = false }
        }
        switcher.candidates = { [weak self] in self?.switcherCandidates() ?? [] }
        switcher.onChoose = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.select(tab)
        }
        switcher.onDismiss = { [weak self] in self?.focusEditor() }
        loadTabs()
    }

    // MARK: - Setup

    private func setUpTextView() {
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = self
        scrollView.documentView = textView
        textView.updateDragTypeRegistration()
    }

    /// Tabs on top, editor and sidebar side by side, the image strip under them, then the status
    /// line. The ⌘K switcher lies over all of it.
    private func setUpLayout() {
        let row = NSStackView(views: [scrollView, transcript.view, sidebar.view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .height
        row.detachesHiddenViews = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcript.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcript.view.isHidden = true
        sidebar.view.isHidden = true
        let sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: 300)
        sidebarWidth.priority = .defaultHigh

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [tabBar, row, strip])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.detachesHiddenViews = true
        row.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        for view in [column, status, switcher.view] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarWidth,
            sidebar.view.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.5),
            tabBar.heightAnchor.constraint(equalToConstant: TabBar.height),
            tabBar.widthAnchor.constraint(equalTo: column.widthAnchor),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            strip.widthAnchor.constraint(equalTo: column.widthAnchor),
            // Start below the transparent title bar so nothing sits under the traffic lights.
            column.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            switcher.view.topAnchor.constraint(equalTo: content.topAnchor),
            switcher.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            switcher.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            switcher.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
    }

    private func applyFont() {
        let attributes = textAttributes
        textView.font = attributes[.font] as? NSFont
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        for tab in tabs where tab.storage.length > 0 {
            tab.storage.addAttributes(attributes, range: NSRange(location: 0, length: tab.storage.length))
        }
    }

    // MARK: - Showing and hiding

    /// `anchor` is a point, in AppKit screen coordinates, on the screen the window should open on.
    func show(near anchor: NSPoint?) {
        if !panel.isVisible { position(near: anchor ?? NSEvent.mouseLocation) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if panel.firstResponder !== sidebar.table, !switcher.isOpen { focusEditor() }
        if showingTranscript { transcript.appeared() }
    }

    func hide(event: String = "promptbox-closed") {
        guard panel.isVisible else { return }
        switcher.dismiss()
        saveNow()
        panel.orderOut(nil)
        NSApp.hide(nil)
        onHide?(event)
    }

    private func position(near point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let defaults = UserDefaults.standard
        let widthFraction = min(1, max(Self.minWidthFraction, defaults.object(forKey: Self.widthKey) as? Double ?? 0))
        let heightFraction = min(1, max(Self.minHeightFraction, defaults.object(forKey: Self.heightKey) as? Double ?? 0))
        let size = NSSize(width: (visible.width * widthFraction).rounded(), height: (visible.height * heightFraction).rounded())
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Remembers a size the user dragged to as a fraction of the screen, so it carries over to
    /// screens of other sizes.
    func windowDidEndLiveResize(_ notification: Notification) {
        if let visible = panel.screen?.visibleFrame {
            UserDefaults.standard.set(Double(panel.frame.width / visible.width), forKey: Self.widthKey)
            UserDefaults.standard.set(Double(panel.frame.height / visible.height), forKey: Self.heightKey)
        }
    }

    // MARK: - Tabs

    func newTab(with prompt: Prompt = Prompt()) {
        let tab = Tab(prompt: prompt, attributes: textAttributes)
        tab.dirty = true
        tabs.append(tab)
        select(tab)
        scheduleSave()
    }

    /// Closes the tab; a non-empty one goes to history and can come back with ⌘⇧T. Closing the
    /// last tab leaves an empty one.
    func close(_ tab: Tab, archive: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let prompt = tab.prompt
        if !prompt.isEmpty {
            if archive { history.add(prompt.attributed) }
            closedTabs.append(prompt)
            sidebar.reload()
        }
        tabs.remove(at: index)
        if persist { tabFiles.delete(tab.id) }
        if tabs.isEmpty {
            let empty = Tab(prompt: Prompt(), attributes: textAttributes)
            empty.dirty = true
            tabs.append(empty)
        }
        if tab === current {
            current = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            refreshTabBar(force: true)
        }
        scheduleSave()
    }

    /// The transcript tab stays.
    func closeCurrentTab() {
        if !showingTranscript { close(current) }
    }

    func reopenClosedTab() {
        guard let prompt = closedTabs.popLast() else { return }
        if current.prompt.isEmpty, tabs.count == 1 {
            load(prompt, into: current)
        } else {
            newTab(with: prompt)
        }
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        select(tabs[index])
    }

    /// ⌘1 to ⌘8 pick that tab, ⌘9 the last, as in browsers.
    func selectTab(number: Int) {
        selectTab(at: number == 9 ? tabs.count - 1 : number - 1)
    }

    /// Cycles through the transcript tab too, which sits before the first tab.
    func selectTab(offset: Int) {
        guard let index = showingTranscript ? -1 : tabs.firstIndex(where: { $0 === current }) else { return }
        let count = tabs.count + 1
        let next = ((index + 1 + offset) % count + count) % count - 1
        if next < 0 { showTranscript() } else { selectTab(at: next) }
    }

    /// ⌘⇧A: the transcript, or back to the tab from before it.
    func toggleTranscript() {
        if showingTranscript { select(current) } else { showTranscript() }
    }

    func showTranscript() {
        if !showingTranscript {
            textView.breakUndoCoalescing()
            current.selection = textView.selectedRanges
            current.scrollOrigin = scrollView.contentView.bounds.origin
            showingTranscript = true
            if persist { UserDefaults.standard.set(true, forKey: Self.transcriptKey) }
            scrollView.isHidden = true
            strip.isHidden = true
            transcript.view.isHidden = false
            refreshTabBar(force: true)
            updateStatus()
        }
        if !switcher.isOpen { focusEditor() }
        if panel.isVisible { transcript.appeared() }
    }

    func findPromptsInTranscript() {
        if !showingTranscript { showTranscript() }
        transcript.findPrompts()
    }

    func toggleSwitcher() {
        if switcher.isOpen { switcher.dismiss() } else { switcher.open() }
    }

    /// Shows `tab` in the editor, keeping the outgoing tab's cursor and scroll position.
    func select(_ tab: Tab) {
        if showingTranscript {
            showingTranscript = false
            if persist { UserDefaults.standard.set(false, forKey: Self.transcriptKey) }
            transcript.view.isHidden = true
            scrollView.isHidden = false
            strip.isHidden = false
            if current === tab {
                textView.setSelectedRanges(tab.selection, affinity: .downstream, stillSelecting: false)
                scrollView.contentView.scroll(to: tab.scrollOrigin)
            }
        } else if let current, current !== tab {
            // End the typing undo group so it doesn't run on into the next tab's text.
            textView.breakUndoCoalescing()
            current.selection = textView.selectedRanges
            current.scrollOrigin = scrollView.contentView.bounds.origin
        }
        let switching = current !== tab
        current = tab
        tab.lastActive = Date()
        if switching {
            textView.layoutManager?.replaceTextStorage(tab.storage)
            textView.typingAttributes = textAttributes
            textView.setSelectedRanges(tab.selection, affinity: .downstream, stillSelecting: false)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scrollView.contentView.scroll(to: tab.scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            strip.set(tab.images)
            coalescer.reset()
            openDeletionID = nil
        }
        refreshTabBar(force: true)
        updateStatus()
        if !switcher.isOpen { focusEditor() }
    }

    private func refreshTabBar(force: Bool = false) {
        let titles = tabs.map(\.title)
        guard force || titles != shownTitles else { return }
        shownTitles = titles
        tabBar.update(titles: titles, selected: showingTranscript ? nil : tabs.firstIndex { $0 === current } ?? 0)
    }

    /// Every tab but the current one by most recent use, then the current one, so ⌘K then Return
    /// goes back to the previous tab.
    private func switcherCandidates() -> [TabSearch.Candidate] {
        let others = tabs.filter { $0 !== current }.sorted { $0.lastActive > $1.lastActive }
        return (others + [current]).map {
            TabSearch.Candidate(id: $0.id, title: $0.title, text: $0.storage.string, lastActive: $0.lastActive)
        }
    }

    // MARK: - Commands

    /// Puts the prompt on the clipboard, files it in history and closes its tab. With `paste`,
    /// Hammerspoon then pastes it into the window that was focused before PromptBox opened.
    func send(paste: Bool) {
        if showingTranscript {
            sendTranscriptPrompt(paste: paste)
            return
        }
        let tab = current!
        let prompt = tab.prompt
        guard !prompt.isEmpty else {
            hide()
            return
        }
        let text: String
        do {
            text = try PromptExport.plainText(from: prompt, imageDirectory: Paths.images)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        history.add(prompt.attributed)
        close(tab, archive: false)
        hide(event: paste ? "promptbox-paste" : "promptbox-closed")
    }

    /// ⌘↩ on a prompt in the transcript tab sends it as is, without opening a tab.
    private func sendTranscriptPrompt(paste: Bool) {
        guard let candidate = transcript.selectedCandidate else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(candidate.prompt, forType: .string)
        history.add(NSAttributedString(string: candidate.prompt))
        transcript.consume(candidate)
        hide(event: paste ? "promptbox-paste" : "promptbox-closed")
    }

    func toggleSidebar(_ mode: SidebarMode) {
        if !sidebar.view.isHidden, sidebar.mode == mode {
            sidebar.view.isHidden = true
            focusEditor()
            return
        }
        sidebar.mode = mode
        sidebar.view.isHidden = false
        sidebar.focus()
    }

    func changeFontSize(by delta: CGFloat?) {
        fontSize = delta.map { min(40, max(9, fontSize + $0)) } ?? 14
        applyFont()
    }

    private func focusEditor() {
        if showingTranscript { transcript.focus() } else { panel.makeFirstResponder(textView) }
    }

    /// Return on a sidebar row: deleted text goes in at the cursor and deleted images back into the
    /// strip; a history entry opens in a new tab (or the current one, if it's empty).
    private func activate(mode: SidebarMode, id: String) {
        switch mode {
        case .deleted:
            guard let stored = deleted.text(for: id) else { return }
            if showingTranscript { select(current) }
            let entry = Prompt(stored)
            if !entry.text.isEmpty { textView.insertText(entry.text, replacementRange: textView.selectedRange()) }
            if !entry.images.isEmpty { insertImages(entry.images, at: strip.images.count) }
        case .history:
            guard let stored = history.text(for: id) else { return }
            if current.prompt.isEmpty { load(Prompt(stored), into: current) } else { newTab(with: Prompt(stored)) }
        }
        focusEditor()
    }

    /// Replaces a tab's text (as one undoable step) and images.
    private func load(_ prompt: Prompt, into tab: Tab) {
        if tab !== current { select(tab) }
        let full = NSRange(location: 0, length: tab.storage.length)
        suppressDeletionLog = true
        if textView.shouldChangeText(in: full, replacementString: prompt.text) {
            textView.replaceCharacters(in: full, with: prompt.text)
            textView.didChangeText()
        }
        suppressDeletionLog = false
        coalescer.reset()
        textView.setSelectedRange(NSRange(location: (prompt.text as NSString).length, length: 0))
        strip.set(prompt.images)
        imagesChanged()
    }

    // MARK: - Images

    private func insertImages(_ pngs: [Data], at start: Int) {
        for (i, png) in pngs.enumerated() { strip.insert(png, at: start + i) }
        textView.breakUndoCoalescing()
        textView.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeImages(at: start, count: pngs.count) }
        }
        textView.undoManager?.setActionName(pngs.count == 1 ? "Add Image" : "Add Images")
        imagesChanged()
    }

    private func removeImages(at start: Int, count: Int) {
        let removed = (0..<count).map { _ in strip.remove(at: start) }
        textView.breakUndoCoalescing()
        textView.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.insertImages(removed, at: start) }
        }
        textView.undoManager?.setActionName(count == 1 ? "Remove Image" : "Remove Images")
        imagesChanged()
    }

    /// The × on a thumbnail: the image goes to the deleted log, and ⌘Z also puts it back.
    private func removeImageByUser(at index: Int) {
        guard index < strip.images.count else { return }
        deleted.add(Prompt(images: [strip.images[index]]).attributed)
        coalescer.reset()
        if sidebar.mode == .deleted { sidebar.reload() }
        removeImages(at: index, count: 1)
    }

    private func imagesChanged() {
        current.images = strip.images
        current.dirty = true
        refreshTabBar()
        updateStatus()
        scheduleSave()
    }

    // MARK: - Text view delegate

    /// Each tab has its own undo stack.
    func undoManager(for view: NSTextView) -> UndoManager? {
        current?.undoManager
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) || commandSelector == #selector(NSTextView.complete(_:)) {
            hide()
            return true
        }
        return false
    }

    /// Every removal of text, whether by backspace, cut, typing over a selection or ⌘⇧K, lands in
    /// the deleted log before it happens.
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        guard !suppressDeletionLog, let replacements = replacementStrings, let storage = textView.textStorage else { return true }
        var changed = false
        for (value, replacement) in zip(affectedRanges, replacements) {
            let range = value.rangeValue
            guard range.length > 0 else {
                _ = coalescer.record(range: range, deletedText: "", replacementLength: (replacement as NSString).length, at: Date())
                continue
            }
            let removed = storage.attributedSubstring(from: range)
            let decision = coalescer.record(range: range, deletedText: removed.string,
                                            replacementLength: (replacement as NSString).length, at: Date())
            switch decision {
            case .ignore:
                continue
            case .prepend, .append:
                if let id = openDeletionID, let existing = deleted.text(for: id) {
                    let combined = NSMutableAttributedString()
                    combined.append(decision == .prepend ? removed : existing)
                    combined.append(decision == .prepend ? existing : removed)
                    deleted.update(id, text: combined)
                } else {
                    openDeletionID = deleted.add(removed)
                }
            case .newEntry:
                openDeletionID = deleted.add(removed)
            }
            changed = true
        }
        if changed, sidebar.mode == .deleted { sidebar.reload() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        current.dirty = true
        refreshTabBar()
        updateStatus()
        scheduleSave()
    }

    private func updateStatus() {
        if showingTranscript {
            status.stringValue = "↩ open in a tab   ⌘↩ send   ⌫ dismiss   ⌘R find prompts   ⇥ other list   ⌘⇧A back   esc hide"
            return
        }
        let words = textView.string.split { $0.isWhitespace || $0.isNewline }.count
        let images = strip.images.count
        var counts = "\(words) word\(words == 1 ? "" : "s")"
        if images > 0 { counts += " · \(images) image\(images == 1 ? "" : "s")" }
        status.stringValue = "\(counts)     ⌘↩ send   ⌘⇧↩ copy   ⌘T new tab   ⌘K find tab   ⌘D deleted   ⌘Y history   esc hide"
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Writes changed tabs, the tab order and both logs, so a crash or quit loses at most the
    /// last second of typing.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard persist else { return }
        for tab in tabs where tab.dirty {
            try? tabFiles.save(tab.prompt, id: tab.id)
            tab.dirty = false
        }
        try? tabFiles.save(TabIndex(tabs: tabs.map(\.record), selected: current?.id))
        history.flush()
        deleted.flush()
    }

    /// Opens the saved tabs. The first launch after tabs arrived turns the old single draft into
    /// the first tab.
    private func loadTabs() {
        let attributes = textAttributes
        if persist, let index = tabFiles.loadIndex() {
            tabs = index.tabs.map { record in
                Tab(id: record.id, created: record.created, lastActive: record.lastActive,
                    prompt: tabFiles.loadPrompt(record.id) ?? Prompt(), attributes: attributes)
            }
            let selected = tabs.first { $0.id == index.selected }
            if !tabs.isEmpty {
                applyFont()
                select(selected ?? tabs[0])
                if UserDefaults.standard.bool(forKey: Self.transcriptKey) { showTranscript() }
                return
            }
        }
        var first = Prompt()
        if persist, let draft = try? NSAttributedString(url: Paths.draft, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                        documentAttributes: nil) {
            first = Prompt(draft)
        }
        let tab = Tab(prompt: first, attributes: attributes)
        tab.dirty = true
        tabs = [tab]
        applyFont()
        select(tab)
        saveNow()
        if persist { try? FileManager.default.removeItem(at: Paths.draft) }
    }
}
