import AppKit

/// A list of saved texts, newest first, kept in a folder as one RTFD per entry plus an index.
/// Used for sent prompts (history) and for removed text (deleted).
public final class EntryStore {
    public struct Entry: Codable, Equatable {
        public let id: String
        public var date: Date
        public var preview: String
    }

    public private(set) var entries: [Entry] = []
    public let directory: URL
    public let limit: Int

    /// Texts added or changed since the last flush.
    private var pending: [String: NSAttributedString] = [:]
    private var indexDirty = false

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, limit: Int) {
        self.directory = directory
        self.limit = limit
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder.store.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    @discardableResult
    public func add(_ text: NSAttributedString, date: Date = Date()) -> String {
        let id = UUID().uuidString
        entries.insert(Entry(id: id, date: date, preview: Self.preview(of: text)), at: 0)
        pending[id] = NSAttributedString(attributedString: text)
        while entries.count > limit {
            let dropped = entries.removeLast()
            pending[dropped.id] = nil
            try? FileManager.default.removeItem(at: fileURL(dropped.id))
        }
        indexDirty = true
        return id
    }

    public func update(_ id: String, text: NSAttributedString, date: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].date = date
        entries[i].preview = Self.preview(of: text)
        pending[id] = NSAttributedString(attributedString: text)
        indexDirty = true
    }

    public func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        pending[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
        indexDirty = true
    }

    public func text(for id: String) -> NSAttributedString? {
        if let text = pending[id] { return text }
        return try? NSAttributedString(url: fileURL(id), options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                       documentAttributes: nil)
    }

    public func flush() {
        guard indexDirty || !pending.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (id, text) in pending {
            try? Self.writeRTFD(text, to: fileURL(id))
        }
        pending.removeAll()
        if indexDirty, let data = try? JSONEncoder.store.encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
        indexDirty = false
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).rtfd", isDirectory: true)
    }

    public static func writeRTFD(_ text: NSAttributedString, to url: URL) throws {
        let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    /// The first few lines, with images shown as "[image]" and blank lines squeezed out.
    public static func preview(of text: NSAttributedString) -> String {
        let lines = text.string
            .replacingOccurrences(of: "\u{FFFC}", with: "[image]")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.prefix(6).joined(separator: "\n").prefix(400))
    }
}

private extension JSONEncoder {
    static var store: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var store: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
