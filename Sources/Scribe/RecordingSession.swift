import Foundation
import SwiftUI
import ScreenCaptureKit

enum RecordingMode: String, CaseIterable, Identifiable {
    case meeting
    case systemOnly
    case microphoneOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting (mic + system)"
        case .systemOnly: return "System audio only"
        case .microphoneOnly: return "Microphone only"
        }
    }

    var subtitle: String {
        switch self {
        case .meeting: return "Records both sides of Zoom, Teams, Meet, FaceTime or browser calls"
        case .systemOnly: return "Only what your Mac plays, including the other side of a call, a video, or a podcast"
        case .microphoneOnly: return "Only your voice, for memos and in-person meetings"
        }
    }

    var icon: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .systemOnly: return "macbook.and.wave.form"
        case .microphoneOnly: return "mic"
        }
    }

    var usesMic: Bool { self != .systemOnly }
    var usesSystem: Bool { self != .microphoneOnly }
}

/// Fixed-size source-level history. Audio callbacks can arrive faster than a
/// display needs, so this also limits captured samples to a stable cadence.
struct LevelHistory: Equatable {
    static let samplesPerSecond = 20
    static let duration: TimeInterval = 60
    static let defaultCapacity = Int(Double(samplesPerSecond) * duration)
    static let defaultMinimumInterval = 1 / Double(samplesPerSecond)

    let capacity: Int
    let minimumInterval: TimeInterval
    private var storage: [Float]
    private var nextIndex = 0
    private var count = 0
    private var lastAppendTime: TimeInterval?

    init(capacity: Int = LevelHistory.defaultCapacity, minimumInterval: TimeInterval = LevelHistory.defaultMinimumInterval) {
        precondition(capacity > 0, "Level history needs room for at least one sample.")
        self.capacity = capacity
        self.minimumInterval = minimumInterval
        storage = Array(repeating: 0, count: capacity)
    }

    var samples: [Float] {
        guard count > 0 else { return [] }
        guard count == capacity else { return Array(storage.prefix(count)) }
        return Array(storage[nextIndex...]) + Array(storage[..<nextIndex])
    }

    @discardableResult
    mutating func append(_ level: Float, at time: TimeInterval) -> Bool {
        if let lastAppendTime, time - lastAppendTime < minimumInterval {
            return false
        }

        storage[nextIndex] = min(1, max(0, level))
        nextIndex = (nextIndex + 1) % capacity
        count = min(capacity, count + 1)
        lastAppendTime = time
        return true
    }

    mutating func reset() {
        storage = Array(repeating: 0, count: capacity)
        nextIndex = 0
        count = 0
        lastAppendTime = nil
    }
}

