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
        case .systemOnly: return "Only what your Mac plays — the other side of a call, a video, a podcast"
        case .microphoneOnly: return "Only your voice — memos, in-person meetings"
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
    @Published private(set) var activeDocumentID: UUID?
    @Published var lastError: String?

    private var mic: MicRecorder?
    private var tap: SystemAudioTap?
    private var timer: Timer?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0

    func start(mode: RecordingMode, library: LibraryStore) async {
        guard !isRecording else { return }
        lastError = nil

        if mode.usesMic {
            guard await MicRecorder.requestPermission() else {
                lastError = MicRecorder.MicError.permissionDenied.localizedDescription
                return
            }
        }

        var doc = ScribeDocument(
            title: Self.defaultTitle(for: mode),
            kind: .recording,
            status: .recording
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
                    Task { @MainActor in self?.systemLevel = level }
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
                    Task { @MainActor in self?.micLevel = level }
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

        isRecording = true
        isPaused = false
        accumulated = 0
        segmentStart = Date()
        elapsed = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isRecording, !isPaused, let segmentStart else { return }
        elapsed = accumulated + Date().timeIntervalSince(segmentStart)
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
        activeDocumentID = nil

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
        activeDocumentID = nil
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
        return "\(kind) — \(formatter.string(from: Date()))"
    }
}
