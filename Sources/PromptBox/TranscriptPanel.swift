import AppKit
import PromptBoxCore

/// The transcript tab: a suggested prompt on top, written by the model from the last few
/// minutes of speech and editable like any tab, and the live thread of everything heard below.
@MainActor
final class TranscriptPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSTextViewDelegate {
    let view = NSView()
    let editor = NSTextView(usingTextLayoutManager: false)
    let thread = SidebarTable()

    /// Open this text in a new tab: the suggestion, or thread messages.
    var onOpen: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// The microphone started, stopped or failed.
    var onListenerChange: (() -> Void)?

    private let log: TranscriptLog
    private let store: SuggestionStore
    private let listener: Listener?
    /// What the microphone heard; the thread shows these.
    private var segments: [TranscriptSegment] = []
    /// What the Mac played, only used to find microphone segments that are really the speakers.
    private var played: [TranscriptSegment] = []
    /// Microphone segment id to the share of its words the speakers were playing.
    private var echo: [String: Double] = [:]
    private var bubbles: [TranscriptBubble] = []
    /// Segments the suggestion came from, marked in the thread.
    private var usedSegments: Set<String> = []

    private(set) var isWriting = false
    /// Typing while the model writes keeps the typing and drops what comes back.
    private var typedWhileWriting = false
    private var settingText = false
    private let editorUndo = UndoManager()

    private let listenStatus = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private let rewriteButton = NSButton(title: "Rewrite", target: nil, action: nil)
    private let openButton = NSButton(title: "Open in tab", target: nil, action: nil)
    private let split = NSSplitView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let timeFormatter = DateFormatter()
    private let dayFormatter = DateFormatter()
    private var positionedDivider = false

    /// `suggestionMinutes` in defaults, else five.
    private var minutes: Double {
        let set = UserDefaults.standard.double(forKey: "suggestionMinutes")
        return set > 0 ? set : PromptSuggestion.defaultMinutes
    }

    init(log: TranscriptLog, store: SuggestionStore, listener: Listener?) {
        self.log = log
        self.store = store
        self.listener = listener
        super.init()
        timeFormatter.dateFormat = "HH:mm"
        dayFormatter.dateFormat = "EEE HH:mm"
        setUpEditor()
        setUpThread()
        setUpLayout()
        reloadSegments()
        editor.string = store.suggestion.text
        usedSegments = Set(store.suggestion.segmentIDs)
        refreshPlaceholder()
        listener?.onSegment = { [weak self] segment in self?.append(segment) }
        listener?.onChange = { [weak self] in self?.listenerChanged() }
        refreshStatus()
    }

    /// A copy: `editor.string` is the text storage's live backing store, so a string taken from it
    /// changes when the editor does.
    var suggestionText: String { editor.attributedString().string }

