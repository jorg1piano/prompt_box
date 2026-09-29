import AppKit
import XCTest
@testable import PromptBoxCore

final class DeletionCoalescerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)

    func testBackspacesJoinIntoOneEntry() {
        var c = DeletionCoalescer()
        // "hello" at 0..<5, cursor at 5, backspace five times.
        XCTAssertEqual(c.record(range: NSRange(location: 4, length: 1), deletedText: "o", replacementLength: 0, at: t0), .newEntry)
        for i in stride(from: 3, through: 0, by: -1) {
            XCTAssertEqual(c.record(range: NSRange(location: i, length: 1), deletedText: "x", replacementLength: 0, at: t0), .prepend)
        }
    }

    func testForwardDeletesAppend() {
        var c = DeletionCoalescer()
        XCTAssertEqual(c.record(range: NSRange(location: 2, length: 1), deletedText: "a", replacementLength: 0, at: t0), .newEntry)
        XCTAssertEqual(c.record(range: NSRange(location: 2, length: 1), deletedText: "b", replacementLength: 0, at: t0), .append)
    }

    func testPauseStartsNewEntry() {
        var c = DeletionCoalescer(window: 4)
        _ = c.record(range: NSRange(location: 4, length: 1), deletedText: "o", replacementLength: 0, at: t0)
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(c.record(range: NSRange(location: 3, length: 1), deletedText: "l", replacementLength: 0, at: later), .newEntry)
    }

    func testTypingBreaksTheRun() {
        var c = DeletionCoalescer()
        _ = c.record(range: NSRange(location: 4, length: 1), deletedText: "o", replacementLength: 0, at: t0)
        _ = c.record(range: NSRange(location: 4, length: 0), deletedText: "", replacementLength: 1, at: t0)
        XCTAssertEqual(c.record(range: NSRange(location: 3, length: 1), deletedText: "l", replacementLength: 0, at: t0), .newEntry)
    }

    func testWhitespaceAloneIsIgnoredButJoinsAnOpenEntry() {
        var c = DeletionCoalescer()
        XCTAssertEqual(c.record(range: NSRange(location: 5, length: 1), deletedText: "\n", replacementLength: 0, at: t0), .ignore)
        XCTAssertEqual(c.record(range: NSRange(location: 3, length: 2), deletedText: "hi", replacementLength: 0, at: t0), .newEntry)
        XCTAssertEqual(c.record(range: NSRange(location: 2, length: 1), deletedText: " ", replacementLength: 0, at: t0), .prepend)
    }

    func testTypingOverSelectionKeepsTheSelection() {
        var c = DeletionCoalescer()
        XCTAssertEqual(c.record(range: NSRange(location: 0, length: 5), deletedText: "hello", replacementLength: 1, at: t0), .newEntry)
        XCTAssertEqual(c.record(range: NSRange(location: 0, length: 1), deletedText: "x", replacementLength: 0, at: t0), .newEntry)
    }
}

final class PromptExportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func png(_ pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testImagesFollowTheTextAsNumberedPaths() throws {
        let prompt = Prompt(text: "  compare image 1 and 2\n", images: [png(2), png(3)])
        let output = try PromptExport.plainText(from: prompt, imageDirectory: dir)
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "compare image 1 and 2")
        XCTAssertEqual(lines[1], "")
        XCTAssertTrue(lines[2].hasPrefix("Image 1: \(dir.path)/"))
        XCTAssertTrue(lines[3].hasPrefix("Image 2: \(dir.path)/"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    func testSameImageTwiceReusesOneFile() throws {
        _ = try PromptExport.plainText(from: Prompt(images: [png(2), png(2)]), imageDirectory: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

    func testPlainTextPassesThrough() throws {
        XCTAssertEqual(try PromptExport.plainText(from: Prompt(text: "  a\n\nb  \n"), imageDirectory: dir), "a\n\nb")
    }

    func testPromptRoundTripsThroughAttributedString() {
        let prompt = Prompt(text: "hello\nworld", images: [png(2), png(4)])
        XCTAssertEqual(Prompt(prompt.attributed), prompt)
    }

    func testInlineImagesFromOldDraftsMoveToTheList() {
        let old = NSMutableAttributedString(string: "look ")
        let wrapper = FileWrapper(regularFileWithContents: png(2))
        wrapper.preferredFilename = "image.png"
        old.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        old.append(NSAttributedString(string: " here"))
        let prompt = Prompt(old)
        XCTAssertEqual(prompt.text, "look  here")
        XCTAssertEqual(prompt.images.count, 1)
    }
}

final class EntryStoreTests: XCTestCase {
    func testRoundTripAndLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EntryStore(directory: dir, limit: 2)
        let first = store.add(NSAttributedString(string: "one"))
        let second = store.add(NSAttributedString(string: "two\n\n  three"))
        store.update(second, text: NSAttributedString(string: "two\n\n  three!"))
        store.flush()

        let reloaded = EntryStore(directory: dir, limit: 2)
        XCTAssertEqual(reloaded.entries.map(\.id), [second, first])
        XCTAssertEqual(reloaded.entries[0].preview, "two\nthree!")
        XCTAssertEqual(reloaded.text(for: first)?.string, "one")

        reloaded.add(NSAttributedString(string: "four"))
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertNil(reloaded.entries.first { $0.id == first })
    }
}
