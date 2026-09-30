import AVFoundation
import CoreAudio

/// Records what the Mac plays (every app but PromptBox) through a Core Audio process tap, so it
/// can be transcribed next to the microphone. macOS asks once for "System Audio Recording";
/// without it the tap delivers silence.
final class SpeakerCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "no.devda.PromptBox.speakers", qos: .userInitiated)

    struct Failure: Error, LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "Couldn't record the speakers (\(step), \(status))" }
    }

    /// `feed` gets each buffer on a background queue, and only for the length of the call.
    func start(feed: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(__stereoGlobalTapButExcludeProcesses: ownProcess().map { [NSNumber(value: $0)] } ?? [])
        description.uuid = UUID()
        description.name = "PromptBox speakers"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { throw Failure(step: "format", status: -1) }

        let output = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PromptBox speakers",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID))
        try check("reader", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            if let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) {
                feed(buffer)
            }
        })
        try check("start", AudioDeviceStart(deviceID, procID))
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    /// PromptBox's own audio object, so the tap leaves out anything it plays.
    private func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check("output", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check("output uid", AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid))
        guard let uid else { throw Failure(step: "output uid", status: -1) }
        return uid.takeRetainedValue() as String
    }

    /// Calls `handler` on the main queue when the default output device changes (headphones in
    /// or out), which a running tap doesn't follow.
    static func observeOutputChanges(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }
}