    /// Font, colour and line spacing, the same as the prompt tabs.
    var textAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet {
            editor.font = textAttributes[.font] as? NSFont
            editor.defaultParagraphStyle = textAttributes[.paragraphStyle] as? NSParagraphStyle
            editor.typingAttributes = textAttributes
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttributes(textAttributes, range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    func focus() {
        view.window?.makeFirstResponder(editor)
    }

    /// Called when the tab comes to the front: writes a new suggestion when something was said
    /// since the last one, unless the current one has been edited.
    func appeared() {
        reloadSegments()
        if !positionedDivider, split.bounds.height > 0 {
            positionedDivider = true
            split.setPosition((split.bounds.height * 0.4).rounded(), ofDividerAt: 0)
        }
        scrollThreadToEnd()
        let fresh = recentSpeech
        guard let newest = fresh.last?.end, newest > store.suggestion.through ?? .distantPast else { return }
        if store.suggestion.edited, !isEmpty {
            note.stringValue = "You said more since this was written. ⌘R rewrites it from the last \(minutesLabel) (⌘Z undoes)."
        } else {
            write(from: fresh)
        }
    }

    /// After the suggestion is sent, copied or opened in a tab: a new prompt starts, written only
    /// from what's said from now on.
    func clearSuggestion() {
        replaceText(with: "")
        startNewPrompt()
        note.stringValue = ""
    }

    /// Speech from before now no longer counts towards the suggestion.
    private func startNewPrompt() {
        store.suggestion = Suggestion(through: store.suggestion.through, newPromptFrom: Date())
        usedSegments = []
        thread.reloadData()
        refreshPlaceholder()
    }

    /// The last few minutes of speech, from after the current prompt was started.
    private var recentSpeech: [TranscriptSegment] {
        PromptSuggestion.recent(segments, after: store.suggestion.newPromptFrom, minutes: minutes)
    }

    private var isEmpty: Bool {
        suggestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc func openInTab() {
        let text = suggestionText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onOpen?(text)
        clearSuggestion()
    }

    /// Self-test only: puts made-up speech in the log as if it had just been heard.
    func seed(_ fake: [TranscriptSegment]) {
        for segment in fake { try? log.append(segment) }
        reloadSegments()
    }

    // MARK: - Writing the suggestion

    /// ⌘R: from the selected thread messages, or else the last few minutes. Replaces edits;
    /// ⌘Z brings them back.
    @objc func rewrite() {
        let rows = thread.selectedRowIndexes.filter { $0 < bubbles.count }
        if rows.isEmpty, recentSpeech.isEmpty, let from = store.suggestion.newPromptFrom {
            note.stringValue = "Nothing said since the new prompt at \(label(for: from)). Select messages in the thread to use earlier speech."
            return
        }
        let chosen = rows.isEmpty ? recentSpeech : PromptSuggestion.limit(rows.flatMap { bubbles[$0].segments })
        write(from: chosen)
    }

    private func write(from chosen: [TranscriptSegment]) {
        guard !isWriting else { return }
        guard let first = chosen.first, let last = chosen.last else {
            note.stringValue = "Nothing heard yet."
            return
        }
        isWriting = true
        typedWhileWriting = false
        rewriteButton.isEnabled = false
        let range = "\(label(for: first.start))–\(timeFormatter.string(from: last.end))"
        note.stringValue = "Writing a prompt from \(range)…"
        refreshPlaceholder()
        let echo = self.echo
        Task {
            defer {
                self.isWriting = false
                self.rewriteButton.isEnabled = true
                self.refreshPlaceholder()
            }
            do {
                var suggestion = try await Suggester.suggestion(from: chosen, echo: echo)
                if typedWhileWriting {
                    store.suggestion.through = suggestion.through
                    note.stringValue = "Kept what you typed. ⌘R replaces it with a rewrite from \(range)."
                    return
                }
                replaceText(with: suggestion.text)
                suggestion.newPromptFrom = store.suggestion.newPromptFrom
                store.suggestion = suggestion
                usedSegments = Set(suggestion.segmentIDs)
                thread.reloadData()
                note.stringValue = suggestion.text.isEmpty
                    ? "Nothing from \(range) sounded like a prompt."
                    : "Written from \(range)."
                if view.window?.firstResponder === editor { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
            } catch {
                note.stringValue = "Couldn't write a prompt: \(error.localizedDescription)"
            }
        }
    }

    /// Replaces the whole suggestion as one step ⌘Z can undo.
    private func replaceText(with text: String) {
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        settingText = true
        if editor.shouldChangeText(in: full, replacementString: text) {
            editor.replaceCharacters(in: full, with: text)
            editor.didChangeText()
            editorUndo.setActionName("Rewrite")
        }
        settingText = false
        if let storage = editor.textStorage, storage.length > 0 {
            storage.addAttributes(textAttributes, range: NSRange(location: 0, length: storage.length))
        }
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        placeholder.isHidden = !editor.string.isEmpty
        if isWriting {
            placeholder.stringValue = "Writing…"
        } else if let from = store.suggestion.newPromptFrom {
            placeholder.stringValue = "New prompt. Opening this tab writes it from what you say after \(label(for: from)), and you can edit it here."
        } else {
            placeholder.stringValue = "Say what you want done. Opening this tab writes a prompt from the last \(minutesLabel), and you can edit it here."
        }
    }

    private var minutesLabel: String {
        minutes == 1 ? "minute" : "\(minutes.formatted()) minutes"
    }

    // MARK: - Editor delegate

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    /// Emptying the suggestion by hand starts a new prompt, the same as sending it.
    func textDidChange(_ notification: Notification) {
        refreshPlaceholder()
        guard !settingText else { return }
        if isWriting { typedWhileWriting = true }
        let hadText = !store.suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty, hadText {
            startNewPrompt()
            note.stringValue = "New prompt: only what you say from now on goes into it."
            return
        }
        store.suggestion.text = suggestionText
        store.suggestion.edited = true
    }

    /// Esc hides the window; Tab goes to the thread, since a prompt rarely needs a tab character.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            onCancel?()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            view.window?.makeFirstResponder(thread)
            if thread.selectedRow < 0, !bubbles.isEmpty { thread.selectRowIndexes([bubbles.count - 1], byExtendingSelection: false) }
            scrollThreadToEnd()
        default:
            return false
        }
        return true
    }

    // MARK: - Thread

    private func reloadSegments() {
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400))
        let all = log.segments(since: since)
        segments = all.filter { $0.source == .mic }
        played = all.filter { $0.source == .speakers }
        echo = EchoMatch.scores(mic: segments, speakers: played)
        bubbles = TranscriptThread.bubbles(segments)
        thread.reloadData()
    }

