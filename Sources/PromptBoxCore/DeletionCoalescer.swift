import Foundation

/// Decides whether a deletion starts a new entry in the deleted log or extends the one before it.
///
/// Holding backspace over a word sends one deletion per character. Each one ends where the previous
/// one began, so they join into a single entry ("hello", not "o", "l", "l", "e", "h"). Forward
/// deletes join the same way from the other side. Any insertion, a pause longer than `window`, or a
/// deletion somewhere else starts a fresh entry.
public struct DeletionCoalescer {
    public enum Decision: Equatable {
        /// Nothing worth keeping was removed.
        case ignore
        case newEntry
        /// The removed text sits before the open entry's text (backspace).
        case prepend
        /// The removed text sits after the open entry's text (forward delete).
        case append
    }

    public var window: TimeInterval

    /// Where the text closed up after the last logged deletion, while an entry is open.
    private var joinPoint: Int?
    private var lastDate: Date?

    public init(window: TimeInterval = 4) {
        self.window = window
    }

    public mutating func reset() {
        joinPoint = nil
        lastDate = nil
    }

    /// `range` is the span being replaced, in UTF-16 units, and `deletedText` its current contents.
    public mutating func record(range: NSRange, deletedText: String, replacementLength: Int, at date: Date) -> Decision {
        guard range.length > 0 else {
            if replacementLength > 0 { reset() }
            return .ignore
        }
        let meaningful = !deletedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Typing over a selection removes the selection: keep it, but don't let later deletions join it.
        if replacementLength > 0 {
            reset()
            return meaningful ? .newEntry : .ignore
        }

        let recent = lastDate.map { date.timeIntervalSince($0) <= window } ?? false
        if recent, let join = joinPoint {
            if range.location + range.length == join {
                joinPoint = range.location
                lastDate = date
                return .prepend
            }
            if range.location == join {
                lastDate = date
                return .append
            }
        }

        guard meaningful else {
            reset()
            return .ignore
        }
        joinPoint = range.location
        lastDate = date
        return .newEntry
    }
}
