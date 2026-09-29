import AppKit
import PromptBoxCore

/// The list beside the editor: text removed from the editor, or prompts sent earlier.
@MainActor
final class Sidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    let table = SidebarTable()
    private let picker = NSSegmentedControl(labels: ["Deleted", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    private let history: EntryStore
    private let deleted: EntryStore
    private let dateFormatter = RelativeDateTimeFormatter()

    var onActivate: ((PromptWindow.SidebarMode, String) -> Void)?
    var onCancel: (() -> Void)?

    var mode: PromptWindow.SidebarMode = .deleted {
        didSet {
            picker.selectedSegment = mode.rawValue
            hint.stringValue = mode == .deleted ? "↩ insert at cursor   ⌫ forget   esc back" : "↩ open in a tab   ⌫ forget   esc back"
            reload()
            if !entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }

    private var store: EntryStore { mode == .deleted ? deleted : history }
    private var entries: [EntryStore.Entry] { store.entries }

    init(history: EntryStore, deleted: EntryStore) {
        self.history = history
        self.deleted = deleted
        super.init()
        dateFormatter.unitsStyle = .short
        dateFormatter.dateTimeStyle = .named

        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.selectedSegment = 0
        picker.segmentDistribution = .fillEqually

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in self?.activateSelected() }
        table.onDelete = { [weak self] in self?.forgetSelected() }
        table.onCancel = { [weak self] in self?.onCancel?() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        for sub in [separator, picker, scroll, hint] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])
        mode = .deleted
    }

    func focus() {
        table.window?.makeFirstResponder(table)
        if table.selectedRow < 0, !entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < table.numberOfRows ? table.selectedRow : nil
        table.reloadData()
        if let selected, !entries.isEmpty {
            table.selectRowIndexes([min(selected, entries.count - 1)], byExtendingSelection: false)
        }
    }

    @objc private func pickerChanged() {
        mode = PromptWindow.SidebarMode(rawValue: picker.selectedSegment) ?? .deleted
        focus()
    }

    @objc private func doubleClicked() { activateSelected() }

    private func activateSelected() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        onActivate?(mode, entries[row].id)
    }

    private func forgetSelected() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        store.remove(entries[row].id)
        store.flush()
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes([min(row, entries.count - 1)], byExtendingSelection: false) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? EntryCell ?? EntryCell(identifier: id)
        let entry = entries[row]
        cell.date.stringValue = dateFormatter.localizedString(for: entry.date, relativeTo: Date())
        cell.preview.stringValue = entry.preview
        cell.toolTip = entry.preview
        cell.thumbnail = entry.preview.contains("[image]")
            ? store.text(for: entry.id).flatMap { Prompt($0).images.first }.flatMap(NSImage.init(data:))
            : nil
        return cell
    }
}

final class EntryCell: NSTableCellView {
    let date = NSTextField(labelWithString: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    private let image = NSImageView()
    private var imageHeight: NSLayoutConstraint!

    /// The first image in the entry, shown under the text; nil hides it.
    var thumbnail: NSImage? {
        didSet {
            image.image = thumbnail
            image.isHidden = thumbnail == nil
            imageHeight.constant = thumbnail == nil ? 0 : 48
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.maximumNumberOfLines = 3
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        image.imageScaling = .scaleProportionallyDown
        image.imageAlignment = .alignLeft
        image.isHidden = true
        imageHeight = image.heightAnchor.constraint(equalToConstant: 0)
        for sub in [date, preview, image] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            date.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            date.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            preview.topAnchor.constraint(equalTo: date.bottomAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            image.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            image.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            imageHeight,
            image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A table that turns Return, Delete and Escape into callbacks.
final class SidebarTable: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 51, 117: onDelete?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
