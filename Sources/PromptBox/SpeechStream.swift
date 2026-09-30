import AVFoundation
import PromptBoxCore
import Speech

/// On-device transcription of a live audio stream. Feed it buffers in any format from any
/// thread; it reports finished segments with wall-clock times, and the words it is still unsure
/// of.
final class SpeechStream: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    /// Wall-clock time of the first sample. The analyzer times results from there.
    private let started = Date()

    /// Both are called on the main actor.
    var onFinal: ((TranscriptSegment) -> Void)?
    var onVolatile: ((String) -> Void)?

    /// Downloads the language model first if it isn't installed.
    static func make(locale: Locale) async throws -> SpeechStream {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw PromptGrouping.Failure(message: "No audio format for \(locale.identifier)")
        }
        return try await SpeechStream(transcriber: transcriber, format: format)
    }

    private init(transcriber: SpeechTranscriber, format: AVAudioFormat) async throws {
        self.transcriber = transcriber
        self.format = format
        analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        results = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                NSLog("PromptBox transcription stopped: \(error)")
            }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let isFinal = result.isFinal
        let segment = TranscriptSegment(start: started.addingTimeInterval(result.range.start.seconds),
                                        end: started.addingTimeInterval(result.range.end.seconds), text: text)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isFinal {
                self.onVolatile?("")
                if !text.isEmpty { self.onFinal?(segment) }
            } else {
                self.onVolatile?(text)
            }
        }
    }

    /// Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if buffer.format == format {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }

    /// Finishes what was said so far and stops.
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }
}
