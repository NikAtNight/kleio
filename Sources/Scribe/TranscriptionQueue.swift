import Foundation
import SwiftUI

/// Serial transcription queue: documents are processed one at a time (the
/// Whisper pipeline is memory-heavy), with per-document progress published
/// for the UI. Meeting recordings transcribe each track separately and merge
/// the segments into one chronological You/Them dialogue.
@MainActor
final class TranscriptionQueue: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var livePreview: [UUID: String] = [:]
    @Published private(set) var pendingCount = 0

    let transcriber = Transcriber()
    let speakerDiarizer = SpeakerDiarizer()

    private var pending: [UUID] = []
    private var isProcessing = false
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

    func enqueue(_ docID: UUID) {
        guard !pending.contains(docID) else { return }
        if var doc = library?.document(id: docID), doc.status != .queued {
            doc.status = .queued
            library?.update(doc)
        }
        pending.append(docID)
        pendingCount = pending.count
        pump()
    }

    func cancelCurrent() {
        transcriber.cancelCurrent()
    }

    private func pump() {
        guard !isProcessing, !pending.isEmpty else { return }
        isProcessing = true
        let docID = pending.removeFirst()
        pendingCount = pending.count
        Task {
            await process(docID)
            isProcessing = false
            pump()
        }
    }

    private func process(_ docID: UUID) async {
        guard let library, let modelManager,
              var doc = library.document(id: docID) else { return }

        doc.status = .transcribing
        library.update(doc)
        progress[docID] = 0

        let language = UserDefaults.standard.string(forKey: "language") ?? ""
        let translate = UserDefaults.standard.bool(forKey: "translate")
        let recognizeSpeakers = UserDefaults.standard.bool(forKey: "automaticSpeakerRecognition")
        let model = modelManager.selectedVariant
        let startedAt = Date()

        do {
            try await transcriber.load(model: model)

            var allSegments: [TranscriptSegment] = []
            let folder = LibraryStore.folder(for: doc.id)
            let tracks = doc.tracks
            for (index, track) in tracks.enumerated() {
                let url = folder.appendingPathComponent(track.fileName)
                let trackCount = Double(tracks.count)
                let base = Double(index) / trackCount
                var segments = try await transcriber.transcribe(
                    file: url,
                    source: track.source,
                    language: language.isEmpty ? nil : language,
                    translate: translate,
                    onProgress: { [weak self] fraction, text in
                        Task { @MainActor in
                            self?.progress[docID] = base + fraction / trackCount
                            self?.livePreview[docID] = text
                        }
                    }
                )
                if let speaker = track.speakerName {
                    for segmentIndex in segments.indices {
                        segments[segmentIndex].speaker = speaker
                    }
                } else if recognizeSpeakers,
                          !(doc.isMeetingRecording && track.source == .microphone) {
                    livePreview[docID] = "Recognizing speakers locally…"
                    progress[docID] = base + 0.92 / trackCount
                    do {
                        let intervals = try await speakerDiarizer.intervals(for: url)
                        segments = SpeakerDiarizer.assignSpeakers(to: segments, using: intervals)
                    } catch {
                        // Diarization is an enhancement. A missing model or
                        // unsupported audio must never discard a good Whisper
                        // transcript.
                        DiagLog.log("speaker recognition skipped for document %@: %@", docID.uuidString, error.localizedDescription)
                    }
                }
                allSegments.append(contentsOf: segments)
            }

            allSegments.sort { $0.start < $1.start }
            if let replacementStore {
                allSegments = replacementStore.apply(to: allSegments)
            }
            doc.segments = allSegments
            let detectedSpeakers = allSegments.compactMap(\.speaker).filter { !$0.isEmpty }
            // Detected speakers are real; never cap them. Only the calendar
            // suggestions below are limited.
            doc.knownSpeakers = Self.mergedKnownSpeakers(doc.knownSpeakers, adding: detectedSpeakers, limit: Int.max)
            if let eventID = doc.calendarEventID {
                let attendeeNames = attendeeNamesProvider?(eventID) ?? []
                doc.knownSpeakers = Self.mergedKnownSpeakers(
                    doc.knownSpeakers,
                    adding: attendeeNames,
                    limit: max(8, (doc.knownSpeakers ?? []).count)
                )
            }
            doc.status = .ready
            doc.modelUsed = model
            doc.language = language.isEmpty ? nil : language
            DiagLog.log(
                "transcription completed for document %@ using model %@: %.1fs, %d segments",
                docID.uuidString,
                model,
                Date().timeIntervalSince(startedAt),
                allSegments.count
            )
        } catch {
            doc.status = .failed
            doc.failureReason = error.localizedDescription
            DiagLog.log(
                "transcription failed for document %@ using model %@ after %.1fs: %@",
                docID.uuidString,
                model,
                Date().timeIntervalSince(startedAt),
                error.localizedDescription
            )
        }

        progress[docID] = nil
        livePreview[docID] = nil
        // Re-read in case the user renamed/edited while transcribing.
        if var fresh = library.document(id: docID) {
            fresh.segments = doc.segments
            fresh.status = doc.status
            fresh.modelUsed = doc.modelUsed
            fresh.language = doc.language
            fresh.failureReason = doc.failureReason
            fresh.knownSpeakers = Self.mergedKnownSpeakers(fresh.knownSpeakers, adding: doc.knownSpeakers ?? [], limit: Int.max)
            library.update(fresh)
            if fresh.status == .ready {
                Exporter.exportAutomaticallyIfNeeded(fresh)
            }
        }
    }
}
