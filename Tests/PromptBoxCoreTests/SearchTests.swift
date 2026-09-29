import XCTest
@testable import PromptBoxCore

final class FuzzyMatchTests: XCTestCase {
    func score(_ query: String, _ text: String) -> Double? { FuzzyMatch.match(query, in: text)?.score }

    func testExactPrefixAndInnerMatches() {
        XCTAssertEqual(score("sidebar", "Fix the sidebar"), 1)
        XCTAssertEqual(score("side", "Fix the sidebar"), 0.9)
        XCTAssertEqual(score("bar", "Fix the sidebar"), 0.75)
    }

    func testTyposAreForgiven() {
        XCTAssertNotNil(score("sidbar", "Fix the sidebar"))    // missing letter
        XCTAssertNotNil(score("sidebra", "Fix the sidebar"))   // swapped letters
        XCTAssertNotNil(score("promtp", "write a prompt"))     // swapped at the end
        XCTAssertNotNil(score("respnse", "the response body")) // missing letter, partial word
        XCTAssertNotNil(score("authentcation", "OAuth authentication flow")) // long word, one miss
    }

    func testShortWordsNeedToBeRight() {
        XCTAssertNil(score("cat", "the car"))
    }

    func testEveryWordMustMatch() {
        XCTAssertNotNil(score("fix sidebar", "Fix the sidebar"))
        XCTAssertNil(score("fix header", "Fix the sidebar"))
    }

    func testLettersInOrderAsLastResort() {
        XCTAssertEqual(score("rspns", "the response body"), 0.35)
    }

    func testCaseAndAccentsIgnored() {
        XCTAssertEqual(score("CAFE", "the café menu"), 1)
    }

    func testCloserMatchesScoreHigher() {
        XCTAssertGreaterThan(score("sidebar", "sidebar")!, score("sidbar", "sidebar")!)
        XCTAssertGreaterThan(score("side", "sidebar")!, score("sidbar", "sidebar")!)
    }

    func testRangePointsAtTheMatch() {
        let text = "one two sidebar"
        let match = FuzzyMatch.match("sidebr", in: text)!
        XCTAssertEqual((text as NSString).substring(with: match.range), "sidebar")
    }
}

final class TabSearchTests: XCTestCase {
    let now = Date()

    func candidate(_ id: String, _ text: String, ago: TimeInterval = 0) -> TabSearch.Candidate {
        let title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return TabSearch.Candidate(id: id, title: title, text: text, lastActive: now.addingTimeInterval(-ago))
    }

    func testEmptyQueryKeepsOrder() {
        let hits = TabSearch.rank("", among: [candidate("a", "Alpha\nsecond"), candidate("b", "Beta")])
        XCTAssertEqual(hits.map(\.id), ["a", "b"])
        XCTAssertEqual(hits[0].snippet, "second")
    }

    func testBestMatchFirstAndNonMatchesDropped() {
        let hits = TabSearch.rank("sidebar", among: [
            candidate("typo", "Refactor the sidbar code"),
            candidate("exact", "Sidebar overlaps editor"),
            candidate("none", "Database migration"),
        ])
        XCTAssertEqual(hits.map(\.id), ["exact", "typo"])
    }

    func testTitleBeatsBody() {
        let hits = TabSearch.rank("deploy", among: [
            candidate("body", "Some task\nthen deploy it"),
            candidate("title", "Deploy the app\nwith fly"),
        ])
        XCTAssertEqual(hits.map(\.id), ["title", "body"])
    }

    func testTiesGoToMostRecent() {
        let hits = TabSearch.rank("bug", among: [candidate("old", "bug one", ago: 100), candidate("new", "bug two", ago: 1)])
        XCTAssertEqual(hits.map(\.id), ["new", "old"])
    }

    func testSnippetShowsTheMatchingLine() {
        let hits = TabSearch.rank("migration", among: [candidate("a", "Title line\nfiller\nrun the migration on staging")])
        XCTAssertEqual(hits[0].snippet, "run the migration on staging")
    }
}

final class TabFilesTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = TabFiles(directory: dir)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let index = TabIndex(tabs: [.init(id: "a", created: date, lastActive: date)], selected: "a")
        try files.save(index)
        try files.save(Prompt(text: "hello"), id: "a")
        XCTAssertEqual(files.loadIndex(), index)
        XCTAssertEqual(files.loadPrompt("a"), Prompt(text: "hello"))
        files.delete("a")
        XCTAssertNil(files.loadPrompt("a"))
    }
}
