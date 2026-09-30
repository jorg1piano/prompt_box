import AppKit
import AVFoundation
import PromptBoxCore
import Speech

/// Keeps the microphone open from launch and writes every finished segment to the transcript
/// log. It restarts itself when the input device changes or the Mac wakes.
@MainActor
final class Listener {
    enum State: Equatable {
        case starting
        case listening(locale: String)
        case paused
        case failed(String)
    }

    let log: TranscriptLog
    private(set) var state: State = .paused { didSet { onChange?() } }
    /// Words the transcriber hasn't settled on yet.
    private(set) var volatile = "" { didSet { onChange?() } }

    var onSegment: ((TranscriptSegment) -> Void)?
    var onChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private var stream: SpeechStream?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    private static let pausedKey = "listeningPaused"
    /// A locale identifier like `en-US`; the system language when unset.
    private static let localeKey = "transcriptLocale"

    var isPaused: Bool { UserDefaults.standard.bool(forKey: Self.pausedKey) }

    init(log: TranscriptLog) {
        self.log = log
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    func start() {
        guard !isPaused else {
            state = .paused
            return
        }
        generation += 1
        let run = generation
        state = .starting
        Task {
            do {
                try await self.begin(run)
            } catch {
                guard run == self.generation else { return }
                self.stopEngine()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: Self.pausedKey)
        if paused {
            generation += 1
            stop()
            state = .paused
        } else {
            start()
        }
    }

    private func restart() {
        guard !isPaused else { return }
        stop()
        start()
    }

    private func begin(_ run: Int) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw PromptGrouping.Failure(message: "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
        }
        let wanted = UserDefaults.standard.string(forKey: Self.localeKey).map(Locale.init(identifier:)) ?? Locale.current
        var match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        if match == nil { match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = match else {
            throw PromptGrouping.Failure(message: "On-device transcription doesn't support \(wanted.identifier)")
        }
        let stream = try await SpeechStream.make(locale: locale)
        guard run == generation else {
            await stream.finish()
            return
        }
        stream.onFinal = { [weak self] segment in self?.record(segment) }
        stream.onVolatile = { [weak self] text in self?.volatile = text }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw PromptGrouping.Failure(message: "No microphone") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in stream.feed(buffer) }
        engine.prepare()
        try engine.start()
        self.stream = stream
        state = .listening(locale: locale.identifier(.bcp47))
    }

    private func record(_ segment: TranscriptSegment) {
        do {
            try log.append(segment)
        } catch {
            NSLog("PromptBox couldn't save a transcript segment: \(error)")
        }
        onSegment?(segment)
    }

    /// Stops the microphone; what was already said still gets finished and saved.
    func stop() {
        stopEngine()
        if let stream {
            self.stream = nil
            Task { await stream.finish() }
        }
        volatile = ""
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
