import Foundation
import AVFoundation
import CoreMedia
import CoreAudio

/// Records the selected input device to a CAF file, writing progressively so
/// a crash mid-recording loses nothing.
final class MicRecorder {
    enum MicError: LocalizedError {
        case permissionDenied
        case deviceUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .deviceUnavailable:
                return "No microphone input is available."
            }
        }
    }

    private let controlQueue = DispatchQueue(label: "Scribe.MicControl", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "Scribe.MicSamples", qos: .userInitiated)
    private let paused = AtomicBool()
    private let stateLock = NSLock()

    private var session: AVCaptureSession?
    private var forwarder: MicSampleForwarder?
    private var runtimeObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?
    private var audioFile: AVAudioFile?
    private var timelineWriter: TimelineAudioWriter?
    private var onError: (@Sendable (String) -> Void)?
    private var onWarning: (@Sendable (String) -> Void)?
    private var writeFailed = false
    private var onLevel: (@Sendable (Float) -> Void)?
    private var recordingActive = false
    private var captureGeneration = 0
    private var nextLevelTime: TimeInterval = 0

    private(set) var fileURL: URL?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, clock: RecordingClock? = nil, onError: (@Sendable (String) -> Void)? = nil, onWarning: (@Sendable (String) -> Void)? = nil, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicError.permissionDenied
        }

        try controlQueue.sync {
            if let clock {
                timelineWriter = try TimelineAudioWriter(url: url, format: MicAudioProcessing.targetFormat, clock: clock)
            } else {
                audioFile = try AVAudioFile(forWriting: url, settings: MicAudioProcessing.targetFormat.settings)
            }
            self.onError = onError
            self.onWarning = onWarning
            writeFailed = false
            fileURL = url
            self.onLevel = onLevel
            paused.value = false
            stateLock.lock()
            recordingActive = true
            nextLevelTime = 0
            stateLock.unlock()

            do {
                try startCaptureWithFallback()
            } catch {
                stateLock.lock()
                recordingActive = false
                stateLock.unlock()
                tearDownCapture()
                audioFile = nil
                timelineWriter?.finish()
                timelineWriter = nil
                self.onError = nil
                self.onLevel = nil
                fileURL = nil
                if error is MicError { throw error }
                throw MicError.deviceUnavailable
            }
        }
    }

    var isPaused: Bool { paused.value }

    func setPaused(_ value: Bool) {
        paused.value = value
    }

    func stop() {
        controlQueue.sync {
            stateLock.lock()
            recordingActive = false
            stateLock.unlock()
            tearDownCapture()
            sampleQueue.sync {}
            audioFile = nil
            timelineWriter?.finish()
            timelineWriter = nil
            onLevel = nil
            onError = nil
            onWarning = nil
        }
    }

    /// Builds a new capture session while leaving the CAF file open. A device
    /// loss can therefore resume into the same progressive recording.
    private func beginCapture(using device: AVCaptureDevice) throws {
        tearDownCapture()

        stateLock.lock()
        captureGeneration &+= 1
        let generation = captureGeneration
        stateLock.unlock()

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw MicError.deviceUnavailable }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let forwarder = MicSampleForwarder(targetFormat: MicAudioProcessing.targetFormat, hostTime: { [weak session] timestamp in
            guard let clock = session?.synchronizationClock else { return nil }
            return CMSyncConvertTime(timestamp, from: clock, to: CMClockGetHostTimeClock()).seconds
        }) { [weak self] buffer, hostTime in
            self?.write(buffer, hostTime: hostTime, from: generation)
        }
        output.setSampleBufferDelegate(forwarder, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw MicError.deviceUnavailable }
        session.addOutput(output)
        session.commitConfiguration()

        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.recoverFromRuntimeError(in: notification.object as? AVCaptureSession)
        }
        deviceDisconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self, weak session] _ in
            self?.recoverFromRuntimeError(in: session)
        }

        self.session = session
        self.forwarder = forwarder
        session.startRunning()
        guard session.isRunning else {
            tearDownCapture()
            throw MicError.deviceUnavailable
        }
    }

    private func startCaptureWithFallback() throws {
        var lastError: Error = MicError.deviceUnavailable
        for attempt in 0..<2 {
            for device in captureCandidates() {
                do {
                    try beginCapture(using: device)
                    return
                } catch {
                    lastError = error
                    NSLog("Scribe: microphone %@ failed to start: %@", device.localizedName, error.localizedDescription)
                }
            }
            if attempt == 0 { usleep(300_000) }
        }
        throw lastError
    }

    private func captureCandidates() -> [AVCaptureDevice] {
        let preferredUID = UserDefaults.standard.string(forKey: "preferredInputDeviceUID") ?? ""
        var candidates: [AVCaptureDevice] = []

        // AVCaptureDevice unique IDs match Core Audio device UIDs. Keep the
        // HAL lookup so a stale saved UID cannot pin capture to a removed mic.
        if !preferredUID.isEmpty,
           AudioDevices.deviceID(forUID: preferredUID) != nil,
           let preferred = AVCaptureDevice(uniqueID: preferredUID) {
            candidates.append(preferred)
        }
        if let defaultDevice = AVCaptureDevice.default(for: .audio),
           !candidates.contains(where: { $0.uniqueID == defaultDevice.uniqueID }) {
            candidates.append(defaultDevice)
        }
        if let builtIn = builtInCaptureDevice(),
           !candidates.contains(where: { $0.uniqueID == builtIn.uniqueID }) {
            candidates.append(builtIn)
        }
        return candidates
    }

    private func builtInCaptureDevice() -> AVCaptureDevice? {
        for input in AudioDevices.inputDevices() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                input.id,
                &address,
                0,
                nil,
                &size,
                &transport
            ) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            if let device = AVCaptureDevice(uniqueID: input.uid) { return device }
        }
        return nil
    }

    private func recoverFromRuntimeError(in failedSession: AVCaptureSession?) {
        controlQueue.async { [weak self] in
            guard let self, let failedSession, failedSession === self.session else { return }
            self.stateLock.lock()
            let active = self.recordingActive
            self.stateLock.unlock()
            guard active else { return }

            NSLog("Scribe: microphone capture stopped; rebuilding on an available input")
            do {
                try self.startCaptureWithFallback()
            } catch {
                // Keep the CAF file and recording state alive. A later runtime
                // retry can resume after a route transition or device replug.
                self.tearDownCapture()
                self.onWarning?("Microphone disconnected. Reconnect it or select another input. Capture will retry; the timeline keeps the missing interval.")
                self.scheduleRecoveryRetry()
            }
        }
    }

    private func scheduleRecoveryRetry() {
        controlQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldRetry = self.recordingActive && self.session == nil
            self.stateLock.unlock()
            guard shouldRetry else { return }
            do {
                try self.startCaptureWithFallback()
                NSLog("Scribe: microphone capture resumed")
            } catch {
                NSLog("Scribe: microphone still unavailable: %@", error.localizedDescription)
                self.scheduleRecoveryRetry()
            }
        }
    }

    private func tearDownCapture() {
        stateLock.lock()
        captureGeneration &+= 1
        stateLock.unlock()
        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        if let deviceDisconnectObserver {
            NotificationCenter.default.removeObserver(deviceDisconnectObserver)
            self.deviceDisconnectObserver = nil
        }
        guard let session else {
            forwarder = nil
            return
        }
        session.stopRunning()
        self.session = nil
        forwarder = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval, from generation: Int) {
        stateLock.lock()
        let shouldWrite = recordingActive && generation == captureGeneration && !paused.value
        stateLock.unlock()
        guard shouldWrite, buffer.frameLength > 0, !writeFailed else { return }

        do {
            // This is the durability boundary: every capture buffer reaches
            // the CAF file before any derived level update is delivered.
            if let timelineWriter { try timelineWriter.write(buffer, hostTime: hostTime) }
            else { try audioFile?.write(from: buffer) }
        } catch {
            writeFailed = true
            onError?("Microphone audio could not be saved. \(error.localizedDescription)")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let emitLevel = now >= nextLevelTime
        if emitLevel { nextLevelTime = now + 0.1 }
        let callback = emitLevel ? onLevel : nil
        stateLock.unlock()
        if let callback {
            callback(MicAudioProcessing.level(of: buffer))
        }
    }
}

