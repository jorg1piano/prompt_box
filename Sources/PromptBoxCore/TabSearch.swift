import Foundation

/// Ranks tabs for the ⌘K switcher.
public enum TabSearch {
    public struct Candidate {
        public let id: String
        public let title: String
        public let text: String
        public let lastActive: Date

        public init(id: String, title: String, text: String, lastActive: Date) {
            self.id = id
            self.title = title
            self.text = text
            self.lastActive = lastActive
        }
    }

    public struct Hit: Equatable {
        public let id: String
        public let title: String
        /// The line where the query matched, or the tab's second line when it matched the title.
        public let snippet: String
    }

    /// An empty query keeps the candidates' order. Otherwise tabs that match rank by score, with a
    /// bonus for matching the title, then by most recently used.
    public static func rank(_ query: String, among candidates: [Candidate]) -> [Hit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return candidates.map { Hit(id: $0.id, title: $0.title, snippet: secondLine(of: $0.text)) }
        }
        var scored: [(hit: Hit, score: Double, date: Date)] = []
        for candidate in candidates {
            let title = FuzzyMatch.match(query, in: candidate.title)
            let body = FuzzyMatch.match(query, in: candidate.text)
            let titleScore = title.map { $0.score + 0.15 } ?? 0
            let best = max(titleScore, body?.score ?? 0)
            guard best > 0 else { continue }
            let snippet: String
            if let body, titleScore < body.score {
                snippet = line(around: body.range, in: candidate.text)
            } else {
                snippet = secondLine(of: candidate.text)
            }
            let shown = snippet == candidate.title ? secondLine(of: candidate.text) : snippet
            scored.append((Hit(id: candidate.id, title: candidate.title, snippet: shown), best, candidate.lastActive))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
        return scored.map(\.hit)
    }

    static func secondLine(of text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.count > 1 ? String(lines[1].prefix(120)) : ""
    }

    /// The line holding `range`, cut to about 100 characters around the match.
    static func line(around range: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard range.location + range.length <= ns.length else { return "" }
        let lineRange = ns.lineRange(for: range)
        let start = max(lineRange.location, range.location - 40)
        let end = min(lineRange.location + lineRange.length, start + 100)
        var result = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > lineRange.location { result = "…" + result }
        if end < lineRange.location + lineRange.length { result += "…" }
        return result
    }
}
