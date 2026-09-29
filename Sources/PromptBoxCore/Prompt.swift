import AppKit

/// What the editor holds: plain text plus the images listed under it.
///
/// Stored (draft, history, deleted log) as one attributed string: the text followed by the images
/// as attachments. Reading one back takes every attachment out as an image wherever it sits, so
/// old drafts with inline images load too.
public struct Prompt: Equatable {
    public var text: String
    /// PNG data, in the order shown.
    public var images: [Data]

    public init(text: String = "", images: [Data] = []) {
        self.text = text
        self.images = images
    }

    public init(_ attributed: NSAttributedString) {
        var text = ""
        var images: [Data] = []
        let source = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                if let png = PromptExport.pngData(of: attachment) { images.append(png) }
            } else {
                text += source.substring(with: range)
            }
        }
        self.init(text: text.replacingOccurrences(of: "\u{FFFC}", with: ""), images: images)
    }

    public var attributed: NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        for png in images {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "image.png"
            result.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        }
        return result
    }

    public var isEmpty: Bool {
        images.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
