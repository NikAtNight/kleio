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

    func configure(
        library: LibraryStore,
        modelManager: ModelManager,
        replacementStore: ReplacementStore
    ) {
        self.library = library
        self.modelManager = modelManager
        self.replacementStore = replacementStore
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
                        NSLog("Scribe: speaker recognition skipped: %@", error.localizedDescription)
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
            if !detectedSpeakers.isEmpty {
                var known = doc.knownSpeakers ?? []
                for speaker in detectedSpeakers where !known.contains(speaker) { known.append(speaker) }
                doc.knownSpeakers = known
            }
            doc.status = .ready
            doc.modelUsed = model
            doc.language = language.isEmpty ? nil : language
        } catch {
            doc.status = .failed
            doc.failureReason = error.localizedDescription
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
            library.update(fresh)
            if fresh.status == .ready {
                Exporter.exportAutomaticallyIfNeeded(fresh)
            }
        }
    }
}
