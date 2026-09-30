import AppKit
import AVFoundation
import PromptBoxCore

/// `PROMPTBOX_SELFTEST=/some/dir PromptBox.app/Contents/MacOS/PromptBox` types, pastes three
/// images, deletes a word, a line and an image, writes what it would send to that folder, opens
/// two more tabs and searches them with ⌘K (or opens the deleted list, with
/// PROMPTBOX_SELFTEST_SIDEBAR set), then shows the window for three seconds and quits. It never saves the draft, history or deleted log.
@MainActor
enum SelfTest {
    private static var window: PromptWindow?

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = PromptWindow(persist: false)
        Self.window = window
        window.panel.setFrame(NSRect(x: 0, y: 0, width: 640, height: 525), display: false)
        window.panel.contentView?.layoutSubtreeIfNeeded()
        if let audio = ProcessInfo.processInfo.environment["PROMPTBOX_SELFTEST_AUDIO"] {
            transcribe(URL(fileURLWithPath: audio))
            return
        }
        if ProcessInfo.processInfo.environment["PROMPTBOX_SELFTEST_TRANSCRIPT"] != nil {
            runTranscript(window, into: dir)
            return
        }
        let text = window.textView
        text.string = ""

        text.insertText("Fix the layout bug in these screenshots:\n", replacementRange: text.selectedRange())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("no.devda.PromptBox.selftest"))
        for (color, size) in [(NSColor.systemTeal, NSSize(width: 1200, height: 700)),
                              (NSColor.systemOrange, NSSize(width: 400, height: 900)),
                              (NSColor.systemPurple, NSSize(width: 2400, height: 500))] {
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                rect.fill()
                NSColor.white.setFill()
                NSRect(x: rect.width * 0.1, y: rect.height * 0.1, width: rect.width * 0.4, height: rect.height * 0.4).fill()
                return true
            }
            pasteboard.clearContents()
            pasteboard.setData(image.tiffRepresentation, forType: .tiff)
            _ = text.readSelection(from: pasteboard)
        }
        text.insertText("The sidebar overlaps the editor when narrow.", replacementRange: text.selectedRange())

        // Backspace over "narrow." one character at a time, ⌘⇧K the first line, remove image 2.
        for _ in 0..<7 { text.deleteBackward(nil) }
        text.setSelectedRange(NSRange(location: 3, length: 0))
        text.deleteLines(nil)
        window.strip.onRemove?(1)

        // Two more tabs, then a ⌘K search with a typo in it.
        window.newTab(with: Prompt(text: "Refactor the authentication flow\nMove token refresh into the client"))
        window.newTab(with: Prompt(text: "Database migration for users\nAdd an index on email"))
        window.selectTab(offset: 1)
        if ProcessInfo.processInfo.environment["PROMPTBOX_SELFTEST_SIDEBAR"] != nil {
            window.toggleSidebar(.deleted)
        } else {
            window.switcher.open(query: "authentcation")
        }
        let sent = (try? PromptExport.plainText(from: window.prompt, imageDirectory: dir)) ?? "export failed"
        let deleted = window.deleted.entries.map { $0.preview }.joined(separator: "\n---\n")
        let report = "SENT:\n\(sent)\n\nDELETED (newest first):\n\(deleted)\n\nIMAGES: \(window.strip.images.count)\n"
        try? report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)

        // Show the real window for three seconds so `screencapture -l <window>` can grab it.
        window.panel.orderFrontRegardless()
        print("WINDOW \(window.panel.windowNumber)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    /// Plays an audio file through the same transcription path as the microphone, in real time,
    /// and prints each finished segment with its offset from the start.
    private static func transcribe(_ url: URL) {
        Task { @MainActor in
            do {
                let file = try AVAudioFile(forReading: url)
                let stream = try await SpeechStream.make(locale: Locale(identifier: "en-US"))
                let began = Date()
                stream.onFinal = { segment in
                    print(String(format: "SEGMENT %.1f-%.1f %@", segment.start.timeIntervalSince(began),
                                 segment.end.timeIntervalSince(began), segment.text))
                    fflush(stdout)
                }
                let chunk: AVAudioFrameCount = 4096
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                    try file.read(into: buffer, frameCount: chunk)
                    stream.feed(buffer)
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                }
                await stream.finish()
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                print("FAILED \(error)")
            }
            exit(0)
        }
    }

    /// Fills the transcript with made-up speech, opens the transcript tab (which asks claude for
    /// the prompts in it), writes what came back to `transcript.txt`, and shows the window.
    private static func runTranscript(_ window: PromptWindow, into dir: URL) {
        let lines = [
            (0, "okay so the sidebar um overlaps the editor when the window is really narrow"),
            (4, "we should probably collapse it under like 600 points"),
            (40, "yeah I'll be there in five minutes, just finishing something"),
            (95, "and in the fuzzy search add a test for typos like sidbar and promtp"),
            (99, "oh and the sidebar thing, keep the deleted list open when it collapses"),
            (140, "in today's video we're going to look at the best mechanical keyboards of 2026"),
            (160, "add a setting to change the keyboard shortcut for the transcript tab"),
        ]
        let start = Date().addingTimeInterval(-600)
        var fake = lines.map { offset, text in
            TranscriptSegment(start: start.addingTimeInterval(TimeInterval(offset)),
                              end: start.addingTimeInterval(TimeInterval(offset) + 3), text: text)
        }
        // The keyboard video, as the speakers played it a moment earlier.
        fake.append(TranscriptSegment(start: start.addingTimeInterval(139.5), end: start.addingTimeInterval(142.5),
                                      text: "In today's video we're going to look at the best mechanical keyboards of 2026.",
                                      source: .speakers))
        window.transcript.seed(fake)
        window.panel.orderFrontRegardless()
        window.showTranscript()
        print("WINDOW \(window.panel.windowNumber)")
        fflush(stdout)
        func finish() {
            guard !window.transcript.isFindingPrompts else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { finish() } }
                return
            }
            let report = window.transcript.candidates.map { "# \($0.title)\n\($0.prompt)\n  from: \($0.quote)" }
                .joined(separator: "\n\n")
            try? report.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            print(report.isEmpty ? "NO PROMPTS" : report)
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { finish() } }
    }
}