    /// Speaker audio can finish after the microphone segment it echoes, so both kinds rescore
    /// the recent segments.
    private func append(_ segment: TranscriptSegment) {
        let atEnd = isThreadAtEnd
        let recent = segment.start.addingTimeInterval(-120)
        if segment.source == .speakers {
            played.append(segment)
        } else {
            segments.append(segment)
        }
        let rescored = EchoMatch.scores(mic: segments.filter { $0.end >= recent }, speakers: played.filter { $0.end >= recent })
        echo.merge(rescored) { _, new in new }
        guard segment.source == .mic || !rescored.isEmpty else { return }
        let before = bubbles.count
        bubbles = TranscriptThread.bubbles(segments)
        if segment.source == .mic, bubbles.count == before, before > 0 {
            thread.reloadData(forRowIndexes: [before - 1], columnIndexes: [0])
            thread.noteHeightOfRows(withIndexesChanged: [before - 1])
        } else {
            thread.reloadData()
        }
        if atEnd { scrollThreadToEnd() }
    }

    private func listenerChanged() {
        refreshStatus()
        onListenerChange?()
        let atEnd = isThreadAtEnd
        let rows = bubbles.count + (listener?.volatile.isEmpty == false ? 1 : 0)
        if thread.numberOfRows != rows {
            thread.reloadData()
        } else if rows > bubbles.count {
            thread.reloadData(forRowIndexes: [bubbles.count], columnIndexes: [0])
            thread.noteHeightOfRows(withIndexesChanged: [bubbles.count])
        }
        if atEnd { scrollThreadToEnd() }
    }

    private var isThreadAtEnd: Bool {
        guard let scroll = thread.enclosingScrollView else { return true }
        return scroll.contentView.bounds.maxY >= thread.bounds.maxY - 40
    }

    private func scrollThreadToEnd() {
        if thread.numberOfRows > 0 { thread.scrollRowToVisible(thread.numberOfRows - 1) }
    }

    private func openSelectedMessages() {
        let text = thread.selectedRowIndexes.filter { $0 < bubbles.count }.map { bubbles[$0].text }.joined(separator: "\n\n")
        if !text.isEmpty { onOpen?(text) }
    }

    // MARK: - Status

    @objc private func togglePause() {
        guard let listener else { return }
        listener.setPaused(!listener.isPaused)
    }

