import AppKit
import PromptBoxCore

/// The transcript tab: prompts the model found on top, the live thread of everything heard
/// below. Opening the tab reads what was said since the last time and adds the prompts in it.
@MainActor
final class TranscriptPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    let view = NSView()
    let prompts = SidebarTable()
    let thread = SidebarTable()

    /// Return on a prompt or on thread messages: open this text in a new tab.
    var onOpen: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// The microphone started, stopped or failed.
    var onListenerChange: (() -> Void)?

    private let log: TranscriptLog
    private let store: CandidateStore
    private let listener: Listener?
    private var segments: [TranscriptSegment] = []
    private var bubbles: [TranscriptBubble] = []
    /// Segments some prompt came from, marked in the thread.
    private var usedSegments: Set<String> = []
    private var grouping = false
    private var groupingNote = "" { didSet { refreshStatus() } }

    private let listenStatus = NSTextField(labelWithString: "")
    private let groupStatus = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let groupButton = NSButton(title: "Find prompts", target: nil, action: nil)
    private let split = NSSplitView()
    private let emptyPrompts = NSTextField(wrappingLabelWithString: "")
    private let timeFormatter = DateFormatter()
    private let dayFormatter = DateFormatter()
    private var positionedDivider = false

    /// Minimum words in new speech before opening the tab asks the model about it.
    private static let minimumWords = 4

    init(log: TranscriptLog, store: CandidateStore, listener: Listener?) {
        self.log = log
        self.store = store
        self.listener = listener
        super.init()
        timeFormatter.dateFormat = "HH:mm"
        dayFormatter.dateFormat = "EEE HH:mm"
        setUpTables()
        setUpLayout()
        reloadSegments()
        refreshUsed()
        listener?.onSegment = { [weak self] segment in self?.append(segment) }
        listener?.onChange = { [weak self] in self?.listenerChanged() }
        refreshStatus()
    }

    var selectedCandidate: PromptCandidate? {
        let row = prompts.selectedRow
        return row >= 0 && row < store.candidates.count ? store.candidates[row] : nil
    }

    func focus() {
        let table = store.candidates.isEmpty ? thread : prompts
        view.window?.makeFirstResponder(table)
        if table === prompts, prompts.selectedRow < 0 { prompts.selectRowIndexes([0], byExtendingSelection: false) }
        if table === thread { scrollThreadToEnd() }
    }

    /// Called when the tab comes to the front.
    func appeared() {
        reloadSegments()
        if !positionedDivider, split.bounds.height > 0 {
            positionedDivider = true
            split.setPosition((split.bounds.height * 0.45).rounded(), ofDividerAt: 0)
        }
        findPromptsInNewSpeech()
        scrollThreadToEnd()
    }

    /// Removes a prompt once it's been opened in a tab or sent.
    func consume(_ candidate: PromptCandidate) {
        let row = prompts.selectedRow
        store.remove(candidate.id)
        reloadPrompts(select: row)
    }

    /// Self-test only: puts made-up speech in the log as if it had just been heard.
    func seed(_ fake: [TranscriptSegment]) {
        for segment in fake { try? log.append(segment) }
        reloadSegments()
    }

    var candidates: [PromptCandidate] { store.candidates }
    var isFindingPrompts: Bool { grouping }

    // MARK: - Finding prompts

    /// Everything said since the last pass, unless there's too little of it to bother.
    func findPromptsInNewSpeech() {
        let since = store.processedThrough ?? Date().addingTimeInterval(-3600)
        let fresh = segments.filter { $0.start >= since }
        guard fresh.reduce(0, { $0 + $1.wordCount }) >= Self.minimumWords else { return }
        find(in: fresh, advancing: true)
    }

    /// The thread messages selected, or else everything new.
    @objc func findPrompts() {
        let rows = thread.selectedRowIndexes.filter { $0 < bubbles.count }
        if rows.isEmpty {
            let since = store.processedThrough ?? Date().addingTimeInterval(-3600)
            let fresh = segments.filter { $0.start >= since }
            if fresh.isEmpty {
                groupingNote = "Nothing new said since the last pass. Select messages in the thread to look at them again."
            } else {
                find(in: fresh, advancing: true)
            }
        } else {
            find(in: rows.flatMap { bubbles[$0].segments }, advancing: false)
        }
    }

    private func find(in chosen: [TranscriptSegment], advancing: Bool) {
        guard !grouping else { return }
        let sent = PromptGrouping.limit(chosen)
        grouping = true
        let skipped = chosen.count - sent.count
        groupingNote = "Finding prompts in \(sent.count) segment\(sent.count == 1 ? "" : "s")…"
            + (skipped > 0 ? " (skipped \(skipped) older)" : "")
        groupButton.isEnabled = false
        Task {
            defer {
                self.grouping = false
                self.groupButton.isEnabled = true
            }
            do {
                let found = try await Grouper.candidates(from: sent)
                if advancing, let last = chosen.last { store.processedThrough = last.end }
                store.add(found)
                reloadPrompts(select: found.isEmpty ? nil : 0)
                refreshUsed()
                groupingNote = found.isEmpty ? "No prompts in what was said." : "Found \(found.count) prompt\(found.count == 1 ? "" : "s")."
                if !found.isEmpty, view.window?.firstResponder === thread { view.window?.makeFirstResponder(prompts) }
            } catch {
                groupingNote = "Couldn't find prompts: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Thread

    private func reloadSegments() {
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400))
        segments = log.segments(since: since)
        bubbles = TranscriptThread.bubbles(segments)
        thread.reloadData()
    }

    private func append(_ segment: TranscriptSegment) {
        let atEnd = isThreadAtEnd
        segments.append(segment)
        let before = bubbles.count
        bubbles = TranscriptThread.bubbles(segments)
        if bubbles.count == before, before > 0 {
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

    // MARK: - Prompts

    private func reloadPrompts(select row: Int?) {
        prompts.reloadData()
        emptyPrompts.isHidden = !store.candidates.isEmpty
        if let row, !store.candidates.isEmpty {
            prompts.selectRowIndexes([min(row, store.candidates.count - 1)], byExtendingSelection: false)
        }
    }

    private func refreshUsed() {
        usedSegments = Set(store.candidates.flatMap(\.segmentIDs))
        thread.reloadData()
    }

    private func dismissSelectedPrompt() {
        guard let candidate = selectedCandidate else { return }
        consume(candidate)
        refreshUsed()
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
        case .listening(let locale): listening = "● Listening (\(locale))"
        case .paused: listening = "Paused"
        case .failed(let message): listening = message
        }
        listenStatus.stringValue = listening
        listenStatus.textColor = { if case .listening = listener?.state { return .systemRed } else { return .secondaryLabelColor } }()
        groupStatus.stringValue = groupingNote
        let paused = listener?.isPaused ?? true
        pauseButton.title = paused ? "Listen" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: paused ? "mic" : "mic.slash", accessibilityDescription: nil)
        pauseButton.isEnabled = listener != nil
    }

    // MARK: - Setup

    private func setUpTables() {
        for table in [prompts, thread] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
            table.headerView = nil
            table.style = .plain
            table.usesAutomaticRowHeights = true
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.onCancel = { [weak self] in self?.onCancel?() }
        }
        prompts.doubleAction = #selector(doubleClicked(_:))
        thread.doubleAction = #selector(doubleClicked(_:))
        prompts.onReturn = { [weak self] in
            guard let self, let candidate = self.selectedCandidate else { return }
            self.onOpen?(candidate.prompt)
            self.consume(candidate)
            self.refreshUsed()
        }
        prompts.onDelete = { [weak self] in self?.dismissSelectedPrompt() }
        thread.allowsMultipleSelection = true
        thread.onReturn = { [weak self] in self?.openSelectedMessages() }
        thread.onDelete = {}
        prompts.nextKeyView = thread
        thread.nextKeyView = prompts
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        (sender === prompts ? prompts.onReturn : thread.onReturn)?()
    }

    private func setUpLayout() {
        listenStatus.font = .systemFont(ofSize: 11, weight: .medium)
        groupStatus.font = .systemFont(ofSize: 11)
        groupStatus.textColor = .secondaryLabelColor
        groupStatus.lineBreakMode = .byTruncatingTail
        groupStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [pauseButton, groupButton] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.imagePosition = .imageLeading
            button.target = self
        }
        pauseButton.action = #selector(togglePause)
        groupButton.action = #selector(findPrompts)
        groupButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        groupButton.toolTip = "Find prompts in the selected messages, or in everything new (⌘R)"

        let header = NSStackView(views: [listenStatus, groupStatus, NSView(), groupButton, pauseButton])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)

        emptyPrompts.stringValue = "Prompts you say out loud show up here when you open this tab. Select messages below and press ⌘R to look at them again."
        emptyPrompts.font = .systemFont(ofSize: 12)
        emptyPrompts.textColor = .tertiaryLabelColor
        emptyPrompts.alignment = .center
        emptyPrompts.isHidden = !store.candidates.isEmpty

        let promptsScroll = scroll(for: prompts)
        promptsScroll.addSubview(emptyPrompts)
        emptyPrompts.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyPrompts.centerYAnchor.constraint(equalTo: promptsScroll.centerYAnchor),
            emptyPrompts.leadingAnchor.constraint(equalTo: promptsScroll.leadingAnchor, constant: 40),
            emptyPrompts.trailingAnchor.constraint(equalTo: promptsScroll.trailingAnchor, constant: -40),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(promptsScroll)
        split.addArrangedSubview(scroll(for: thread))

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

    private func scroll(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        table.backgroundColor = .textBackgroundColor
        return scroll
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        60
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 80
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === prompts { return store.candidates.count }
        return bubbles.count + (listener?.volatile.isEmpty == false ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === prompts {
            let id = NSUserInterfaceItemIdentifier("prompt")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PromptCell ?? PromptCell(identifier: id)
            let candidate = store.candidates[row]
            cell.title.stringValue = candidate.title
            cell.time.stringValue = label(for: candidate.spoken)
            cell.body.stringValue = candidate.prompt
            cell.quote.stringValue = "“\(candidate.quote)”"
            cell.toolTip = candidate.prompt
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("message")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MessageCell ?? MessageCell(identifier: id)
        if row < bubbles.count {
            let bubble = bubbles[row]
            cell.time.stringValue = label(for: bubble.start)
            cell.body.stringValue = bubble.text
            cell.body.textColor = .labelColor
            cell.used = bubble.segments.contains { usedSegments.contains($0.id) }
        } else {
            cell.time.stringValue = "now"
            cell.body.stringValue = listener?.volatile ?? ""
            cell.body.textColor = .secondaryLabelColor
            cell.used = false
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === prompts || row < bubbles.count
    }

    private func label(for date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dayFormatter.string(from: date)
    }
}

/// A prompt the model found: title and time, the rewrite, and the words it came from.
final class PromptCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    let quote = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .systemFont(ofSize: 10)
        time.textColor = .secondaryLabelColor
        body.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        body.maximumNumberOfLines = 8
        body.cell?.truncatesLastVisibleLine = true
        quote.font = .systemFont(ofSize: 10.5)
        quote.textColor = .tertiaryLabelColor
        quote.maximumNumberOfLines = 2
        quote.cell?.truncatesLastVisibleLine = true
        for sub in [title, time, body, quote] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        for label in [body, quote] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            quote.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 4),
            quote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            quote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            quote.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A message in the thread: its time on the left, the words on the right. A bar marks messages
/// a prompt came from.
final class MessageCell: NSTableCellView {
    let time = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    private let bar = NSView()

    var used = false { didSet { bar.isHidden = !used } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        body.font = .systemFont(ofSize: 13)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.layer?.cornerRadius = 1.5
        bar.isHidden = true
        for sub in [time, body, bar] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            time.firstBaselineAnchor.constraint(equalTo: body.firstBaselineAnchor),
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            time.widthAnchor.constraint(equalToConstant: 58),
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
