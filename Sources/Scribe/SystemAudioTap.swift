import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures ALL system audio output (Zoom, Teams, Meet, FaceTime, browsers —
/// anything that plays sound) via a Core Audio process tap on macOS 14.4+.
/// Scribe's own process is excluded so playback inside the app can never
/// feed back into a recording.
///
/// Audio is written progressively to a CAF file: CAF tolerates an
/// unfinalized data chunk, so a crash mid-recording loses nothing.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case osStatus(String, OSStatus)
        case badFormat

        var errorDescription: String? {
            switch self {
            case .osStatus(let stage, let status):
                return "System audio tap failed at \(stage) (error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .badFormat:
                return "System audio tap returned an unusable audio format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var format: AVAudioFormat?
    private let writeQueue = DispatchQueue(label: "app.talix.scribe.systemtap")
    private let paused = AtomicBool()
    /// Diagnostics: raw IO callbacks seen / buffer conversions failed.
    let callbackCount = AtomicCounter()
    let conversionFailures = AtomicCounter()
    let writesOK = AtomicCounter()
    private(set) var tapFormatDescription = ""
    /// First callback's raw buffer-list layout, for diagnostics.
    private(set) var firstBufferDescription = ""
    private(set) var firstWriteError = ""

    private(set) var fileURL: URL?

    func start(writingTo url: URL, onLevel: @escaping @Sendable (Float) -> Void) throws {
        fileURL = url

        // Exclude our own process from the global tap.
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(for: ProcessInfo.processInfo.processIdentifier) {
            excluded = [own]
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Scribe System Audio Tap"
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "create tap")
        tapID = newTapID

        // The tap tells us the format it delivers (typically 48 kHz stereo).
        var asbd = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw TapError.badFormat
        }
        format = tapFormat
        tapFormatDescription = "\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame)ch, fmt \(asbd.mFormatID), flags \(asbd.mFormatFlags)"

        // A private aggregate device hosts the tap so we can run an IO proc
        // against it without touching the user's device setup. The default
        // output device must be included as a real subdevice — an aggregate
        // with only a tap has no clock, so its IO cycle never runs and the
        // callback never fires (symptom: a 4 KB header-only file).
        let outputUID = try defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe Tap Device",
            kAudioAggregateDeviceUIDKey: "app.talix.scribe.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID), "create aggregate device")
        aggregateID = newAggregateID

        // The tap delivers interleaved float32; AVAudioFile's default
        // processing format is de-interleaved, and ExtAudioFileWrite errors
        // (-50) on the mismatch — declare interleaved explicitly.
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: tapFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: tapFormat.isInterleaved
        )

        let pausedFlag = paused
        var levelCounter = 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, writeQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.callbackCount.increment()
            if self.firstBufferDescription.isEmpty {
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let sizes = abl.map { "\($0.mDataByteSize)B/\($0.mNumberChannels)ch" }.joined(separator: ", ")
                self.firstBufferDescription = "buffers: \(abl.count) [\(sizes)]"
            }
            guard let format = self.format, let file = self.audioFile else { return }
            guard !pausedFlag.value else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                self.conversionFailures.increment()
                return
            }
            // bufferListNoCopy can leave frameLength at 0 — set it from the
            // delivered byte count or write() silently writes nothing.
            let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
            if bytesPerFrame > 0 {
                buffer.frameLength = inInputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
            }
            if self.firstBufferDescription.hasSuffix("]") {
                self.firstBufferDescription += " frameLength=\(buffer.frameLength) capacity=\(buffer.frameCapacity)"
            }
            guard buffer.frameLength > 0 else { return }
            do {
                try file.write(from: buffer)
                self.writesOK.increment()
            } catch {
                if self.firstWriteError.isEmpty { self.firstWriteError = "\(error)" }
                NSLog("Scribe: system tap write failed: %@", error.localizedDescription)
            }
            // Level metering ~10x/sec is plenty; buffers arrive ~100x/sec.
            levelCounter += 1
            if levelCounter % 8 == 0 {
                onLevel(buffer.rmsLevel)
            }
        }, "create IO proc")

        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
    }

    var isPaused: Bool { paused.value }

    func setPaused(_ value: Bool) {
        paused.value = value
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        // Ensure pending writes land before the file is closed.
        writeQueue.sync { self.audioFile = nil }
        cleanup()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else {
            cleanup()
            throw TapError.osStatus(stage, status)
        }
    }

    /// UID of the device the user currently hears audio through — the
    /// aggregate's clock source.
    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID), "find output device")

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &uid) { pointer in
            try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer), "read output device UID")
        }
        return uid as String
    }

    /// Translates a PID to its Core Audio process object (for tap exclusion).
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPointer,
                &size, &objectID
            )
        }
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }; return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }; _value += 1
    }
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

extension AVAudioPCMBuffer {
    /// RMS of channel 0, mapped into 0…1 for level meters.
    var rmsLevel: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrtf(sum / Float(frameLength))
        // Perceptual-ish curve: -50 dB → 0, 0 dB → 1.
        let db = 20 * log10f(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }
}
