import Foundation
import SwiftUI
import Combine

/// Model execution is replaceable so queue ordering is tested with real manifests.
protocol TranscriptionEngine: Sendable {
    func load(model: String) async throws
    func transcribe(file: URL, source: AudioSource, language: String?, translate: Bool,
                    onProgress: (@Sendable (Double, String) -> Void)?) async throws -> [TranscriptSegment]
    func cancelCurrent()
}

extension Transcriber: TranscriptionEngine {}

/// Transcription and speaker analysis share a serial queue so large local
/// models do not process competing documents at the same time.
@MainActor
final class TranscriptionQueue: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var livePreview: [UUID: String] = [:]
    @Published private(set) var pendingCount = 0

    @Published private(set) var pendingSaveIDs: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var currentDocumentID: UUID?
    var isBusy: Bool { currentDocumentID != nil || !pending.isEmpty || !pendingSaves.isEmpty }

    struct Options {
        var model: String
        var language: String? = nil
        var translate = false
        var speakerModel: SpeakerDetectionModel = .community1
        var analyzeImports = false
    }

    private enum Work {
        case transcription(allowPartialAudio: Bool)
        case speakers
        case save
    }
    private struct Job {
        let id = UUID()
        let documentID: UUID
        let work: Work
    }
    private enum PendingSave {
        case beginTranscription(allowPartialAudio: Bool)
        case transcript(baseline: ScribeDocument, segments: [TranscriptSegment], options: Options, warning: String?)
        case beginAnalysis(forceImports: Bool, applyCleanup: Bool)
        case analysis(baseline: ScribeDocument, result: ScribeDocument, applyCleanup: Bool)
        case failure(message: String, speakersOnly: Bool)
    }

    private let transcriber: any TranscriptionEngine
    private let inferSpeakers: SpeakerAnalysis.Inference
    private let exportAutomatically: (ScribeDocument) -> Void
    private var pending: [Job] = []
    private var pendingSaves: [UUID: PendingSave] = [:]
    private var currentJobID: UUID?
    private var processingTask: Task<Void, Never>?
    private var preparingToQuit = false
    private weak var library: LibraryStore?
    private var optionsProvider: (() -> Options?)?
    private var cleanup: ([TranscriptSegment]) -> [TranscriptSegment] = { $0 }
    private var attendeeNamesProvider: ((String) -> [String])?
    private var libraryObservation: AnyCancellable?

    init(transcriber: any TranscriptionEngine = Transcriber(),
         inferSpeakers: SpeakerAnalysis.Inference? = nil,
         exportAutomatically: @escaping (ScribeDocument) -> Void = Exporter.exportAutomaticallyIfNeeded) {
        self.transcriber = transcriber
        if let inferSpeakers {
            self.inferSpeakers = inferSpeakers
        } else {
            let diarizer = SpeakerDiarizer()
            self.inferSpeakers = { url, model, count in
                try await diarizer.intervals(for: url, model: model, expectedSpeakerCount: count)
            }
        }
        self.exportAutomatically = exportAutomatically
    }

    func configure(
        library: LibraryStore,
        modelManager: ModelManager,
        replacementStore: ReplacementStore,
        attendeeNamesProvider: ((String) -> [String])? = nil
    ) {
        configure(library: library, options: { [weak modelManager] in
            guard let modelManager else { return nil }
            let language = UserDefaults.standard.string(forKey: "language") ?? ""
            return Options(model: modelManager.selectedVariant, language: language.isEmpty ? nil : language,
                           translate: UserDefaults.standard.bool(forKey: "translate"),
                           speakerModel: SpeakerDetectionModel.selected,
                           analyzeImports: UserDefaults.standard.bool(forKey: "automaticSpeakerRecognition"))
        }, cleanup: { [weak replacementStore] segments in
            replacementStore?.apply(to: segments) ?? segments
        }, attendeeNamesProvider: attendeeNamesProvider)
    }

    func configure(library: LibraryStore, options: @escaping () -> Options?,
                   cleanup: @escaping ([TranscriptSegment]) -> [TranscriptSegment] = { $0 },
                   attendeeNamesProvider: ((String) -> [String])? = nil) {
        self.library = library
        optionsProvider = options
        self.cleanup = cleanup
        self.attendeeNamesProvider = attendeeNamesProvider
        libraryObservation = library.$documents.sink { [weak self] documents in
            self?.removeDeletedDocuments(keeping: Set(documents.map(\.id)))
        }
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
        for document: ScribeDocument, folder: URL, allowPartialAudio: Bool = false
    ) throws -> (tracks: [AudioTrack], omitted: [String]) {
        let availability = RecordingAudioAvailability.inspect(document, folder: folder)
        let available = availability.availableTracks
        let omitted = availability.unavailable.map { sourceDescription(for: $0.track) }
        guard !available.isEmpty else {
            throw inputError("No usable audio remains in this recording. Its original media references have been kept.", omitted: omitted)
        }
        if !allowPartialAudio, !omitted.isEmpty {
            throw inputError("Audio is missing, empty, or unreadable. Restore these files before retrying transcription.", omitted: omitted)
        }
        return (available, omitted)
    }

    private nonisolated static func sourceDescription(for track: AudioTrack) -> String {
        let source = RecordingAudioAvailability.name(for: track)
        return "\(source) (\(track.fileName))"
    }

    private nonisolated static func inputError(_ message: String, omitted: [String]) -> Error {
        NSError(domain: "Scribe.TranscriptionInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message + (omitted.isEmpty ? "" : " " + omitted.joined(separator: ", "))])
    }

    private nonisolated static func recoveryWarning(omitted: [String]) -> String? {
        guard !omitted.isEmpty else { return nil }
        return "Partial transcript from available audio. These sources were unavailable or could not be transcribed: "
            + omitted.joined(separator: ", ") + ". Their original media references have been kept."
    }

    /// Apply completed decoding against the latest saved version, keeping the
    /// original transcript and giving edits made during the job precedence.
    nonisolated static func applyingTranscript(
        _ decoded: [TranscriptSegment], to current: ScribeDocument, basedOn baseline: ScribeDocument,
        transcriptionWarning: String? = nil
    ) -> ScribeDocument {
        var updated = current
        updated.rawSegments = current.rawSegments ?? (baseline.segments.isEmpty ? decoded : baseline.segments)
        if canReplaceTranscript(current, basedOn: baseline) {
            updated.segments = TranscriptTiming.chronologicalTurns(from: decoded)
            updated.speakers = nil
            updated.normalizeSpeakerIdentities()
            updated.transcriptionWarning = transcriptionWarning
        }
        return updated
    }

    private nonisolated static func canReplaceTranscript(_ current: ScribeDocument, basedOn baseline: ScribeDocument) -> Bool {
        current.segments == baseline.segments && current.speakers == baseline.speakers
            && current.microphoneSpeakerName == baseline.microphoneSpeakerName
            && current.speakerEditsApplied == baseline.speakerEditsApplied
    }

    func enqueue(_ docID: UUID, allowPartialAudio: Bool = false) {
        guard !preparingToQuit, canEnqueue(docID), let library,
              !library.pendingRecordingSaveIDs.contains(docID),
              var doc = library.document(id: docID), doc.status != .recording else { return }
        errors[docID] = nil
        doc.status = .queued
        doc.failureReason = nil
        guard library.update(doc) else {
            retain(.beginTranscription(allowPartialAudio: allowPartialAudio), for: docID)
            return
        }
        append(docID, work: .transcription(allowPartialAudio: allowPartialAudio))
    }

    func retrySpeakerAnalysis(_ docID: UUID) {
        guard !preparingToQuit, canEnqueue(docID), let doc = library?.document(id: docID), doc.status == .ready,
              !doc.segments.isEmpty else { return }
        errors[docID] = nil
        append(docID, work: .speakers)
    }

    func retrySave(_ docID: UUID) {
        guard !preparingToQuit, pendingSaves[docID] != nil, currentDocumentID != docID,
              !pending.contains(where: { $0.documentID == docID }),
              library?.document(id: docID) != nil else { return }
        append(docID, work: .save)
    }

    func cancelCurrent() {
        guard let currentDocumentID else { return }
        cancel(currentDocumentID)
    }

    func cancel(_ docID: UUID) {
        if currentDocumentID == docID {
            transcriber.cancelCurrent()
            processingTask?.cancel()
        } else if let job = pending.first(where: { $0.documentID == docID }) {
            pending.removeAll { $0.documentID == docID }
            pendingCount = pending.count
            // A completed result waiting for a save is kept until retry or deletion.
            guard pendingSaves[docID] == nil else { return }
            let speakersOnly: Bool
            if case .speakers = job.work { speakersOnly = true } else { speakersOnly = false }
            saveFailure("Processing was cancelled.", for: docID, speakersOnly: speakersOnly)
        }
    }

    /// Stop admitting work, drain cancellation, and save completed results before exit.
    /// Queued requests become cancelled documents; retries never start a model here.
    func prepareToQuit() async -> Bool {
        guard !preparingToQuit else { return false }
        preparingToQuit = true
        defer { preparingToQuit = false }
        let queued = pending
        pending = []
        pendingCount = 0
        for job in queued where pendingSaves[job.documentID] == nil {
            let speakersOnly: Bool
            if case .speakers = job.work { speakersOnly = true } else { speakersOnly = false }
            saveFailure("Processing was cancelled when quitting.", for: job.documentID, speakersOnly: speakersOnly)
        }
        transcriber.cancelCurrent()
        processingTask?.cancel()
        await processingTask?.value
        for id in Array(pendingSaves.keys) {
            switch pendingSaves[id] {
            case .beginTranscription:
                saveFailure("Transcription was cancelled when quitting.", for: id, speakersOnly: false)
            case .beginAnalysis:
                saveFailure("Speaker analysis was cancelled when quitting.", for: id, speakersOnly: true)
            default:
                await retryRetainedSave(id)
            }
        }
        return pendingSaveIDs.isEmpty
    }

    private func canEnqueue(_ id: UUID) -> Bool {
        currentDocumentID != id && pendingSaves[id] == nil
            && !pending.contains { $0.documentID == id }
    }

    private func append(_ docID: UUID, work: Work) {
        pending.append(Job(documentID: docID, work: work))
        pendingCount = pending.count
        pump()
    }

    private func pump() {
        guard !preparingToQuit, currentDocumentID == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        currentDocumentID = job.documentID
        currentJobID = job.id
        pendingCount = pending.count
        processingTask = Task {
            switch job.work {
            case .transcription(let partial):
                await transcribe(job.documentID, allowPartialAudio: partial)
            case .speakers:
                await analyzeSpeakers(job.documentID, forceImports: true)
            case .save:
                await retryRetainedSave(job.documentID)
            }
            progress[job.documentID] = nil
            livePreview[job.documentID] = nil
            currentDocumentID = nil
            currentJobID = nil
            processingTask = nil
            pump()
        }
    }

    private func transcribe(_ docID: UUID, allowPartialAudio: Bool) async {
        guard let library, let options = optionsProvider?(),
              var original = library.document(id: docID) else { return }
        original.status = .transcribing
        original.failureReason = nil
        guard library.update(original) else {
            retain(.beginTranscription(allowPartialAudio: allowPartialAudio), for: docID)
            return
        }
        clearPendingSave(docID)
        progress[docID] = 0
        let jobID = currentJobID
        do {
            try Task.checkCancellation()
            let folder = library.folder(for: docID)
            let inputs = try Self.transcriptionInputs(for: original, folder: folder, allowPartialAudio: allowPartialAudio)
            var omitted = inputs.omitted
            try await transcriber.load(model: options.model)
            var allSegments: [TranscriptSegment] = []
            var completedTracks = 0
            let trackCount = Double(inputs.tracks.count)
            for (index, track) in inputs.tracks.enumerated() {
                try Task.checkCancellation()
                guard library.document(id: docID) != nil else { return }
                let base = Double(index) / trackCount
                var segments: [TranscriptSegment]
                do {
                    segments = try await transcriber.transcribe(
                        file: folder.appendingPathComponent(track.fileName), source: track.source,
                        language: options.language, translate: options.translate,
                        onProgress: { [weak self] fraction, text in
                            Task { @MainActor in
                                guard let self, self.currentJobID == jobID,
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
                    guard allowPartialAudio else { throw error }
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
            await saveTranscript(docID, baseline: original, segments: allSegments, options: options,
                                 warning: Self.recoveryWarning(omitted: omitted))
        } catch {
            saveFailure(Task.isCancelled ? "Transcription was cancelled." : error.localizedDescription,
                        for: docID, speakersOnly: false)
        }
    }

    private func saveTranscript(_ docID: UUID, baseline: ScribeDocument, segments: [TranscriptSegment],
                                options: Options, warning: String?) async {
        guard let library, var fresh = library.document(id: docID) else { return }
        let replacedTranscript = Self.canReplaceTranscript(fresh, basedOn: baseline)
        fresh = Self.applyingTranscript(segments, to: fresh, basedOn: baseline, transcriptionWarning: warning)
        fresh.status = .ready
        fresh.modelUsed = options.model
        fresh.language = options.language
        fresh.failureReason = nil
        guard library.update(fresh) else {
            retain(.transcript(baseline: baseline, segments: segments, options: options, warning: warning), for: docID)
            return
        }
        clearPendingSave(docID)
        if Task.isCancelled || preparingToQuit { return }
        await analyzeSpeakers(docID, forceImports: false, applyCleanup: replacedTranscript)
    }

    private func analyzeSpeakers(_ docID: UUID, forceImports: Bool, applyCleanup: Bool = false) async {
        guard let library, let options = optionsProvider?(),
              var baseline = library.document(id: docID) else { return }
        guard !Task.isCancelled else {
            saveFailure("Speaker analysis was cancelled.", for: docID, speakersOnly: true)
            return
        }
        baseline.speakerAnalysisStatus = .running
        baseline.speakerAnalysisError = nil
        guard library.update(baseline) else {
            retain(.beginAnalysis(forceImports: forceImports, applyCleanup: applyCleanup), for: docID)
            return
        }
        clearPendingSave(docID)
        livePreview[docID] = "Analyzing remote speakers locally…"
        progress[docID] = nil
        let analysis = await SpeakerAnalysis.run(
            baseline, folder: library.folder(for: docID), model: options.speakerModel,
            analyzeImports: forceImports || options.analyzeImports,
            splitAtSpeakerChanges: baseline.speakerEditsApplied != true, infer: inferSpeakers
        )
        guard !Task.isCancelled else {
            saveFailure("Speaker analysis was cancelled.", for: docID, speakersOnly: true)
            return
        }
        saveAnalysis(docID, baseline: baseline, analysis: analysis, applyCleanup: applyCleanup)
    }

    private func saveAnalysis(_ docID: UUID, baseline: ScribeDocument, analysis: ScribeDocument, applyCleanup: Bool) {
        guard let library, var fresh = library.document(id: docID) else { return }
        let unchanged = fresh.segments == baseline.segments && fresh.speakers == baseline.speakers
            && fresh.microphoneSpeakerName == baseline.microphoneSpeakerName
        fresh = SpeakerAnalysis.applying(analysis, to: fresh, basedOn: baseline)
        if applyCleanup, unchanged { fresh.segments = cleanup(fresh.segments) }
        if let eventID = fresh.calendarEventID {
            fresh.knownSpeakers = Self.mergedKnownSpeakers(
                fresh.knownSpeakers, adding: attendeeNamesProvider?(eventID) ?? [],
                limit: max(8, (fresh.knownSpeakers ?? []).count)
            )
        }
        guard library.update(fresh) else {
            retain(.analysis(baseline: baseline, result: analysis, applyCleanup: applyCleanup), for: docID)
            return
        }
        clearPendingSave(docID)
        if fresh.status == .ready { exportAutomatically(fresh) }
    }

    private func saveFailure(_ message: String, for docID: UUID, speakersOnly: Bool) {
        guard let library, var fresh = library.document(id: docID) else { return }
        if speakersOnly {
            fresh.speakerAnalysisStatus = .failed
            fresh.speakerAnalysisError = message
        } else {
            fresh.status = .failed
            fresh.failureReason = message
        }
        guard library.update(fresh) else {
            retain(.failure(message: message, speakersOnly: speakersOnly), for: docID)
            return
        }
        clearPendingSave(docID)
        errors[docID] = message
    }

    private func retain(_ result: PendingSave, for docID: UUID) {
        pendingSaves[docID] = result
        pendingSaveIDs.insert(docID)
        errors[docID] = (library?.lastError ?? "The recording could not be saved.")
            + " Retry saving to continue. Any completed work is retained while this save is pending."
    }

    private func clearPendingSave(_ docID: UUID) {
        pendingSaves[docID] = nil
        pendingSaveIDs.remove(docID)
        errors[docID] = nil
    }

    private func retryRetainedSave(_ docID: UUID) async {
        guard !Task.isCancelled, let result = pendingSaves[docID], library?.document(id: docID) != nil else { return }
        switch result {
        case .beginTranscription(let partial):
            await transcribe(docID, allowPartialAudio: partial)
        case .transcript(let baseline, let segments, let options, let warning):
            await saveTranscript(docID, baseline: baseline, segments: segments, options: options, warning: warning)
        case .beginAnalysis(let forceImports, let applyCleanup):
            await analyzeSpeakers(docID, forceImports: forceImports, applyCleanup: applyCleanup)
        case .analysis(let baseline, let result, let applyCleanup):
            saveAnalysis(docID, baseline: baseline, analysis: result, applyCleanup: applyCleanup)
        case .failure(let message, let speakersOnly):
            saveFailure(message, for: docID, speakersOnly: speakersOnly)
        }
    }

    private func removeDeletedDocuments(keeping ids: Set<UUID>) {
        pending.removeAll { !ids.contains($0.documentID) }
        pendingCount = pending.count
        for id in pendingSaveIDs.subtracting(ids) { clearPendingSave(id) }
        errors = errors.filter { ids.contains($0.key) }
        if let currentDocumentID, !ids.contains(currentDocumentID) {
            transcriber.cancelCurrent()
            processingTask?.cancel()
            progress[currentDocumentID] = nil
            livePreview[currentDocumentID] = nil
        }
    }
}
