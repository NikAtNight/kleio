import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures selected application processes, or all system output when explicitly requested.
/// Progressive CAF writes preserve completed buffers if the app is interrupted.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case osStatus(String, OSStatus)
        case badFormat
        case configurationChanged
        case ambiguousInput
        case inconsistentTiming

        var errorDescription: String? {
            switch self {
            case .osStatus(let stage, let status):
                return "System audio tap failed at \(stage) (error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .badFormat:
                return "System audio tap returned an unusable audio format."
            case .ambiguousInput:
                return "This output device combines microphone and app-audio streams that Kleio cannot safely separate yet. Choose headphones or another output device before recording app audio."
            case .configurationChanged:
                return "The audio device changed during recording. Your recorded audio was kept. Start a new recording with the current device."
            case .inconsistentTiming:
                return "App audio stopped arriving at the expected rate. Your recorded audio was kept. Reconnect your audio device before starting a new recording."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var timelineWriter: TimelineAudioWriter?
    private var tapDescription: CATapDescription?
    private var inputFormat: TapInputFormat?
    private var readiness: AtomicBool?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
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

    func start(writingTo url: URL, processes: [AudioObjectID]? = nil, clock: RecordingClock? = nil,
               onError: (@Sendable (String) -> Void)? = nil, onLevel: @escaping @Sendable (Float) -> Void) throws {
        do { try start(writingTo: Optional(url), processes: processes, clock: clock, onError: onError, onLevel: onLevel) }
        catch { stop(); throw error }
    }

    /// Starts the Core Audio tap for level confirmation only. No file is
    /// created and no audio buffers are retained.
    func startMetering(onLevel: @escaping @Sendable (Float) -> Void) throws {
        do { try start(writingTo: nil, processes: nil, clock: nil, onError: nil, onLevel: onLevel) }
        catch { stop(); throw error }
    }

    private func start(writingTo url: URL?, processes: [AudioObjectID]?, clock: RecordingClock?,
                       onError: (@Sendable (String) -> Void)?, onLevel: @escaping @Sendable (Float) -> Void) throws {
        fileURL = url

        // Exclude our own process from the global tap.
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(for: ProcessInfo.processInfo.processIdentifier) {
            excluded = [own]
        }
        if let processes, processes.isEmpty { throw TapError.badFormat }
        let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription = description
        description.name = "Scribe System Audio Tap"
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "create tap")
        tapID = newTapID

        // Give the private aggregate a hardware clock. Its default rate can
        // differ from Bluetooth output, even while the tap advertises 48 kHz.
        let output = try defaultOutputDevice()
        guard try inputBufferChannels(of: output.id).allSatisfy({ $0 == 0 }) else { throw TapError.ambiguousInput }
        let outputUID = output.uid
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

        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = try nominalRate(of: output.id)
        let rateSize = UInt32(MemoryLayout<Float64>.size)
        // Set only the private aggregate, and only to its anchor's current rate.
        try check(AudioObjectSetPropertyData(aggregateID, &rateAddress, 0, nil, rateSize, &rate), "align aggregate rate")
        // HAL property changes are asynchronous. Keep startup bounded while
        // waiting for the aggregate to publish the requested device rate.
        for _ in 0..<50 {
            if (try? nominalRate(of: aggregateID)) == rate { break }
            usleep(10_000)
        }
        guard try nominalRate(of: aggregateID) == rate, try nominalRate(of: output.id) == rate else {
            throw TapError.configurationChanged
        }

        let ready = AtomicBool()
        readiness = ready
        let invalidated = AtomicBool()
        let pausedFlag = paused
        var levelCounter = 0
        var timing = TapTimingValidator()
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, writeQueue) { [weak self] _, inInputData, inputTime, _, _ in
            guard let self else { return }
            self.callbackCount.increment()
            if self.firstBufferDescription.isEmpty {
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let sizes = abl.map { "\($0.mDataByteSize)B/\($0.mNumberChannels)ch" }.joined(separator: ", ")
                self.firstBufferDescription = "buffers: \(abl.count) [\(sizes)]"
            }
            guard ready.value, !pausedFlag.value, self.firstWriteError.isEmpty else { return }
            do {
                guard !invalidated.value else { throw TapError.configurationChanged }
                guard let input = self.inputFormat else { throw TapError.badFormat }
                guard let buffer = try input.copyBuffer(from: inInputData) else { return }
                let timestamp = inputTime.pointee
                guard timestamp.mFlags.contains(.hostTimeValid) else { throw TapError.badFormat }
                let hostTime = AVAudioTime.seconds(forHostTime: timestamp.mHostTime)
                try timing.validate(frames: buffer.frameLength, rate: input.format.sampleRate,
                    hostTime: hostTime, sampleTime: timestamp.mFlags.contains(.sampleTimeValid) ? timestamp.mSampleTime : nil)
                if self.firstBufferDescription.hasSuffix("]") {
                    self.firstBufferDescription += " frameLength=\(buffer.frameLength) capacity=\(buffer.frameCapacity)"
                }
                if let writer = self.timelineWriter {
                    try writer.write(buffer, hostTime: hostTime)
                    self.writesOK.increment()
                } else if let file = self.audioFile {
                    try file.write(from: buffer)
                    self.writesOK.increment()
                }
                levelCounter += 1
                if levelCounter % 8 == 0 { onLevel(buffer.rmsLevel) }
            } catch {
                self.conversionFailures.increment()
                self.report(error, onError: onError)
            }
        }, "create IO proc")

        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
        // No samples are saved until the running device's format is validated.
        var runningInput: (TapInputFormat, [AudioObjectID])?
        for _ in 0..<50 {
            if let candidate = try? readInputFormat(outputDevice: output.id), candidate.0.format.sampleRate == rate {
                runningInput = candidate
                break
            }
            usleep(10_000)
        }
        guard let (input, streams) = runningInput else { throw TapError.configurationChanged }
        let expectedRate = rate
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // A delayed notification from startup or a process-list refresh
            // need not mean the running format changed. Compare actual values.
            do {
                guard try self.configurationMatches(input: input, streams: streams,
                    output: output.id, rate: expectedRate) else { throw TapError.configurationChanged }
            } catch {
                invalidated.value = true
                if ready.value { self.report(TapError.configurationChanged, onError: onError) }
            }
        }
        var watched: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal),
            (aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            (aggregateID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (aggregateID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (aggregateID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (output.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (output.id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal),
        ]
        for stream in streams {
            watched.append((stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal))
            watched.append((stream, kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal))
        }
        for (object, selector, scope) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectAddPropertyListenerBlock(object, &address, writeQueue, changed), "observe audio format")
            listeners.append((object, address, changed))
        }
        guard try configurationMatches(input: input, streams: streams, output: output.id, rate: rate) else {
            throw TapError.configurationChanged
        }
        try writeQueue.sync {
            guard !invalidated.value, firstWriteError.isEmpty else { throw TapError.configurationChanged }
            inputFormat = input
            tapFormatDescription = "\(input.format.sampleRate) Hz, \(input.format.channelCount)ch, aggregate input"
            if let url, let clock {
                timelineWriter = try TimelineAudioWriter(url: url, format: input.format, clock: clock)
            } else if let url {
                audioFile = try AVAudioFile(forWriting: url, settings: input.format.settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            ready.value = true
        }
    }

    var isPaused: Bool { paused.value }

    func setPaused(_ value: Bool) {
        paused.value = value
    }

    func stop() {
        readiness?.value = false
        for (object, originalAddress, block) in listeners {
            var address = originalAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, writeQueue, block)
        }
        listeners.removeAll()
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        // Ensure pending writes land before the file is closed.
        writeQueue.sync {
            self.audioFile = nil
            self.timelineWriter?.finish()
            self.timelineWriter = nil
        }
        cleanup()
    }

    /// Refresh only the selected application's process list when helpers start or restart.
    func updateProcesses(_ processes: [AudioObjectID]) throws {
        guard !processes.isEmpty, let description = tapDescription, tapID != kAudioObjectUnknown else { return }
        description.processes = processes
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: description) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil,
                UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        guard status == noErr else { throw TapError.osStatus("update selected app", status) }
    }

    private func report(_ error: Error, onError: (@Sendable (String) -> Void)?) {
        guard firstWriteError.isEmpty else { return }
        firstWriteError = error.localizedDescription
        onError?(error.localizedDescription)
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
            DiagLog.log("system audio tap failed at %@: status %d", stage, status)
            throw TapError.osStatus(stage, status)
        }
    }

    /// The device used to clock the private aggregate and select its tap stream.
    private func defaultOutputDevice() throws -> (id: AudioObjectID, uid: String) {
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
        return (deviceID, uid as String)
    }

    private func nominalRate(of device: AudioObjectID) throws -> Float64 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate), "read device rate")
        guard rate.isFinite, rate > 0 else { throw TapError.badFormat }
        return rate
    }

    private func configurationMatches(input: TapInputFormat, streams: [AudioObjectID], output: AudioObjectID, rate: Double) throws -> Bool {
        let (current, currentStreams) = try readInputFormat(outputDevice: output)
        for device in [output, aggregateID] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive), "check audio device")
            guard alive != 0 else { return false }
        }
        return try defaultOutputDevice().id == output && nominalRate(of: output) == rate
            && nominalRate(of: aggregateID) == rate && currentStreams == streams
            && current.format == input.format && current.bufferChannels == input.bufferChannels
    }

    private func streamIDs(of device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "read stream count")
        guard size > 0 else { return [] }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams), "read streams")
        return streams
    }

    private func streamFormat(_ stream: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd), "read stream format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError.badFormat }
        return format
    }

    private func inputBufferChannels(of device: AudioObjectID) throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "read input layout size")
        guard size >= MemoryLayout<UInt32>.size else { throw TapError.badFormat }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage), "read input layout")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    private func readInputFormat(outputDevice: AudioObjectID) throws -> (TapInputFormat, [AudioObjectID]) {
        let channels = try streamIDs(of: aggregateID, scope: kAudioObjectPropertyScopeInput).map { stream in
            var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyStartingChannel,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var firstChannel: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &firstChannel), "read stream channel")
            return (stream: stream, first: firstChannel)
        }.sorted { $0.first < $1.first }
        let streams = channels.map(\.stream)
        let formats = try streams.map(streamFormat)
        try TapInputFormat.validateChannelOrder(starts: channels.map(\.first), counts: formats.map(\.channelCount))
        guard try inputBufferChannels(of: outputDevice).allSatisfy({ $0 == 0 }) else { throw TapError.ambiguousInput }
        let input = try TapInputFormat(streamFormats: formats)
        guard try inputBufferChannels(of: aggregateID) == input.bufferChannels else { throw TapError.badFormat }
        return (input, streams)
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
