import AppKit
import PromptBoxCore

/// The row of small numbered thumbnails under the editor. Each has a × that removes it;
/// double-clicking one opens it in Preview. Hidden while there are no images.
@MainActor
final class ImageStrip: NSView {
    static let thumbHeight: CGFloat = 56

    private(set) var images: [Data] = []
    /// Called when the × on a thumbnail is clicked, with the image's index.
    var onRemove: ((Int) -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.thumbHeight + 20),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ images: [Data]) {
        self.images = images
        rebuild()
    }

    func insert(_ png: Data, at index: Int) {
        images.insert(png, at: min(index, images.count))
        rebuild()
    }

    @discardableResult
    func remove(at index: Int) -> Data {
        let png = images.remove(at: index)
        rebuild()
        return png
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, png) in images.enumerated() {
            let thumb = Thumbnail(png: png, number: i + 1, height: Self.thumbHeight)
            thumb.onRemove = { [weak self] in self?.onRemove?(i) }
            stack.addArrangedSubview(thumb)
        }
        isHidden = images.isEmpty
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One image: scaled to the strip height (and at most 2.5 times as wide), with its number in the
/// bottom left and a remove button in the top right.
private final class Thumbnail: NSView {
    var onRemove: (() -> Void)?
    private let png: Data

    init(png: Data, number: Int, height: CGFloat) {
        self.png = png
        super.init(frame: .zero)
        let image = NSImage(data: png) ?? NSImage()
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let width = min(height * 2.5, max(height * 0.6, height * aspect))
        if image.size.width > 0 { toolTip = "\(Int(image.size.width))×\(Int(image.size.height)) · double-click to open" }

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor

        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        badge.layer?.cornerRadius = 4

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove image")!,
                             target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = .white
        close.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        close.target = self
        close.action = #selector(removeClicked)
        close.wantsLayer = true
        close.layer?.shadowOpacity = 0.6
        close.layer?.shadowRadius = 2
        close.layer?.shadowOffset = .zero

        for view in [imageView, badge, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width.rounded()),
            heightAnchor.constraint(equalToConstant: height),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])

        let open = NSClickGestureRecognizer(target: self, action: #selector(openInPreview))
        open.numberOfClicksRequired = 2
        addGestureRecognizer(open)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked() { onRemove?() }

    @objc private func openInPreview() {
        if let url = try? PromptExport.store(png: png, in: Paths.images) { NSWorkspace.shared.open(url) }
    }
}