/// Owns an in-flight recording: starts/pauses/stops the mic recorder and
/// system tap, keeps the elapsed clock and level meters, and maintains the
/// crash marker (document saved with status .recording the moment recording
/// starts, so audio is recoverable if the app dies).
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var hasPendingSave = false
    var isBusy: Bool { isRecording || isStarting || isFinalizing || hasPendingSave }
    var pendingSaveDocumentID: UUID? { pendingFinalSave?.document.id }
    @Published private(set) var healthMessage: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micHistory: [Float] = []
    @Published private(set) var systemHistory: [Float] = []
    @Published private(set) var activeDocumentID: UUID?
    @Published private(set) var activeCalendarEventTitle: String?
    @Published var lastError: String?
    private(set) var lastWaveformAppend = Date.distantPast
    static let waveformSampleInterval: TimeInterval = 0.05

    private var mic: MicRecorder?
    private var tap: SystemAudioTap?
    private var screen: ScreenRecorder?
    private let picker = ScreenCapturePicker()
    private var clock: RecordingClock?
    private var application: RecordingApplication?
    private var processIDs: [UInt32] = []
    private var nextProcessCheck: TimeInterval = 0
    private var lastMicCallback: TimeInterval = 0
    private var lastSystemCallback: TimeInterval = 0
    private var timer: Timer?
    private var finalizationTask: Task<Void, Never>?
    private var cancelStart = false
    private var captureFailure: String?
    private var failureState = CaptureFailureState()
    private var pendingFinalSave: (document: ScribeDocument, discard: Bool, enqueue: Bool)?
    private var sampleCount = 0
    private var micLevelHistory = LevelHistory(minimumInterval: 0)
    private var systemLevelHistory = LevelHistory(minimumInterval: 0)

    func start(
        mode: RecordingMode,
        library: LibraryStore,
        calendarEvent: AutoRecordEvent? = nil,
        storeCalendarDetails: Bool = true,
        application: RecordingApplication? = nil,
        videoMode: VideoCaptureMode? = nil,
        microphoneSpeakerName: String = "Me",
        expectedRemoteSpeakerCount: Int? = nil
    ) async {
        guard !isBusy else { return }
        isStarting = true
        cancelStart = false
        lastError = nil
        healthMessage = nil
        captureFailure = nil
        failureState = CaptureFailureState()
        defer { isStarting = false }

        do {
            if mode.usesMic, !(await MicRecorder.requestPermission()) {
                throw MicRecorder.MicError.permissionDenied
            }
            try checkStartCancellation()
            let filter: SCContentFilter?
            if let videoMode { filter = try await picker.select(videoMode) }
            else { filter = nil }
            try checkStartCancellation()
            processIDs = try application.map { try ApplicationAudioResolver.resolve($0) } ?? []
            var doc = ScribeDocument(
                title: calendarEvent?.title ?? application.map { "Meeting · \($0.name)" } ?? Self.defaultTitle(for: mode),
                kind: .recording,
                status: .recording,
                calendarEventID: storeCalendarDetails ? calendarEvent?.eventID : nil,
                calendarEventTitle: storeCalendarDetails ? calendarEvent?.title : nil
            )
            doc.microphoneSpeakerName = microphoneSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Me" : microphoneSpeakerName
            doc.expectedRemoteSpeakerCount = expectedRemoteSpeakerCount.flatMap { $0 > 0 ? $0 : nil }
            doc.recordingAppBundleID = application?.bundleID
            doc.recordingAppName = application?.name
            if mode.usesSystem { doc.tracks.append(AudioTrack(source: .system, fileName: "system.caf", startOffset: 0)) }
            if mode.usesMic { doc.tracks.append(AudioTrack(source: .microphone, fileName: "microphone.caf", speakerName: doc.microphoneSpeakerName, startOffset: 0)) }
            if videoMode != nil { doc.videoTracks = [VideoTrack(fileName: "screen.mov", startOffset: 0, duration: 0)] }
            // Persist every intended file before opening any recorder. A failed save starts no capture.
            guard library.add(doc) else { throw CaptureStartError.message(library.lastError ?? "The recording could not be saved.") }
            activeDocumentID = doc.id
            activeCalendarEventTitle = calendarEvent?.title
            self.application = application
            let folder = library.folder(for: doc.id)
            let clock = RecordingClock()
            self.clock = clock
            elapsed = 0
            lastMicCallback = RecordingClock.now
            lastSystemCallback = RecordingClock.now
            let failureState = self.failureState
            let documentID = doc.id
            let onError: @Sendable (String) -> Void = { [weak self, weak library] message in
                failureState.record(message)
                Task { @MainActor in
                    guard let self, let library, self.activeDocumentID == documentID else { return }
                    self.captureFailure = message
                    self.lastError = message
                    self.healthMessage = message
                    if self.isRecording, !self.isStarting { self.finish(library: library, queue: nil, discard: false) }
                }
            }
            if mode.usesSystem {
                let tap = SystemAudioTap()
                self.tap = tap
                try tap.start(writingTo: folder.appendingPathComponent("system.caf"),
                    processes: application == nil ? nil : processIDs, clock: clock, onError: onError) { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.activeDocumentID == documentID, self.isRecording, !self.isPaused else { return }
                        self.systemLevel = level
                        self.lastSystemCallback = RecordingClock.now
                    }
                }
            }
            if mode.usesMic {
                let mic = MicRecorder()
                self.mic = mic
                try mic.start(writingTo: folder.appendingPathComponent("microphone.caf"), clock: clock,
                    onError: onError, onWarning: { [weak self] message in
                        Task { @MainActor in
                            guard self?.activeDocumentID == documentID else { return }
                            self?.healthMessage = message
                        }
                    }) { [weak self] level in
                        Task { @MainActor in
                            guard let self, self.activeDocumentID == documentID, self.isRecording, !self.isPaused else { return }
                            self.micLevel = level
                            self.lastMicCallback = RecordingClock.now
                        }
                    }
            }
            if let filter {
                let screen = ScreenRecorder()
                self.screen = screen
                try await screen.start(filter: filter, writingTo: folder.appendingPathComponent("screen.mov"), clock: clock,
                    onError: onError, onFirstFrame: { [weak self, weak library] offset in
                        Task { @MainActor in
                            guard let self, self.activeDocumentID == documentID, !self.isFinalizing,
                                  let library, var document = library.document(id: documentID) else { return }
                            document.videoTracks?[0].startOffset = offset
                            if !library.update(document) { onError(library.lastError ?? "The video start time could not be saved.") }
                        }
                    })
            }
            try checkStartCancellation()
            if let message = failureState.message { throw CaptureStartError.message(message) }
            isRecording = true
            isPaused = false
            resetLevelHistories()
            let timer = Timer(timeInterval: Self.waveformSampleInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            clock?.stop()
            mic?.stop()
            tap?.stop()
            mic = nil
            tap = nil
            if let screen { _ = try? await screen.stop() }
            screen = nil
            picker.close()
            if !(error is CancellationError) { lastError = error.localizedDescription }
            if let id = activeDocumentID, var doc = library.document(id: id) {
                doc.status = .recovered
                doc.recoveredAt = Date()
                doc.duration = clock?.time() ?? 0
                doc.failureReason = lastError ?? "Recording setup was cancelled. Any captured files were kept."
                if !library.finalizeRecording(doc) {
                    pendingFinalSave = (doc, false, false)
                    hasPendingSave = true
                    lastError = library.lastError
                }
            }
            activeDocumentID = nil
            activeCalendarEventTitle = nil
        }
    }

    private enum CaptureStartError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }

    private func checkStartCancellation() throws {
        if cancelStart || Task.isCancelled { throw CancellationError() }
    }

    private func tick() {
        guard isRecording, !isPaused else { return }
        elapsed = clock?.time() ?? elapsed
        sampleCount += 1
        let time = Double(sampleCount) * Self.waveformSampleInterval
        if mic != nil, micLevelHistory.append(micLevel, at: time) { micHistory = micLevelHistory.samples }
        if tap != nil, systemLevelHistory.append(systemLevel, at: time) { systemHistory = systemLevelHistory.samples }
        lastWaveformAppend = Date()
        let now = RecordingClock.now
        if now >= nextProcessCheck {
            nextProcessCheck = now + 2
            var warning: String?
            if let application {
                do {
                    let ids = try ApplicationAudioResolver.resolve(application)
                    if ids != processIDs { try tap?.updateProcesses(ids); processIDs = ids }
                } catch { warning = error.localizedDescription }
            }
            if mic != nil, now - lastMicCallback > 4 { warning = "No microphone data is arriving. Check the input device." }
            if tap != nil, now - lastSystemCallback > 4 { warning = "No app audio data is arriving. Check the selected app and audio permissions." }
            healthMessage = warning
        }
    }

    private func resetLevelHistories() {
        micLevelHistory.reset()
        systemLevelHistory.reset()
        micHistory = []
        systemHistory = []
        sampleCount = 0
        lastWaveformAppend = .distantPast
    }

    func togglePause() {
        guard isRecording, !isStarting, !isFinalizing else { return }
        if isPaused {
            clock?.resume()
            lastMicCallback = RecordingClock.now
            lastSystemCallback = RecordingClock.now
        } else { clock?.pause() }
        isPaused.toggle()
        elapsed = clock?.time() ?? elapsed
        // Source timestamps decide which queued samples belong to the pause.
        micLevel = 0
        systemLevel = 0
    }

    func stop(library: LibraryStore, queue: TranscriptionQueue) {
        finish(library: library, queue: queue, discard: false)
    }

    func discard(library: LibraryStore) {
        finish(library: library, queue: nil, discard: true)
    }

    private func finish(library: LibraryStore, queue: TranscriptionQueue?, discard: Bool) {
        guard isRecording, !isFinalizing, let docID = activeDocumentID else { return }
        isFinalizing = true
        clock?.stop()
        elapsed = clock?.time() ?? elapsed
        timer?.invalidate()
        timer = nil
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
        micLevel = 0
        systemLevel = 0
        resetLevelHistories()
        finalizationTask = Task { @MainActor in
            defer {
                self.screen = nil
                self.picker.close()
                self.isRecording = false
                self.isPaused = false
                self.isFinalizing = false
                self.activeDocumentID = nil
                self.activeCalendarEventTitle = nil
                self.finalizationTask = nil
            }
            var videoDuration: TimeInterval?
            if let screen = self.screen {
                do { videoDuration = try await screen.stop() }
                catch { self.captureFailure = error.localizedDescription; self.lastError = error.localizedDescription }
            }
            guard var doc = library.document(id: docID) else { return }
            doc.duration = max(self.elapsed, doc.tracks.map {
                ($0.startOffset ?? 0) + audioDuration(of: library.folder(for: doc.id).appendingPathComponent($0.fileName))
            }.max() ?? 0)
            if let videoDuration, doc.videoTracks?.isEmpty == false {
                doc.videoTracks?[0].duration = videoDuration
                let offset = self.screen?.startOffset ?? doc.videoTracks?[0].startOffset ?? 0
                doc.videoTracks?[0].startOffset = offset
            }
            self.captureFailure = self.failureState.message ?? self.captureFailure
            doc.status = self.captureFailure == nil && !discard ? .queued : .recovered
            if doc.status == .recovered { doc.recoveredAt = doc.recoveredAt ?? Date() }
            doc.failureReason = self.captureFailure
            guard library.finalizeRecording(doc) else {
                self.pendingFinalSave = (doc, discard, self.captureFailure == nil && queue != nil)
                self.hasPendingSave = true
                self.lastError = library.lastError
                return
            }
            if discard {
                if !library.delete(doc) { self.lastError = library.lastError }
            } else if self.captureFailure == nil {
                queue?.enqueue(doc.id)
            }
        }
    }

    func retryFinalSave(library: LibraryStore, queue: TranscriptionQueue) {
        guard let pending = pendingFinalSave else { return }
        // Keep any title or note edits made while the save was pending.
        var doc = library.document(id: pending.document.id) ?? pending.document
        doc.status = pending.document.status
        doc.failureReason = pending.document.failureReason
        doc.duration = pending.document.duration
        doc.tracks = pending.document.tracks
        doc.videoTracks = pending.document.videoTracks
        guard library.finalizeRecording(doc) else { lastError = library.lastError; return }
        hasPendingSave = false
        pendingFinalSave = nil
        lastError = nil
        if pending.discard {
            if !library.delete(doc) { lastError = library.lastError }
        } else if pending.enqueue { queue.enqueue(doc.id) }
    }

    func prepareToQuit(library: LibraryStore, queue: TranscriptionQueue) async {
        if isStarting {
            cancelStart = true
            picker.cancel()
            while isStarting { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        if isRecording, !isFinalizing { stop(library: library, queue: queue) }
        await finalizationTask?.value
        if hasPendingSave { retryFinalSave(library: library, queue: queue) }
    }

    private static func defaultTitle(for mode: RecordingMode) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let kind: String
        switch mode {
        case .meeting: kind = "Meeting"
        case .systemOnly: kind = "System Audio"
        case .microphoneOnly: kind = "Voice Memo"
        }
        return "\(kind), \(formatter.string(from: Date()))"
    }
}

/// Capture callbacks record failures before crossing to the UI actor, so stop cannot outrun them.
private final class CaptureFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = message }
    }
}