/// Format and signal operations shared by capture and hardware-free tests.
enum MicAudioProcessing {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    static func convertedFrameCapacity(
        sourceFrames: AVAudioFrameCount,
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> AVAudioFrameCount {
        guard sourceFrames > 0, sourceSampleRate > 0, targetSampleRate > 0 else { return 0 }
        return AVAudioFrameCount(ceil(Double(sourceFrames) * targetSampleRate / sourceSampleRate)) + 32
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        return level(of: samples)
    }

    static func level(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { level(of: $0) }
    }

    static func convert(
        _ source: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat = targetFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw MicRecorder.MicError.deviceUnavailable
        }
        configure(converter)
        let capacity = convertedFrameCapacity(
            sourceFrames: source.frameLength,
            sourceSampleRate: source.format.sampleRate,
            targetSampleRate: targetFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw MicRecorder.MicError.deviceUnavailable
        }
        try fill(output, using: converter, source: source)
        return output
    }

    static func configure(_ converter: AVAudioConverter) {
        converter.downmix = true
        converter.primeMethod = .none
    }

    static func fill(
        _ output: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        source: AVAudioPCMBuffer
    ) throws {
        output.frameLength = 0
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
    }

    private static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        let rms = sqrt(sum / Double(samples.count))
        let db = 20 * log10(max(rms, 1e-6))
        return Float(max(0, min(1, (db + 50) / 50)))
    }
}

