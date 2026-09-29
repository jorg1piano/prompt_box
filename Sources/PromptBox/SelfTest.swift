import AppKit
import PromptBoxCore

/// `PROMPTBOX_SELFTEST=/some/dir PromptBox.app/Contents/MacOS/PromptBox` types, pastes three
/// images, deletes a word, a line and an image, writes what it would send to that folder, then
/// shows the window for three seconds and quits. It never saves the draft, history or deleted log.
@MainActor
enum SelfTest {
    private static var window: PromptWindow?

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = PromptWindow(persist: false)
        Self.window = window
        window.panel.setFrame(NSRect(x: 0, y: 0, width: 640, height: 525), display: false)
        window.panel.contentView?.layoutSubtreeIfNeeded()
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

        window.toggleSidebar(.deleted)
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
}
