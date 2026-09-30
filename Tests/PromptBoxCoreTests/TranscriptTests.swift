import XCTest
@testable import PromptBoxCore

final class TranscriptTests: XCTestCase {
    var dir: URL!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func segment(_ offset: TimeInterval, _ text: String, length: TimeInterval = 2) -> TranscriptSegment {
        TranscriptSegment(start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + length), text: text)
    }

    func testLogAppendsAndReadsAcrossDays() throws {
        let log = TranscriptLog(directory: dir)
        let today = segment(0, "fix the sidebar")
        let tomorrow = segment(86_400, "add a test")
        try log.append(today)
        try log.append(tomorrow)
        try log.append(segment(5, "also the tab bar"))

        let all = log.segments(since: t0.addingTimeInterval(-60), now: t0.addingTimeInterval(90_000))
        XCTAssertEqual(all.map(\.text), ["fix the sidebar", "also the tab bar", "add a test"])
        XCTAssertEqual(all[0], today)
        XCTAssertEqual(log.segments(since: t0.addingTimeInterval(1), now: t0.addingTimeInterval(90_000)).map(\.text),
                       ["also the tab bar", "add a test"])
        XCTAssertNotEqual(log.fileURL(for: today.start), log.fileURL(for: tomorrow.start))
    }

    func testBubblesSplitOnPauses() {
        let segments = [segment(0, "a"), segment(5, "b"), segment(30, "c"), segment(43, "d")]
        let bubbles = TranscriptThread.bubbles(segments, gap: 10)
        XCTAssertEqual(bubbles.map(\.text), ["a b", "c", "d"])
        XCTAssertEqual(bubbles[0].end, t0.addingTimeInterval(7))
    }

    func testLimitKeepsNewestWords() {
        let segments = [segment(0, "one two three"), segment(10, "four five"), segment(20, "six")]
        XCTAssertEqual(PromptGrouping.limit(segments, maxWords: 3).map(\.text), ["four five", "six"])
        XCTAssertEqual(PromptGrouping.limit(segments, maxWords: 100).count, 3)
        // A single segment over the limit still goes through.
        XCTAssertEqual(PromptGrouping.limit([segments[0]], maxWords: 1).count, 1)
    }

    func testInputNumbersSegments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let input = PromptGrouping.input(for: [segment(0, "fix it"), segment(65, "thanks")], calendar: calendar)
        XCTAssertEqual(input, "[1] 14:13:20 fix it\n[2] 14:14:25 thanks")
    }

    func testCandidatesFromCLIOutput() throws {
        let segments = [segment(0, "the sidebar overlaps"), segment(5, "lunch?"), segment(9, "collapse it under 600")]
        let json = """
        {"type":"result","is_error":false,"result":"","structured_output":{"prompts":[
          {"title":"Fix sidebar","prompt":" Collapse the sidebar under 600pt. ","segments":[3,1,1,9]},
          {"title":"Empty","prompt":"x","segments":[42]}
        ]}}
        """
        let candidates = try PromptGrouping.candidates(fromCLIOutput: Data(json.utf8), segments: segments)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].prompt, "Collapse the sidebar under 600pt.")
        XCTAssertEqual(candidates[0].segmentIDs, [segments[0].id, segments[2].id])
        XCTAssertEqual(candidates[0].spoken, segments[0].start)
        XCTAssertEqual(candidates[0].quote, "the sidebar overlaps collapse it under 600")
    }

    func testCLIErrorSurfaces() {
        let json = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try PromptGrouping.candidates(fromCLIOutput: Data(json.utf8), segments: [])) { error in
            XCTAssertEqual(error.localizedDescription, "Not logged in")
        }
    }

    func testCandidateStoreRoundTrips() {
        let url = dir.appendingPathComponent("candidates.json")
        let store = CandidateStore(url: url)
        let old = PromptCandidate(title: "old", prompt: "a", segmentIDs: ["1"], spoken: t0, quote: "a")
        let new = PromptCandidate(title: "new", prompt: "b", segmentIDs: ["2"], spoken: t0.addingTimeInterval(60), quote: "b")
        store.add([old, new])
        store.processedThrough = t0.addingTimeInterval(62.5)

        let reloaded = CandidateStore(url: url)
        XCTAssertEqual(reloaded.candidates.map(\.title), ["new", "old"])
        XCTAssertEqual(reloaded.processedThrough, t0.addingTimeInterval(62.5))
        reloaded.remove(new.id)
        XCTAssertEqual(CandidateStore(url: url).candidates.map(\.title), ["old"])
    }
}
