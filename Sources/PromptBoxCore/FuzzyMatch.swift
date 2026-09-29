import Foundation

/// Scores how well a typed query matches a text, forgiving partial words and small typos.
///
/// The query splits into words, and every query word must match some word of the text:
/// exactly (1.0), as a prefix ("resp" in "response", 0.9), inside a word ("side" in "outside",
/// 0.75), or within an edit distance that grows with the word's length ("sidbar" or "sidebra" for
/// "sidebar", 0.65, then 0.5 for two edits). Query words of four letters or more may have one
/// edit, eight or more two. As a last resort the letters may appear in order close together
/// ("rspns" in "response", 0.35). The score is the mean over the query words, plus a bonus when
/// the whole query appears as typed.
public enum FuzzyMatch {
    public struct Match: Equatable {
        public let score: Double
        /// Where the first query word matched, in the text's UTF-16 offsets.
        public let range: NSRange
    }

    public static func match(_ query: String, in text: String) -> Match? {
        let tokens = self.tokens(query)
        guard !tokens.isEmpty else { return nil }
        let words = self.words(in: text)
        let foldedText = fold(text)

        var total = 0.0
        var firstRange: NSRange?
        for token in tokens {
            var best: (score: Double, range: NSRange)?
            for word in words {
                guard let score = score(token: token, word: word.chars), score > (best?.score ?? 0) else { continue }
                best = (score, word.range)
                if score == 1 { break }
            }
            if best == nil, let range = subsequence(token, in: text) {
                best = (0.35, range)
            }
            guard let found = best else { return nil }
            total += found.score
            if firstRange == nil { firstRange = found.range }
        }
        var score = total / Double(tokens.count)
        let phrase = fold(query).trimmingCharacters(in: .whitespaces)
        if tokens.count > 1, foldedText.contains(phrase) { score += 0.15 }
        return Match(score: score, range: firstRange!)
    }

    // MARK: - Pieces

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func tokens(_ query: String) -> [[Character]] {
        fold(query).split { !$0.isLetter && !$0.isNumber }.map { Array($0) }
    }

    static func words(in text: String) -> [(chars: [Character], range: NSRange)] {
        var result: [(chars: [Character], range: NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            if let word { result.append((Array(fold(word)), range)) }
        }
        return result
    }

    static func score(token q: [Character], word w: [Character]) -> Double? {
        if w == q { return 1 }
        if w.starts(with: q) { return 0.9 }
        if q.count >= 3, w.count > q.count, contains(w, q) { return 0.75 }
        let allowed = q.count >= 8 ? 2 : (q.count >= 4 ? 1 : 0)
        guard allowed > 0, abs(w.count - q.count) <= allowed || w.count > q.count else { return nil }
        var distance = editDistance(q, w)
        // A word still being typed: compare against the start of the longer word.
        if w.count > q.count {
            distance = min(distance, editDistance(q, Array(w.prefix(q.count))), editDistance(q, Array(w.prefix(q.count + 1))))
        }
        guard distance <= allowed else { return nil }
        return distance == 1 ? 0.65 : 0.5
    }

    private static func contains(_ haystack: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start..<start + needle.count].elementsEqual(needle) {
            return true
        }
        return false
    }

    /// Optimal string alignment distance: insertions, deletions, substitutions and swaps of
    /// neighbouring letters each cost one.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    /// The query word's letters in order, spanning at most four times its length.
    static func subsequence(_ token: [Character], in text: String) -> NSRange? {
        guard token.count >= 3 else { return nil }
        let chars = Array(fold(text))
        guard chars.count == text.count else { return nil }
        for start in chars.indices where chars[start] == token[0] {
            var t = 1
            var i = start + 1
            while t < token.count, i < chars.count, i - start < token.count * 4 {
                if chars[i] == token[t] { t += 1 }
                i += 1
            }
            if t == token.count {
                let lower = text.index(text.startIndex, offsetBy: start)
                let upper = text.index(text.startIndex, offsetBy: i)
                return NSRange(lower..<upper, in: text)
            }
        }
        return nil
    }
}