/// Converts each self-describing capture buffer. Rebuilding the converter
/// when the ASBD changes tolerates Bluetooth profile and sample-rate flips.
private final class MicSampleForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let targetFormat: AVAudioFormat
    private let onPCM: (AVAudioPCMBuffer, TimeInterval) -> Void
    private let hostTime: (CMTime) -> TimeInterval?
    private var sourceDescription: AudioStreamBasicDescription?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var rawBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?

    init(targetFormat: AVAudioFormat, hostTime: @escaping (CMTime) -> TimeInterval?, onPCM: @escaping (AVAudioPCMBuffer, TimeInterval) -> Void) {
        self.targetFormat = targetFormat
        self.hostTime = hostTime
        self.onPCM = onPCM
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return
        }
        let incoming = streamDescription.pointee
        if sourceDescription.map({ !Self.matches($0, incoming) }) ?? true {
            guard let format = AVAudioFormat(streamDescription: streamDescription),
                  let converter = AVAudioConverter(from: format, to: targetFormat) else { return }
            MicAudioProcessing.configure(converter)
            sourceDescription = incoming
            sourceFormat = format
            self.converter = converter
            rawBuffer = nil
            convertedBuffer = nil
        }
        guard let sourceFormat, let converter else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }
        let raw: AVAudioPCMBuffer
        if let rawBuffer, rawBuffer.frameCapacity >= frameCount {
            raw = rawBuffer
        } else {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }
            rawBuffer = buffer
            raw = buffer
        }
        raw.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: raw.mutableAudioBufferList
        ) == noErr else { return }

        let capacity = MicAudioProcessing.convertedFrameCapacity(
            sourceFrames: frameCount,
            sourceSampleRate: sourceFormat.sampleRate,
            targetSampleRate: targetFormat.sampleRate
        )
        let converted: AVAudioPCMBuffer
        if let convertedBuffer, convertedBuffer.frameCapacity >= capacity {
            converted = convertedBuffer
        } else {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            convertedBuffer = buffer
            converted = buffer
        }

        do {
            try MicAudioProcessing.fill(converted, using: converter, source: raw)
        } catch {
            NSLog("Scribe: microphone format conversion failed: %@", error.localizedDescription)
            return
        }
        guard converted.frameLength > 0 else { return }
        guard let timestamp = hostTime(sampleBuffer.presentationTimeStamp), timestamp.isFinite else { return }
        onPCM(converted, timestamp)
    }

    private static func matches(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate &&
            lhs.mFormatID == rhs.mFormatID &&
            lhs.mFormatFlags == rhs.mFormatFlags &&
            lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
            lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
            lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
            lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
            lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
