import AppKit

/// A row of browser-style tabs with a + at the end, after the pinned transcript tab. Tabs share
/// the width, each between `minWidth` and `maxWidth`; the selected one takes the editor's colour
/// so it joins the page.
@MainActor
final class TabBar: NSView {
    static let height: CGFloat = 32
    private static let minWidth: CGFloat = 70
    private static let maxWidth: CGFloat = 220
    private static let pinnedWidth: CGFloat = 44

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onSelectTranscript: (() -> Void)?

    /// The waveform shows while the microphone is on, a crossed-out mic while it isn't.
    var listening = false {
        didSet { pinned.symbolName = listening ? "waveform" : "mic.slash" }
    }

    private let pinned = TabItem(pinned: true)
    private var items: [TabItem] = []
    private let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!,
                                target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.isBordered = false
        plus.bezelStyle = .regularSquare
        plus.contentTintColor = .secondaryLabelColor
        plus.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        plus.toolTip = "New tab (⌘T)"
        plus.target = self
        plus.action = #selector(newClicked)
        addSubview(plus)
        pinned.symbolName = "mic.slash"
        pinned.toolTip = "Transcript (⌘⇧A)"
        pinned.onSelect = { [weak self] in self?.onSelectTranscript?() }
        addSubview(pinned)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `selected` is nil while the transcript tab is showing.
    func update(titles: [String], selected: Int?) {
        while items.count < titles.count {
            let item = TabItem()
            item.onSelect = { [weak self, weak item] in
                if let self, let item, let i = self.items.firstIndex(of: item) { self.onSelect?(i) }
            }
            item.onClose = { [weak self, weak item] in
                if let self, let item, let i = self.items.firstIndex(of: item) { self.onClose?(i) }
            }
            items.append(item)
            addSubview(item)
        }
        while items.count > titles.count {
            items.removeLast().removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            item.title = titles[i]
            item.number = i + 1
            item.isSelected = i == selected
        }
        pinned.isSelected = selected == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let plusWidth: CGFloat = 30
        let left: CGFloat = 8
        pinned.frame = NSRect(x: left, y: 4, width: Self.pinnedWidth, height: bounds.height - 4)
        let available = bounds.width - left - Self.pinnedWidth - plusWidth - 8
        let width = items.isEmpty ? 0 : min(Self.maxWidth, max(Self.minWidth, (available / CGFloat(items.count)).rounded(.down)))
        var x = left + Self.pinnedWidth
        for item in items {
            item.frame = NSRect(x: x, y: 4, width: width, height: bounds.height - 4)
            x += width
        }
        plus.frame = NSRect(x: min(x + 2, bounds.width - plusWidth), y: 5, width: plusWidth - 4, height: bounds.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func newClicked() { onNew?() }
}

private final class TabItem: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var title = "" {
        didSet {
            label.stringValue = title
            toolTip = title
        }
    }
    var number = 0
    var isSelected = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    /// Pinned tabs show an icon instead of a title and can't be closed.
    private let isPinned: Bool
    var symbolName: String? {
        didSet {
            icon.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: toolTip) }
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!,
                                 target: nil, action: nil)

    init(pinned: Bool = false) {
        isPinned = pinned
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.isHidden = !pinned
        label.isHidden = pinned
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close tab (⌘W)"
        addSubview(label)
        addSubview(icon)
        addSubview(close)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 6, dy: 4)
        let closeSize: CGFloat = 16
        close.frame = NSRect(x: bounds.width - closeSize - 8, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 12, y: (bounds.height - labelHeight) / 2, width: bounds.width - 12 - closeSize - 12, height: labelHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    /// Middle click closes, as in browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !isPinned { onClose?() }
    }

    private func refresh() {
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        close.isHidden = isPinned || !(isSelected || hovering)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 0)
        if isSelected {
            // Rounded on top, square at the bottom where it meets the editor.
            let path = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 8),
                                    xRadius: 7, yRadius: 7)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            NSColor.textBackgroundColor.setFill()
            NSRect(x: rect.minX + 0.5, y: rect.maxY - 1, width: rect.width - 1, height: 2).fill()
        } else {
            if hovering {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 3), xRadius: 6, yRadius: 6).fill()
            }
            // A thin divider between unselected tabs.
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 9, width: 1, height: bounds.height - 18).fill()
        }
    }

    @objc private func closeClicked() { onClose?() }
}
