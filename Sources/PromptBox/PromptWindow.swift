import AppKit
import PromptBoxCore

/// The floating editor window with its sidebar of deleted text and sent prompts.
@MainActor
final class PromptWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    enum SidebarMode: Int { case deleted, history }

    let panel: NSPanel
    let textView = EditorTextView(usingTextLayoutManager: false)
    let strip = ImageStrip()
    private let scrollView = NSScrollView()
    private let sidebar: Sidebar
    private let status = NSTextField(labelWithString: "")

    let history: EntryStore
    let deleted: EntryStore
    /// False for the self-test: nothing is read from or written to disk.
    private let persist: Bool
    private var coalescer = DeletionCoalescer()
    private var openDeletionID: String?
    private var suppressDeletionLog = false
    private var saveWork: DispatchWorkItem?

    /// Called with the Hammerspoon event to send after the window hides.
    var onHide: ((String) -> Void)?

    private static let fontSizeKey = "fontSize"
    private static let widthKey = "widthFraction"
    private static let heightKey = "heightFraction"
    /// The window never opens smaller than a third of the screen's width and half its height.
    private static let minWidthFraction: CGFloat = 1.0 / 3.0
    private static let minHeightFraction: CGFloat = 0.5

    private var fontSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: Self.fontSizeKey) as? Double ?? 14) }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.fontSizeKey) }
    }

    var prompt: Prompt { Prompt(text: textView.string, images: strip.images) }

    init(persist: Bool = true) {
        self.persist = persist
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        history = EntryStore(directory: persist ? Paths.history : scratch.appendingPathComponent("history"), limit: 500)
        deleted = EntryStore(directory: persist ? Paths.deleted : scratch.appendingPathComponent("deleted"), limit: 1000)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        sidebar = Sidebar(history: history, deleted: deleted)
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
        if persist { loadDraft() }
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
        textView.textColor = .textColor
        textView.delegate = self
        applyFont()
        scrollView.documentView = textView
        textView.updateDragTypeRegistration()
    }

    /// Editor and sidebar side by side, the image strip under them, then the status line.
    private func setUpLayout() {
        let row = NSStackView(views: [scrollView, sidebar.view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .height
        row.detachesHiddenViews = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebar.view.isHidden = true
        let sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: 300)
        sidebarWidth.priority = .defaultHigh

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [row, strip])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.detachesHiddenViews = true
        row.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        for view in [column, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarWidth,
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            strip.widthAnchor.constraint(equalTo: column.widthAnchor),
            sidebar.view.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.5),
            // Start below the transparent title bar so text doesn't sit under the traffic lights.
            column.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        panel.contentView = content
        updateStatus()
    }

    private func applyFont() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        textView.font = attributes[.font] as? NSFont
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    // MARK: - Showing and hiding

    /// `anchor` is a point, in AppKit screen coordinates, on the screen the window should open on.
    func show(near anchor: NSPoint?) {
        if !panel.isVisible { position(near: anchor ?? NSEvent.mouseLocation) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if panel.firstResponder !== sidebar.table { focusEditor() }
    }

    func hide(event: String = "promptbox-closed") {
        guard panel.isVisible else { return }
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

    // MARK: - Commands

    /// Puts the prompt on the clipboard, files it in history and clears the editor. With `paste`,
    /// Hammerspoon then pastes it into the window that was focused before PromptBox opened.
    func send(paste: Bool) {
        let current = prompt
        guard !current.isEmpty else {
            hide()
            return
        }
        let text: String
        do {
            text = try PromptExport.plainText(from: current, imageDirectory: Paths.images)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        history.add(current.attributed)
        load(Prompt())
        sidebar.reload()
        hide(event: paste ? "promptbox-paste" : "promptbox-closed")
    }

    /// Files the current prompt in history and starts an empty one. ⌘Z brings the text back.
    func newPrompt() {
        let current = prompt
        guard !current.isEmpty else { return }
        history.add(current.attributed)
        load(Prompt())
        sidebar.reload()
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
        panel.makeFirstResponder(textView)
    }

    /// Return on a sidebar row: deleted text goes in at the cursor and deleted images back into the
    /// strip; a history entry replaces the editor (the current prompt is filed in history first,
    /// so nothing is lost either way).
    private func activate(mode: SidebarMode, id: String) {
        switch mode {
        case .deleted:
            guard let stored = deleted.text(for: id) else { return }
            let entry = Prompt(stored)
            if !entry.text.isEmpty { textView.insertText(entry.text, replacementRange: textView.selectedRange()) }
            if !entry.images.isEmpty { insertImages(entry.images, at: strip.images.count) }
        case .history:
            guard let stored = history.text(for: id) else { return }
            let entry = Prompt(stored)
            let current = prompt
            if !current.isEmpty, current != entry {
                history.add(current.attributed)
                sidebar.reload()
            }
            load(entry)
        }
        focusEditor()
    }

    /// Replaces the text (as one undoable step) and the images.
    private func load(_ prompt: Prompt) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
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
        updateStatus()
        scheduleSave()
    }

    // MARK: - Text view delegate

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
        updateStatus()
        scheduleSave()
    }

    private func updateStatus() {
        let words = textView.string.split { $0.isWhitespace || $0.isNewline }.count
        let images = strip.images.count
        var counts = "\(words) word\(words == 1 ? "" : "s")"
        if images > 0 { counts += " · \(images) image\(images == 1 ? "" : "s")" }
        status.stringValue = "\(counts)     ⌘↩ send   ⌘⇧↩ copy   esc hide   ⌘D deleted   ⌘Y history   ⌘N new"
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Writes the draft and both logs, so a crash or quit loses at most the last second of typing.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard persist else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? EntryStore.writeRTFD(prompt.attributed, to: Paths.draft)
        history.flush()
        deleted.flush()
    }

    private func loadDraft() {
        guard let draft = try? NSAttributedString(url: Paths.draft, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil) else { return }
        let saved = Prompt(draft)
        textView.string = saved.text
        applyFont()
        textView.setSelectedRange(NSRange(location: (saved.text as NSString).length, length: 0))
        strip.set(saved.images)
        updateStatus()
    }
}
