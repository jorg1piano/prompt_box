import Foundation

/// A prompt the model found in the transcript: its rewrite, and the segments it came from.
public struct PromptCandidate: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let prompt: String
    public let segmentIDs: [String]
    /// When the first of its segments was said.
    public let spoken: Date
    /// The segments' own words, joined.
    public let quote: String

    public init(id: String = UUID().uuidString, title: String, prompt: String, segmentIDs: [String], spoken: Date, quote: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.segmentIDs = segmentIDs
        self.spoken = spoken
        self.quote = quote
    }
}

/// Turns transcript segments into prompts through `claude -p`: the input it reads, the schema
/// it answers in, and reading the answer back.
public enum PromptGrouping {
    /// About 16k tokens. Anything older than this in one pass is left out.
    public static let maxWords = 12_000

    public static let systemPrompt = """
    You read a transcript of everything a software developer's microphone picked up, and pull \
    out the prompts they meant for a coding agent such as Claude Code.

    The transcript is numbered segments with the time each was said. Most of it is not a \
    prompt: talking to people, phone calls, thinking out loud about unrelated things, and \
    other people's voices. Leave all of that out.

    Segments marked (speakers) are audio the computer was playing, such as a video or the other \
    side of a call, that the microphone picked up. They are never the developer: don't make \
    prompts from them, though they can explain what the developer is reacting to. Segments \
    marked (partly speakers) mix the two; use only the words that aren't from the audio. \
    A prompt is a request, instruction, bug \
    report or idea about code or a task the developer would hand to an agent.

    Group segments that are about the same task into one prompt, even when other talk sits \
    between them. Rewrite each prompt as the developer would have typed it: first person, \
    direct, with every concrete detail kept (file names, function names, numbers, error text, \
    the order of steps). Keep numbers, units and names exactly as said: never convert or \
    "correct" them. Drop filler words, false starts and repetition. Fix words the speech \
    recognizer clearly got wrong when the context makes the right word obvious. Do not add \
    requirements, steps or details that were not said. If a prompt is one sentence, keep it \
    one sentence.

    Give each prompt a title of at most 8 words, and list the segment numbers it came from. \
    Return an empty list when nothing in the transcript is a prompt.
    """

    public static let schema = """
    {"type":"object","properties":{"prompts":{"type":"array","items":{"type":"object","properties":{\
    "title":{"type":"string"},"prompt":{"type":"string"},\
    "segments":{"type":"array","items":{"type":"integer"}}},\
    "required":["title","prompt","segments"]}}},"required":["prompts"]}
    """

    /// The newest segments that fit in `maxWords`, oldest first.
    public static func limit(_ segments: [TranscriptSegment], maxWords: Int = maxWords) -> [TranscriptSegment] {
        var words = 0
        var kept: [TranscriptSegment] = []
        for segment in segments.reversed() {
            words += segment.wordCount
            if words > maxWords, !kept.isEmpty { break }
            kept.append(segment)
        }
        return kept.reversed()
    }

    /// `[1] 10:02:13 okay so the sidebar overlaps…`, one segment per line, with `(speakers)` or
    /// `(partly speakers)` after the time when `echo` says the speakers played those words.
    public static func input(for segments: [TranscriptSegment], echo: [String: Double] = [:], calendar: Calendar = .current) -> String {
        segments.enumerated().map { i, segment in
            let t = calendar.dateComponents([.hour, .minute, .second], from: segment.start)
            let score = echo[segment.id] ?? 0
            let mark = score >= EchoMatch.echo ? "(speakers) " : score >= EchoMatch.partial ? "(partly speakers) " : ""
            return String(format: "[%d] %02d:%02d:%02d ", i + 1, t.hour!, t.minute!, t.second!) + mark + segment.text
        }.joined(separator: "\n")
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Reads `claude -p --output-format json --json-schema …` output. Segment numbers are
    /// 1-based indexes into `segments`; ones out of range are dropped.
    public static func candidates(fromCLIOutput data: Data, segments: [TranscriptSegment]) throws -> [PromptCandidate] {
        struct Output: Decodable {
            struct Answer: Decodable {
                struct Item: Decodable {
                    let title: String
                    let prompt: String
                    let segments: [Int]
                }
                let prompts: [Item]
            }
            let is_error: Bool?
            let result: String?
            let structured_output: Answer?
        }
        let output: Output
        do {
            output = try JSONDecoder().decode(Output.self, from: data)
        } catch {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure(message: "Unreadable answer from claude: \(text)")
        }
        guard output.is_error != true, let answer = output.structured_output else {
            throw Failure(message: output.result ?? "claude returned no prompts")
        }
        return answer.prompts.compactMap { item in
            let used = Array(Set(item.segments.filter { $0 >= 1 && $0 <= segments.count })).sorted().map { segments[$0 - 1] }
            let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !used.isEmpty, !prompt.isEmpty else { return nil }
            return PromptCandidate(title: item.title.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
                                   segmentIDs: used.map(\.id), spoken: used[0].start, quote: used.map(\.text).joined(separator: " "))
        }
    }
}

/// The prompts waiting in the transcript tab, and how far into the transcript the last pass read.
public final class CandidateStore {
    private struct State: Codable {
        var candidates: [PromptCandidate]
        var processedThrough: Date?
    }

    public let url: URL
    public private(set) var candidates: [PromptCandidate] = []
    /// The end of the newest segment an automatic pass has read.
    public var processedThrough: Date? { didSet { save() } }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let state = try? JSONDecoder.transcript.decode(State.self, from: data) {
            candidates = state.candidates
            processedThrough = state.processedThrough
        }
    }

    /// Newest first.
    public func add(_ new: [PromptCandidate]) {
        candidates.insert(contentsOf: new.sorted { $0.spoken > $1.spoken }, at: 0)
        save()
    }

    public func remove(_ id: String) {
        candidates.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.transcript.encode(State(candidates: candidates, processedThrough: processedThrough)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
