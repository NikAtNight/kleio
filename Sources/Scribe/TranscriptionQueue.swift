import Foundation
import SwiftUI
import AVFoundation

/// Transcription and speaker analysis share a serial queue so large local
/// models do not process competing documents at the same time.
@MainActor
final class TranscriptionQueue: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var livePreview: [UUID: String] = [:]
    @Published private(set) var pendingCount = 0

    let transcriber = Transcriber()
    let speakerDiarizer = SpeakerDiarizer()

    private struct Job {
        var documentID: UUID
        var speakersOnly: Bool
    }
    private var pending: [Job] = []
    private var currentDocumentID: UUID?
    private var processingTask: Task<Void, Never>?
    private weak var library: LibraryStore?
    private weak var modelManager: ModelManager?
    private weak var replacementStore: ReplacementStore?
    private var attendeeNamesProvider: ((String) -> [String])?

    func configure(
        library: LibraryStore,
        modelManager: ModelManager,
        replacementStore: ReplacementStore,
        attendeeNamesProvider: ((String) -> [String])? = nil
    ) {
        self.library = library
        self.modelManager = modelManager
        self.replacementStore = replacementStore
        self.attendeeNamesProvider = attendeeNamesProvider
    }

    nonisolated static func mergedKnownSpeakers(
        _ existing: [String]?,
        adding names: [String],
        limit: Int = 8
    ) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for name in (existing ?? []) + names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            merged.append(trimmed)
            if merged.count == limit { break }
        }
        return merged
    }

    nonisolated static func transcriptionInputs(
        for document: ScribeDocument, folder: URL
    ) throws -> (tracks: [AudioTrack], omitted: [String]) {
        var available: [AudioTrack] = []
        var omitted: [String] = []
        for track in document.tracks {
            do {
                let file = try AVAudioFile(forReading: folder.appendingPathComponent(track.fileName))
                guard file.length > 0, file.processingFormat.sampleRate > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(min(file.length, 1_024))) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                available.append(track)
            } catch {
                omitted.append(sourceDescription(for: track))
            }
        }
        guard !available.isEmpty else {
            throw inputError("No usable audio remains in this recording. Its original media references have been kept.", omitted: omitted)
        }
        if document.recoveredAt == nil, document.status != .recovered, !omitted.isEmpty {
            throw inputError("Audio is missing, empty, or unreadable. Restore these files before retrying transcription.", omitted: omitted)
        }
        return (available, omitted)
    }

    private nonisolated static func sourceDescription(for track: AudioTrack) -> String {
        let source: String
        switch track.source {
        case .microphone: source = "Microphone"
        case .system: source = "App audio"
        case .imported: source = track.speakerName ?? "Imported audio"
        }
        return "\(source) (\(track.fileName))"
    }

    private nonisolated static func inputError(_ message: String, omitted: [String]) -> Error {
        NSError(domain: "Scribe.TranscriptionInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message + (omitted.isEmpty ? "" : " " + omitted.joined(separator: ", "))])
    }

    private nonisolated static func recoveryWarning(omitted: [String]) -> String? {
        guard !omitted.isEmpty else { return nil }
        return "Partial transcript from recovered audio. These sources were unavailable or could not be transcribed: "
            + omitted.joined(separator: ", ") + ". Their original media references have been kept."
    }

    func enqueue(_ docID: UUID) {
        guard currentDocumentID != docID, !pending.contains(where: { $0.documentID == docID }),
              var doc = library?.document(id: docID), doc.status != .recording else { return }
        if doc.status == .recovered { doc.recoveredAt = doc.recoveredAt ?? Date() }
        doc.status = .queued
        doc.failureReason = nil
        library?.update(doc)
        pending.append(Job(documentID: docID, speakersOnly: false))
        pendingCount = pending.count
        pump()
    }

    func retrySpeakerAnalysis(_ docID: UUID) {
        guard currentDocumentID != docID, !pending.contains(where: { $0.documentID == docID }),
              let doc = library?.document(id: docID), doc.status == .ready,
              !doc.segments.isEmpty else { return }
        pending.append(Job(documentID: docID, speakersOnly: true))
        pendingCount = pending.count
        pump()
    }

    func cancelCurrent() {
        transcriber.cancelCurrent()
        processingTask?.cancel()
    }

    private func pump() {
        guard currentDocumentID == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        currentDocumentID = job.documentID
        pendingCount = pending.count
        processingTask = Task {
            if job.speakersOnly {
                await analyzeSpeakers(job.documentID, forceImports: true)
            } else {
                await transcribe(job.documentID)
            }
            progress[job.documentID] = nil
            livePreview[job.documentID] = nil
            currentDocumentID = nil
            processingTask = nil
            pump()
        }
    }

    private func transcribe(_ docID: UUID) async {
        guard let library, let modelManager,
              var original = library.document(id: docID) else { return }
        original.status = .transcribing
        original.failureReason = nil
        library.update(original)
        progress[docID] = 0

        let language = UserDefaults.standard.string(forKey: "language") ?? ""
        let translate = UserDefaults.standard.bool(forKey: "translate")
        let model = modelManager.selectedVariant
        let startedAt = Date()
        do {
            try Task.checkCancellation()
            let folder = library.folder(for: docID)
            let inputs = try Self.transcriptionInputs(for: original, folder: folder)
            var omitted = inputs.omitted
            original.transcriptionWarning = Self.recoveryWarning(omitted: omitted)
            library.update(original)
            try await transcriber.load(model: model)
            var allSegments: [TranscriptSegment] = []
            var completedTracks = 0
            let trackCount = Double(inputs.tracks.count)
            for (index, track) in inputs.tracks.enumerated() {
                try Task.checkCancellation()
                let base = Double(index) / trackCount
                var segments: [TranscriptSegment]
                do {
                    segments = try await transcriber.transcribe(
                        file: folder.appendingPathComponent(track.fileName), source: track.source,
                        language: language.isEmpty ? nil : language, translate: translate,
                        onProgress: { [weak self] fraction, text in
                            Task { @MainActor in
                                guard let self, self.currentDocumentID == docID,
                                      self.library?.document(id: docID)?.status == .transcribing else { return }
                                self.progress[docID] = base + fraction / trackCount
                                self.livePreview[docID] = text
                            }
                        }
                    )
                    completedTracks += 1
                } catch {
                    try Task.checkCancellation()
                    if case Transcriber.TranscriberError.cancelled = error { throw error }
                    guard original.recoveredAt != nil else { throw error }
                    omitted.append(Self.sourceDescription(for: track))
                    continue
                }
                let offset = track.startOffset ?? 0
                for index in segments.indices {
                    segments[index].start += offset
                    segments[index].end += offset
                    segments[index].words = segments[index].words?.map {
                        var word = $0
                        word.start += offset
                        word.end += offset
                        return word
                    }
                    if track.source == .microphone {
                        segments[index].speaker = original.microphoneSpeakerName ?? "You"
                    } else if let name = track.speakerName {
                        segments[index].speaker = name
                    } else if track.source == .system {
                        segments[index].speaker = original.expectedRemoteSpeakerCount == 1
                            ? "Speaker 1" : "Unanalyzed audio"
                    }
                }
                allSegments.append(contentsOf: segments)
            }
            try Task.checkCancellation()
            guard completedTracks > 0 else {
                throw Self.inputError("None of the recovered audio sources could be transcribed. The media has been kept.", omitted: omitted)
            }
            allSegments.sort { $0.start < $1.start }
            guard var fresh = library.document(id: docID) else { return }
            // Keep the earliest raw transcript and any edits made while this
            // transcription was running.
            fresh.rawSegments = fresh.rawSegments ?? allSegments
            if fresh.segments == original.segments {
                fresh.segments = allSegments
                fresh.speakers = nil
                fresh.normalizeSpeakerIdentities()
            }
            fresh.status = .ready
            fresh.modelUsed = model
            fresh.language = language.isEmpty ? nil : language
            fresh.failureReason = nil
            fresh.transcriptionWarning = Self.recoveryWarning(omitted: omitted)
            library.update(fresh)
            await analyzeSpeakers(docID, forceImports: false, applyCleanup: true)
            DiagLog.log("transcription completed for document %@ using model %@: %.1fs, %d segments",
                        docID.uuidString, model, Date().timeIntervalSince(startedAt), allSegments.count)
        } catch {
            guard var fresh = library.document(id: docID) else { return }
            fresh.status = .failed
            fresh.failureReason = error.localizedDescription
            library.update(fresh)
            DiagLog.log("transcription failed for document %@: %@", docID.uuidString, error.localizedDescription)
        }
    }

    private func analyzeSpeakers(_ docID: UUID, forceImports: Bool, applyCleanup: Bool = false) async {
        guard let library, var baseline = library.document(id: docID) else { return }
        baseline.speakerAnalysisStatus = .running
        baseline.speakerAnalysisError = nil
        library.update(baseline)
        livePreview[docID] = "Analyzing remote speakers locally…"
        progress[docID] = nil
        let model = SpeakerDetectionModel.selected
        let diarizer = speakerDiarizer
        let analysis = await SpeakerAnalysis.run(
            baseline, folder: library.folder(for: docID), model: model,
            analyzeImports: forceImports || UserDefaults.standard.bool(forKey: "automaticSpeakerRecognition"),
            splitAtSpeakerChanges: baseline.speakerEditsApplied != true
        ) { url, model, count in
            try await diarizer.intervals(for: url, model: model, expectedSpeakerCount: count)
        }
        guard var fresh = library.document(id: docID) else { return }
        let unchanged = fresh.segments == baseline.segments && fresh.speakers == baseline.speakers
        fresh = SpeakerAnalysis.applying(analysis, to: fresh, basedOn: baseline)
        if applyCleanup, unchanged, let replacementStore {
            fresh.segments = replacementStore.apply(to: fresh.segments)
        }
        if let eventID = fresh.calendarEventID {
            fresh.knownSpeakers = Self.mergedKnownSpeakers(
                fresh.knownSpeakers, adding: attendeeNamesProvider?(eventID) ?? [],
                limit: max(8, (fresh.knownSpeakers ?? []).count)
            )
        }
        library.update(fresh)
        if fresh.status == .ready { Exporter.exportAutomaticallyIfNeeded(fresh) }
    }
}
