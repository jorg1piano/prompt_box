import AppKit

/// Open tabs on disk: `index.json` holds their order and which one is selected, and each tab's
/// prompt is `<id>.rtfd` next to it.
public struct TabIndex: Codable, Equatable {
    public struct Record: Codable, Equatable {
        public let id: String
        public var created: Date
        public var lastActive: Date

        public init(id: String, created: Date, lastActive: Date) {
            self.id = id
            self.created = created
            self.lastActive = lastActive
        }
    }

    public var tabs: [Record]
    public var selected: String?

    public init(tabs: [Record], selected: String?) {
        self.tabs = tabs
        self.selected = selected
    }
}

public struct TabFiles {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func promptURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).rtfd", isDirectory: true)
    }

    public func loadIndex() -> TabIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TabIndex.self, from: data)
    }

    public func save(_ index: TabIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    public func loadPrompt(_ id: String) -> Prompt? {
        guard let text = try? NSAttributedString(url: promptURL(id), options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                 documentAttributes: nil) else { return nil }
        return Prompt(text)
    }

    public func save(_ prompt: Prompt, id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EntryStore.writeRTFD(prompt.attributed, to: promptURL(id))
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: promptURL(id))
    }
}