    private func refreshStatus() {
        let listening: String
        switch listener?.state {
        case nil: listening = "Not listening"
        case .starting: listening = "Starting the microphone…"
        case .listening(let locale):
            listening = "● Listening (\(locale))" + (listener?.speakerProblem.map { " · \($0)" } ?? "")
        case .paused: listening = "Paused"
        case .failed(let message): listening = message
        }
        listenStatus.stringValue = listening
        listenStatus.textColor = { if case .listening = listener?.state { return .systemRed } else { return .secondaryLabelColor } }()
        let paused = listener?.isPaused ?? true
        pauseButton.title = paused ? "Listen" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: paused ? "mic" : "mic.slash", accessibilityDescription: nil)
        pauseButton.isEnabled = listener != nil
    }

    // MARK: - Setup

    private func setUpEditor() {
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 18, height: 12)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.delegate = self
    }

    private func setUpThread() {
        thread.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
        thread.headerView = nil
        thread.style = .plain
        thread.usesAutomaticRowHeights = true
        thread.dataSource = self
        thread.delegate = self
        thread.target = self
        thread.allowsMultipleSelection = true
        thread.doubleAction = #selector(doubleClicked)
        thread.onReturn = { [weak self] in self?.openSelectedMessages() }
        thread.onDelete = {}
        thread.onCancel = { [weak self] in self?.onCancel?() }
        thread.nextKeyView = editor
    }

    @objc private func doubleClicked() { openSelectedMessages() }

    private func setUpLayout() {
        listenStatus.font = .systemFont(ofSize: 11, weight: .medium)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [pauseButton, rewriteButton, openButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.imagePosition = .imageLeading
            button.target = self
        }
        pauseButton.action = #selector(togglePause)
        rewriteButton.action = #selector(rewrite)
        rewriteButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        rewriteButton.toolTip = "Rewrite from the selected messages, or the last few minutes (⌘R)"
        openButton.action = #selector(openInTab)
        openButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        openButton.toolTip = "Open the suggestion in a new tab (⌘O)"

        let header = NSStackView(views: [listenStatus, note, NSView(), rewriteButton, openButton, pauseButton])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)

        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let top = NSView()
        for sub in [editorScroll, placeholder] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            editorScroll.topAnchor.constraint(equalTo: top.topAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: top.topAnchor, constant: 13),
            placeholder.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: top.trailingAnchor, constant: -24),
        ])

        let threadScroll = NSScrollView()
        threadScroll.documentView = thread
        threadScroll.hasVerticalScroller = true
        threadScroll.drawsBackground = true
        threadScroll.backgroundColor = .controlBackgroundColor
        thread.backgroundColor = .controlBackgroundColor

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(top)
        split.addArrangedSubview(threadScroll)

        let separator = NSBox()
        separator.boxType = .separator
        for sub in [header, separator, split] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: separator.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        60
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 80
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        bubbles.count + (listener?.volatile.isEmpty == false ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("message")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MessageCell ?? MessageCell(identifier: id)
        if row < bubbles.count {
            let bubble = bubbles[row]
            cell.time.stringValue = label(for: bubble.start)
            cell.body.attributedStringValue = text(of: bubble)
            cell.used = bubble.segments.contains { usedSegments.contains($0.id) }
            cell.fromSpeakers = bubble.segments.contains { (echo[$0.id] ?? 0) >= EchoMatch.partial }
        } else {
            cell.time.stringValue = "now"
            cell.body.attributedStringValue = NSAttributedString(string: listener?.volatile ?? "", attributes: [
                .font: MessageCell.font, .foregroundColor: NSColor.secondaryLabelColor,
            ])
            cell.used = false
            cell.fromSpeakers = false
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < bubbles.count
    }

    /// Segments that are the speakers are faded; ones that are partly the speakers less so.
    private func text(of bubble: TranscriptBubble) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, segment) in bubble.segments.enumerated() {
            let score = echo[segment.id] ?? 0
            let color: NSColor = score >= EchoMatch.echo ? .tertiaryLabelColor : score >= EchoMatch.partial ? .secondaryLabelColor : .labelColor
            result.append(NSAttributedString(string: (i == 0 ? "" : " ") + segment.text,
                                             attributes: [.font: MessageCell.font, .foregroundColor: color]))
        }
        return result
    }

    private func label(for date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dayFormatter.string(from: date)
    }
}

/// A message in the thread: its time on the left, the words on the right. A bar marks messages
/// the suggestion came from.
final class MessageCell: NSTableCellView {
    static let font = NSFont.systemFont(ofSize: 13)

    let time = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    private let bar = NSView()
    private let speaker = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "From the speakers")!)

    var used = false { didSet { bar.isHidden = !used } }
    /// Some of it was a video or call the microphone picked up.
    var fromSpeakers = false {
        didSet {
            speaker.isHidden = !fromSpeakers
            toolTip = fromSpeakers ? "The faded words were also playing from the speakers." : nil
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        body.font = Self.font
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        speaker.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        speaker.contentTintColor = .tertiaryLabelColor
        speaker.isHidden = true
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.layer?.cornerRadius = 1.5
        bar.isHidden = true
        for sub in [time, body, bar, speaker] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            time.firstBaselineAnchor.constraint(equalTo: body.firstBaselineAnchor),
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            time.widthAnchor.constraint(equalToConstant: 58),
            speaker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            speaker.centerYAnchor.constraint(equalTo: time.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 6),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: body.topAnchor),
            bar.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            body.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
