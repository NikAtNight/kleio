import Foundation
import SwiftUI

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
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micHistory: [Float] = []
    @Published private(set) var systemHistory: [Float] = []
    @Published private(set) var activeDocumentID: UUID?
    @Published private(set) var activeCalendarEventTitle: String?
    @Published var lastError: String?

    /// When the newest waveform sample landed; the live waveform interpolates
    /// its scroll position from this. Not published: it always changes in the
    /// same tick as the published history arrays.
    private(set) var lastWaveformAppend = Date.distantPast

    /// The waveform is sampled on a fixed clock, not on recorder callbacks —
    /// callbacks arrive at ~10 Hz with jitter, which made the waveform stutter.
    static let waveformSampleInterval: TimeInterval = 0.05

    private var mic: MicRecorder?
    private var tap: SystemAudioTap?
    private var timer: Timer?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var sampleCount = 0
    private var micLevelHistory = LevelHistory(minimumInterval: 0)
    private var systemLevelHistory = LevelHistory(minimumInterval: 0)

    func start(
        mode: RecordingMode,
        library: LibraryStore,
        calendarEvent: AutoRecordEvent? = nil,
        storeCalendarDetails: Bool = true
    ) async {
        guard !isRecording else { return }
        lastError = nil

        if mode.usesMic {
            guard await MicRecorder.requestPermission() else {
                lastError = MicRecorder.MicError.permissionDenied.localizedDescription
                return
            }
        }

        var doc = ScribeDocument(
            title: calendarEvent?.title ?? Self.defaultTitle(for: mode),
            kind: .recording,
            status: .recording,
            calendarEventID: storeCalendarDetails ? calendarEvent?.eventID : nil,
            calendarEventTitle: storeCalendarDetails ? calendarEvent?.title : nil
        )
        let folder = LibraryStore.folder(for: doc.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
            return
        }

        if mode.usesSystem {
            let track = AudioTrack(source: .system, fileName: "system.caf")
            let tap = SystemAudioTap()
            do {
                try tap.start(writingTo: folder.appendingPathComponent(track.fileName)) { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.receiveSystemLevel(level)
                    }
                }
                self.tap = tap
                doc.tracks.append(track)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }

        if mode.usesMic {
            let track = AudioTrack(source: .microphone, fileName: "microphone.caf")
            let mic = MicRecorder()
            do {
                try mic.start(writingTo: folder.appendingPathComponent(track.fileName)) { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.receiveMicLevel(level)
                    }
                }
                self.mic = mic
                doc.tracks.append(track)
            } catch {
                tap?.stop()
                tap = nil
                lastError = error.localizedDescription
                return
            }
        }

        // Persist immediately: this is the crash marker that makes the
        // recording recoverable if the app dies.
        library.add(doc)
        activeDocumentID = doc.id
        activeCalendarEventTitle = calendarEvent?.title

        isRecording = true
        isPaused = false
        accumulated = 0
        segmentStart = Date()
        elapsed = 0
        resetLevelHistories()
        let timer = Timer(timeInterval: Self.waveformSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fixed 20 Hz clock: updates the elapsed readout and samples the current
    /// levels into the waveform histories (sample-and-hold between recorder
    /// callbacks), so bars advance on a steady beat the view can animate against.
    private func tick() {
        guard isRecording, !isPaused, let segmentStart else { return }
        elapsed = accumulated + Date().timeIntervalSince(segmentStart)

        sampleCount += 1
        let time = Double(sampleCount) * Self.waveformSampleInterval
        if mic != nil, micLevelHistory.append(micLevel, at: time) {
            micHistory = micLevelHistory.samples
        }
        if tap != nil, systemLevelHistory.append(systemLevel, at: time) {
            systemHistory = systemLevelHistory.samples
        }
        lastWaveformAppend = Date()
    }

    private func receiveMicLevel(_ level: Float) {
        guard isRecording, !isPaused else { return }
        micLevel = level
    }

    private func receiveSystemLevel(_ level: Float) {
        guard isRecording, !isPaused else { return }
        systemLevel = level
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
        guard isRecording else { return }
        if isPaused {
            segmentStart = Date()
            isPaused = false
        } else {
            if let segmentStart {
                accumulated += Date().timeIntervalSince(segmentStart)
            }
            segmentStart = nil
            isPaused = true
        }
        mic?.setPaused(isPaused)
        tap?.setPaused(isPaused)
        micLevel = 0
        systemLevel = 0
    }

    /// Stops recorders, finalizes the document, and hands it to the
    /// transcription queue.
    func stop(library: LibraryStore, queue: TranscriptionQueue) {
        guard isRecording, let docID = activeDocumentID else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil

        isRecording = false
        isPaused = false
        micLevel = 0
        systemLevel = 0
        resetLevelHistories()
        activeDocumentID = nil
        activeCalendarEventTitle = nil

        guard var doc = library.document(id: docID) else { return }
        let folder = LibraryStore.folder(for: doc.id)
        doc.duration = doc.tracks
            .map { audioDuration(of: folder.appendingPathComponent($0.fileName)) }
            .max() ?? elapsed
        doc.status = .queued
        library.update(doc)
        queue.enqueue(doc.id)
    }

    /// Abandon and delete the in-flight recording.
    func discard(library: LibraryStore) {
        guard isRecording, let docID = activeDocumentID else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
        isRecording = false
        isPaused = false
        micLevel = 0
        systemLevel = 0
        resetLevelHistories()
        activeDocumentID = nil
        activeCalendarEventTitle = nil
        if let doc = library.document(id: docID) {
            library.delete(doc)
        }
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
