import Foundation
import ScreenCaptureKit

struct RecordingVideoStopResult: Equatable {
    var duration: TimeInterval
    var startOffset: TimeInterval?
}

/// One capture boundary for RecordingSession. Tests replace this driver without
/// asking for native permissions or opening audio and video devices.
@MainActor
protocol RecordingCaptureDriving: AnyObject {
    var hasMicrophone: Bool { get }
    var hasSystemAudio: Bool { get }

    func requestMicrophonePermission() async -> Bool
    func prepareVideo(_ mode: VideoCaptureMode) async throws
    func start(
        mode: RecordingMode,
        folder: URL,
        processes: [UInt32]?,
        clock: RecordingClock,
        muteSyncApplication: RecordingApplication?,
        onMuteState: @escaping @Sendable (MeetingMuteObservation) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void,
        onMicLevel: @escaping @Sendable (Float) -> Void,
        onSystemLevel: @escaping @Sendable (Float) -> Void,
        onFirstVideoFrame: @escaping @Sendable (TimeInterval) -> Void
    ) async throws
    func updateProcesses(_ processes: [UInt32]) throws
    func setPaused(_ paused: Bool)
    func stopAudio()
    func stopVideo() async throws -> RecordingVideoStopResult?
    func cancelStart() async
    func close()
}

struct RecordingSessionDependencies {
    var makeCapture: @MainActor () -> any RecordingCaptureDriving
    var availableDiskCapacity: (URL) -> Int64?
    var audioDuration: (URL) -> TimeInterval
    var enqueue: @MainActor (TranscriptionQueue, UUID) -> Void
    var resolveApplication: @MainActor (RecordingApplication) throws -> [UInt32] = { try ApplicationAudioResolver.resolve($0) }

    static let live = RecordingSessionDependencies(
        makeCapture: { NativeRecordingCaptureDriver() },
        availableDiskCapacity: { url in
            var candidate = url
            while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
                candidate.deleteLastPathComponent()
            }
            let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        },
        audioDuration: audioDuration(of:),
        enqueue: { queue, id in queue.enqueue(id) }
    )
}

@MainActor
private final class NativeRecordingCaptureDriver: RecordingCaptureDriving {
    private let picker = ScreenCapturePicker()
    private var filter: SCContentFilter?
    private var mic: MicRecorder?
    private var tap: SystemAudioTap?
    private var screen: ScreenRecorder?
    private var muteMonitor: MeetingMuteMonitor?

    var hasMicrophone: Bool { mic != nil }
    var hasSystemAudio: Bool { tap != nil }

    func requestMicrophonePermission() async -> Bool {
        await MicRecorder.requestPermission()
    }

    func prepareVideo(_ mode: VideoCaptureMode) async throws {
        filter = try await picker.select(mode)
    }

    func start(
        mode: RecordingMode,
        folder: URL,
        processes: [UInt32]?,
        clock: RecordingClock,
        muteSyncApplication: RecordingApplication?,
        onMuteState: @escaping @Sendable (MeetingMuteObservation) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void,
        onMicLevel: @escaping @Sendable (Float) -> Void,
        onSystemLevel: @escaping @Sendable (Float) -> Void,
        onFirstVideoFrame: @escaping @Sendable (TimeInterval) -> Void
    ) async throws {
        let gate = mode == .meeting && muteSyncApplication != nil ? MeetingMicrophoneGate() : nil
        // Opening a Bluetooth microphone can change the output sample rate.
        // Settle the microphone route before configuring the app-audio tap.
        if mode.usesMic {
            let mic = MicRecorder()
            self.mic = mic
            try mic.start(
                writingTo: folder.appendingPathComponent("microphone.caf"),
                clock: clock,
                meetingMuteGate: gate,
                onError: onError,
                onWarning: onWarning,
                onLevel: onMicLevel
            )
        }
        if let gate, let muteSyncApplication {
            let monitor = MeetingMuteMonitor(application: muteSyncApplication, gate: gate, onUpdate: onMuteState)
            muteMonitor = monitor
            monitor.start()
        }
        if mode.usesSystem {
            let tap = SystemAudioTap()
            self.tap = tap
            try tap.start(
                writingTo: folder.appendingPathComponent("system.caf"),
                processes: processes,
                clock: clock,
                onError: onError,
                onLevel: onSystemLevel
            )
        }
        if let filter {
            let screen = ScreenRecorder()
            self.screen = screen
            try await screen.start(
                filter: filter,
                writingTo: folder.appendingPathComponent("screen.mov"),
                clock: clock,
                onError: onError,
                onFirstFrame: onFirstVideoFrame
            )
        }
    }

    func updateProcesses(_ processes: [UInt32]) throws {
        try tap?.updateProcesses(processes)
    }

    func setPaused(_ paused: Bool) {
        if muteMonitor != nil { mic?.setPaused(paused) }
    }

    func stopAudio() {
        muteMonitor?.stop()
        muteMonitor = nil
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
    }

    func stopVideo() async throws -> RecordingVideoStopResult? {
        guard let screen else { return nil }
        defer { self.screen = nil }
        let duration = try await screen.stop()
        return RecordingVideoStopResult(duration: duration, startOffset: screen.startOffset)
    }

    func cancelStart() async {
        picker.cancel()
        stopAudio()
        // Session cleanup awaits startup before stopping video.
    }

    func close() {
        picker.close()
        filter = nil
    }
}
