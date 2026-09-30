import Foundation
import PromptBoxCore

/// Runs `claude -p` over transcript segments and returns the prompt it wrote from them. It uses
/// the Claude Code login, no tools and no session, from a folder with no CLAUDE.md in it.
enum Suggester {
    /// `sonnet` unless the `suggestionModel` default says otherwise. Haiku was slower in testing and
    /// changed details ("600 points" became "600 pixels").
    static var model: String { UserDefaults.standard.string(forKey: "suggestionModel") ?? "sonnet" }

    /// `echo` marks the segments that were the speakers, from `EchoMatch.scores`.
    static func suggestion(from segments: [TranscriptSegment], echo: [String: Double]) async throws -> Suggestion {
        let output = try await runClaude(input: PromptSuggestion.input(for: segments, echo: echo))
        return try PromptSuggestion.suggestion(fromCLIOutput: output, segments: segments)
    }

    private static func runClaude(input: String) async throws -> Data {
        guard let claude = claudeURL() else {
            throw PromptSuggestion.Failure(message: "Can't find the claude command. Set its path with `defaults write no.devda.PromptBox claudePath /path/to/claude`.")
        }
        let arguments = ["-p", "--model", model, "--tools", "", "--no-session-persistence", "--setting-sources", "",
                         "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", PromptSuggestion.systemPrompt,
                         "--output-format", "json", "--json-schema", PromptSuggestion.schema]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = claude
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = [claude.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                                       "/usr/bin", "/bin"].joined(separator: ":")
                process.environment = environment
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Write and read on separate queues so a full pipe can't stall either side.
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                var errors = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errors = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timeout.cancel()
                // A failed run still prints its JSON result with the reason, so let the parser report that.
                if process.terminationStatus != 0, output.isEmpty {
                    let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: PromptSuggestion.Failure(
                        message: message.isEmpty ? "claude exited with status \(process.terminationStatus)" : message))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }

    /// The `claudePath` default, then the usual install places, then whatever a login shell finds.
    private static func claudeURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let configured = UserDefaults.standard.string(forKey: "claudePath") { candidates.insert(configured, at: 0) }
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        shell.waitUntilExit()
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
