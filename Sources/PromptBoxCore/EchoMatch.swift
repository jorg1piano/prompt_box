import Foundation

/// Finds microphone segments that are really the Mac's speakers: a video or a call the
/// microphone picked up. Both are transcribed separately, so a microphone segment whose words
/// the speakers were playing at the same time is an echo.
public enum EchoMatch {
    /// A score from here up means the segment is the speakers.
    public static let echo = 0.5
    /// From here up to `echo`, the segment mixes your words with the speakers'.
    public static let partial = 0.25

    /// For each microphone segment that overlaps speaker audio, the share of its words the
    /// speakers played within `slack` seconds of it. Segments with no speaker audio near them are
    /// left out.
    public static func scores(mic: [TranscriptSegment], speakers: [TranscriptSegment], slack: TimeInterval = 3) -> [String: Double] {
        let played = speakers.sorted { $0.start < $1.start }
        var scores: [String: Double] = [:]
        var first = 0
        for segment in mic.sorted(by: { $0.start < $1.start }) {
            let from = segment.start.addingTimeInterval(-slack), to = segment.end.addingTimeInterval(slack)
            // Speaker segments are sorted by start, so ones that ended long before this segment
            // can be skipped for every later segment too. Segments rarely run over a minute.
            while first < played.count, played[first].end < from.addingTimeInterval(-60) { first += 1 }
            let near = played[first...].prefix { $0.start <= to }.filter { $0.end >= from }
            guard !near.isEmpty else { continue }
            scores[segment.id] = score(segment.text, against: near.map(\.text).joined(separator: " "))
        }
        return scores
    }

    /// The share of word pairs in `text` that also occur in `played` (or of its one word, for a
    /// one-word segment). Pairs keep short common words like "the" from matching on their own.
    public static func score(_ text: String, against played: String) -> Double {
        let said = words(text), heard = words(played)
        guard !said.isEmpty, !heard.isEmpty else { return 0 }
        guard said.count > 1 else { return heard.contains(said[0]) ? 1 : 0 }
        let heardPairs = Set(pairs(heard))
        let saidPairs = pairs(said)
        return Double(saidPairs.filter(heardPairs.contains).count) / Double(saidPairs.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { $0.replacingOccurrences(of: "'", with: "") }
    }

    private static func pairs(_ words: [String]) -> [String] {
        zip(words, words.dropFirst()).map { "\($0) \($1)" }
    }
}
