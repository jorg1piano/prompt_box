import AppKit
import PromptBoxCore

/// The ⌘K panel: a search field over a list of tabs, ranked by `TabSearch` as you type. The best
/// match is highlighted; ↑/↓ (or ⌃P/⌃N) move, Return switches, Esc or a click outside closes.
@MainActor
final class TabSwitcher: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view = Overlay()
    private let box = NSView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "No tabs match")
    private var tableHeight: NSLayoutConstraint!
    private var hits: [TabSearch.Hit] = []

    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 8

    /// Tabs to search, in the order to list them for an empty query.
    var candidates: (() -> [TabSearch.Candidate])?
    var onChoose: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    var isOpen: Bool { !view.isHidden }

    override init() {
        super.init()
        view.isHidden = true
        view.onClickOutside = { [weak self] in self?.dismiss() }

        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        box.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
        view.box = box

        field.placeholderString = "Search tabs"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let separator = NSBox()
        separator.boxType = .separator

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.isHidden = true

        for sub in [field, separator, scroll, empty] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(sub)
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(box)
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        let width = box.widthAnchor.constraint(equalToConstant: 560)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width,
            box.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.topAnchor.constraint(equalTo: view.topAnchor, constant: 76),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            tableHeight,
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
        ])
    }

    func open(query: String = "") {
        field.stringValue = query
        view.isHidden = false
        refresh()
        view.window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard isOpen else { return }
        view.isHidden = true
        onDismiss?()
    }

    private func refresh() {
        hits = TabSearch.rank(field.stringValue, among: candidates?() ?? [])
        table.reloadData()
        empty.isHidden = !hits.isEmpty
        tableHeight.constant = Self.rowHeight * CGFloat(max(1, min(hits.count, Self.visibleRows)))
        if !hits.isEmpty { select(0) }
    }

    private func select(_ row: Int) {
        guard !hits.isEmpty else { return }
        let row = min(max(0, row), hits.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func choose() {
        let row = table.selectedRow
        guard row >= 0, row < hits.count else { return }
        let id = hits[row].id
        dismiss()
        onChoose?(id)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        select(table.clickedRow)
        choose()
    }

    // MARK: - Field

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("hit")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HitCell ?? HitCell(identifier: id)
        cell.title.stringValue = hits[row].title
        cell.snippet.stringValue = hits[row].snippet
        return cell
    }
}

/// Dims the window behind the switcher and closes it on a click outside the box.
final class Overlay: NSView {
    weak var box: NSView?
    var onClickOutside: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        if let box, box.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        onClickOutside?()
    }
}

private final class HitCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let snippet = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .medium)
        snippet.font = .systemFont(ofSize: 11)
        snippet.textColor = .secondaryLabelColor
        for label in [title, snippet] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            snippet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
