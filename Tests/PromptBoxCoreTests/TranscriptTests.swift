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
        XCTAssertEqual(PromptSuggestion.limit(segments, maxWords: 3).map(\.text), ["four five", "six"])
        XCTAssertEqual(PromptSuggestion.limit(segments, maxWords: 100).count, 3)
        // A single segment over the limit still goes through.
        XCTAssertEqual(PromptSuggestion.limit([segments[0]], maxWords: 1).count, 1)
    }

    func testRecentCountsBackFromTheNewestSegment() {
        // Said an hour ago and 6 and 2 minutes before the newest segment.
        let segments = [segment(-3600, "old"), segment(0, "six minutes"), segment(240, "two minutes"), segment(360, "newest")]
        XCTAssertEqual(PromptSuggestion.recent(segments, minutes: 5).map(\.text), ["two minutes", "newest"])
        XCTAssertEqual(PromptSuggestion.recent([], minutes: 5), [])
    }

    func testInputNumbersSegments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let input = PromptSuggestion.input(for: [segment(0, "fix it"), segment(65, "thanks")], calendar: calendar)
        XCTAssertEqual(input, "[1] 14:13:20 fix it\n[2] 14:14:25 thanks")
    }

    func testSuggestionFromCLIOutput() throws {
        let segments = [segment(0, "the sidebar overlaps"), segment(5, "lunch?"), segment(9, "collapse it under 600")]
        let json = """
        {"type":"result","is_error":false,"result":"","structured_output":{
          "prompt":" Collapse the sidebar under 600pt. ","segments":[3,1,1,9]}}
        """
        let suggestion = try PromptSuggestion.suggestion(fromCLIOutput: Data(json.utf8), segments: segments)
        XCTAssertEqual(suggestion.text, "Collapse the sidebar under 600pt.")
        XCTAssertEqual(suggestion.segmentIDs, [segments[0].id, segments[2].id])
        XCTAssertEqual(suggestion.through, segments[2].end)
        XCTAssertFalse(suggestion.edited)
    }

    func testCLIErrorSurfaces() {
        let json = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try PromptSuggestion.suggestion(fromCLIOutput: Data(json.utf8), segments: [])) { error in
            XCTAssertEqual(error.localizedDescription, "Not logged in")
        }
    }

    func testSuggestionStoreRoundTrips() {
        let url = dir.appendingPathComponent("suggestion.json")
        let store = SuggestionStore(url: url)
        XCTAssertEqual(store.suggestion, Suggestion())
        store.suggestion = Suggestion(text: "Fix it", segmentIDs: ["a"], through: t0.addingTimeInterval(62.5), edited: true)
        XCTAssertEqual(SuggestionStore(url: url).suggestion, store.suggestion)
    }
}

final class EchoMatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func segment(_ offset: TimeInterval, _ text: String, _ source: TranscriptSegment.Source = .mic) -> TranscriptSegment {
        TranscriptSegment(start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + 3), text: text, source: source)
    }

    func testVideoPickedUpByTheMicIsAnEcho() {
        let mic = segment(0.8, "In today's video we look at the best keyboards of 2026.")
        let speakers = segment(0, "in today's video, we look at the best keyboards of twenty twenty six", .speakers)
        let scores = EchoMatch.scores(mic: [mic], speakers: [speakers])
        XCTAssertGreaterThanOrEqual(scores[mic.id]!, EchoMatch.echo)
    }

    func testTalkingOverAVideoIsNotAnEcho() {
        let mic = segment(1, "fix the sidebar in the settings screen")
        let speakers = segment(0, "the best keyboard in the world is the one you use", .speakers)
        XCTAssertLessThan(EchoMatch.scores(mic: [mic], speakers: [speakers])[mic.id]!, EchoMatch.partial)
    }

    func testMixedSegmentIsPartial() {
        let score = EchoMatch.score("wow the best mechanical keyboards ever okay fix the sidebar overlap now",
                                    against: "the best mechanical keyboards ever made")
        XCTAssertGreaterThanOrEqual(score, EchoMatch.partial)
        XCTAssertLessThan(score, EchoMatch.echo)
    }

    func testSpeakerAudioAtAnotherTimeDoesNotCount() {
        let mic = segment(100, "the best keyboards of 2026")
        let speakers = segment(0, "the best keyboards of 2026", .speakers)
        XCTAssertNil(EchoMatch.scores(mic: [mic], speakers: [speakers])[mic.id])
    }

    func testInputMarksSpeakers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let a = segment(0, "fix it"), b = segment(5, "subscribe"), c = segment(9, "mixed")
        let input = PromptSuggestion.input(for: [a, b, c], echo: [b.id: 0.9, c.id: 0.3], calendar: calendar)
        XCTAssertEqual(input, "[1] 14:13:20 fix it\n[2] 14:13:25 (speakers) subscribe\n[3] 14:13:29 (partly speakers) mixed")
    }

    func testOldLinesDecodeAsMic() throws {
        let line = #"{"end":"2026-09-30T01:20:39.744Z","id":"x","start":"2026-09-30T01:20:36.504Z","text":"hi"}"#
        let segment = try JSONDecoder.transcript.decode(TranscriptSegment.self, from: Data(line.utf8))
        XCTAssertEqual(segment.source, .mic)
    }
}
