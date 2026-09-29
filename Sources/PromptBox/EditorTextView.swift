import AppKit
import PromptBoxCore
import UniformTypeIdentifiers

/// The prompt editor: plain text only. Images pasted or dropped in go to `onImages`, which puts
/// them in the strip under the editor instead of the text.
final class EditorTextView: NSTextView {
    var onImages: (([Data]) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL, .string, .png, .tiff] }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        insertContents(of: pboard)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        insertContents(of: pboard)
    }

    /// Picks what to take from a pasteboard, in this order: files (images to the strip, anything
    /// else as its path), plain text, then raw image data. Text comes before image data because
    /// apps like Numbers put a picture of the copied text on the pasteboard as well.
    private func insertContents(of pboard: NSPasteboard) -> Bool {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var images: [Data] = []
            var paths: [String] = []
            for url in urls {
                let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) ?? false
                if isImage, let data = try? Data(contentsOf: url), let png = PromptExport.pngData(from: data) {
                    images.append(png)
                } else {
                    paths.append(url.path)
                }
            }
            if !paths.isEmpty { insertText(paths.joined(separator: " "), replacementRange: selectedRange()) }
            if !images.isEmpty { onImages?(images) }
            return true
        }
        if let string = pboard.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
            return true
        }
        if let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff), let png = PromptExport.pngData(from: data) {
            onImages?([png])
            return true
        }
        return false
    }

    /// Deletes every line the selection touches, like ⌘⇧K in VS Code.
    @objc func deleteLines(_ sender: Any?) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard range.length > 0 else { return }
        insertText("", replacementRange: range)
    }
}
