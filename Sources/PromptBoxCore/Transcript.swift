import Foundation

/// One stretch of speech the transcriber finished, with wall-clock times.
public struct TranscriptSegment: Codable, Equatable, Identifiable {
    /// What the microphone heard, or what the Mac itself played (videos, calls), which is only
    /// used to tell which microphone segments were the speakers rather than you.
    public enum Source: String, Codable {
        case mic
        case speakers
    }

    public let id: String
    public let start: Date
    public let end: Date
    public let text: String
    public let source: Source

    public init(id: String = UUID().uuidString, start: Date, end: Date, text: String, source: Source = .mic) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.source = source
    }

    /// Lines written before speakers were recorded have no source; they're all microphone.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .mic
    }

    public var wordCount: Int { text.split { $0.isWhitespace }.count }
}

/// Everything the microphone heard, one JSON line per segment in a file per local day
/// (`2026-09-30.jsonl`). Nothing is ever deleted.
public final class TranscriptLog {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func append(_ segment: TranscriptSegment) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = try JSONEncoder.transcript.encode(segment)
        line.append(0x0A)
        let url = fileURL(for: segment.start)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    /// Segments that started at or after `date`, oldest first.
    public func segments(since date: Date, now: Date = Date()) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var day = Calendar.current.startOfDay(for: date)
        while day <= now {
            if let data = try? Data(contentsOf: fileURL(for: day)) {
                for line in data.split(separator: 0x0A) {
                    if let segment = try? JSONDecoder.transcript.decode(TranscriptSegment.self, from: line), segment.start >= date {
                        result.append(segment)
                    }
                }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        return result.sorted { $0.start < $1.start }
    }

    public func fileURL(for date: Date) -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d.jsonl", parts.year!, parts.month!, parts.day!)
        return directory.appendingPathComponent(name)
    }
}

/// Segments said close together, shown as one message in the thread.
public struct TranscriptBubble: Equatable {
    public var segments: [TranscriptSegment]

    public var start: Date { segments[0].start }
    public var end: Date { segments[segments.count - 1].end }
    public var text: String { segments.map(\.text).joined(separator: " ") }
}

public enum TranscriptThread {
    /// Starts a new bubble whenever the speaker paused for more than `gap` seconds.
    public static func bubbles(_ segments: [TranscriptSegment], gap: TimeInterval = 10) -> [TranscriptBubble] {
        var bubbles: [TranscriptBubble] = []
        for segment in segments {
            if let last = bubbles.last, segment.start.timeIntervalSince(last.end) <= gap {
                bubbles[bubbles.count - 1].segments.append(segment)
            } else {
                bubbles.append(TranscriptBubble(segments: [segment]))
            }
        }
        return bubbles
    }
}

extension JSONEncoder {
    static var transcript: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractional.string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var transcript: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
