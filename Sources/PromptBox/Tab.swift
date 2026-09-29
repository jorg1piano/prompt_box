import AppKit
import PromptBoxCore

/// One prompt. The editor shows one tab at a time by swapping in the tab's text storage, so each
/// tab keeps its own text, images, cursor, scroll position and undo stack.
@MainActor
final class Tab {
    let id: String
    let created: Date
    var lastActive: Date
    let storage: NSTextStorage
    let undoManager = UndoManager()
    var images: [Data]
    var selection: [NSValue] = [NSValue(range: NSRange(location: 0, length: 0))]
    var scrollOrigin: NSPoint = .zero
    /// Changed since it was last written to disk.
    var dirty = false

    init(id: String = UUID().uuidString, created: Date = Date(), lastActive: Date = Date(), prompt: Prompt,
         attributes: [NSAttributedString.Key: Any]) {
        self.id = id
        self.created = created
        self.lastActive = lastActive
        storage = NSTextStorage(string: prompt.text, attributes: attributes)
        images = prompt.images
        let end = (prompt.text as NSString).length
        selection = [NSValue(range: NSRange(location: end, length: 0))]
    }

    var prompt: Prompt { Prompt(text: storage.string, images: images) }

    var record: TabIndex.Record { TabIndex.Record(id: id, created: created, lastActive: lastActive) }

    /// The first non-empty line, else the image count, else "New prompt".
    var title: String {
        let string = storage.string
        var title: String?
        string.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                title = String(trimmed.prefix(80))
                stop = true
            }
        }
        if let title { return title }
        if !images.isEmpty { return images.count == 1 ? "1 image" : "\(images.count) images" }
        return "New prompt"
    }
}
