import Foundation
import SwiftUI
import AVFoundation

/// Each document owns a folder containing an atomic manifest and progressive media files.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [ScribeDocument] = []
    @Published var lastError: String?
    @Published private(set) var pendingRecordingSaveIDs: Set<UUID> = []
    private var pendingRecordingSaves: [UUID: PendingRecordingSave] = [:] {
        didSet { pendingRecordingSaveIDs = Set(pendingRecordingSaves.keys) }
    }

    var hasPendingRecordingSaves: Bool { !pendingRecordingSaveIDs.isEmpty }

    nonisolated static let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scribe/library", isDirectory: true)
    let storageURL: URL

    static func folder(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func folder(for id: UUID) -> URL {
        storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for track: AudioTrack, in doc: ScribeDocument) -> URL {
        folder(for: doc.id).appendingPathComponent(track.fileName)
    }

    init(baseURL: URL = LibraryStore.baseURL) {
        storageURL = baseURL
        load()
        let loadError = lastError
        recoverCrashedRecordings()
        lastError = loadError ?? lastError
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)) ?? []
        documents = folders.compactMap { folder in
            let json = folder.appendingPathComponent("document.json")
            guard FileManager.default.fileExists(atPath: json.path) else {
                let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                if children.contains(where: { ["caf", "wav", "m4a", "mov", "mp4"].contains($0.pathExtension.lowercased()) }) {
                    lastError = "A recording has media but no document.json. Its files remain in \(folder.path)."
                }
                return nil
            }
            do { return try decoder.decode(ScribeDocument.self, from: Data(contentsOf: json)) }
            catch {
                lastError = "A recording could not be opened. Its files remain in \(folder.path). \(error.localizedDescription)"
                return nil
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func recoverCrashedRecordings() {
        for var doc in documents where doc.status == .ready && doc.speakerAnalysisStatus == .running {
            doc.speakerAnalysisStatus = .failed
            doc.speakerAnalysisError = "Speaker analysis was interrupted. Retry speaker analysis to continue."
            publishRecovery(doc)
        }
        for var doc in documents where [.recording, .transcribing, .queued].contains(doc.status) {
            let folder = folder(for: doc.id)
            // Keep missing track references in the manifest so a failed capture is diagnosable.
            doc.duration = max(doc.duration, doc.tracks.map {
                ($0.startOffset ?? 0) + audioDuration(of: folder.appendingPathComponent($0.fileName))
            }.max() ?? 0)
            doc.status = .recovered
            doc.recoveredAt = doc.recoveredAt ?? Date()
            doc.failureReason = "Recording was interrupted. Available audio and video have been kept. Review the files before retrying transcription."
            publishRecovery(doc)
        }
    }

    private func publishRecovery(_ doc: ScribeDocument) {
        guard !update(doc), let index = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        // A save failure cannot make a session from an earlier process active again.
        // Keep the on-disk crash marker and expose a retryable state in this process.
        var recovered = doc
        let saveError = lastError ?? "The recovery state could not be saved."
        if recovered.status == .recovered {
            recovered.failureReason = (recovered.failureReason ?? "") + " " + saveError
        } else {
            recovered.speakerAnalysisError = (recovered.speakerAnalysisError ?? "") + " " + saveError
        }
        documents[index] = recovered
    }

    @discardableResult
    func add(_ doc: ScribeDocument) -> Bool { update(doc) }

    /// Publish only after the atomic save succeeds. Callers can retain a pending edit on failure.
    @discardableResult
    func update(_ doc: ScribeDocument) -> Bool {
        var document = doc
        if let previous = self.document(id: document.id),
           let summary = previous.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           document.summary == previous.summary,
           SummaryService.sourceText(document) != SummaryService.sourceText(previous) {
            document.summaryIsStale = true
        }
        do {
            let folder = folder(for: document.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: folder.appendingPathComponent("document.json"), options: .atomic)
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index] = document
            } else {
                documents.append(document)
            }
            documents.sort { $0.createdAt > $1.createdAt }
            lastError = nil
            return true
        } catch {
            lastError = "Could not save \(document.title). \(error.localizedDescription)"
            return false
        }
    }

    /// A finished capture must stop looking active even if its final manifest cannot be saved.
    /// Keep the old crash marker on disk, expose the preserved media, and block deletion until retry.
    @discardableResult
    func finalizeRecording(_ doc: ScribeDocument) -> Bool {
        finalizeRecording(doc, retryDisposition: .keep)
    }

    @discardableResult
    func finalizeRecording(
        _ doc: ScribeDocument,
        retryDisposition: PendingRecordingSave.Disposition
    ) -> Bool {
        if update(doc) {
            pendingRecordingSaves[doc.id] = nil
            return true
        }
        guard let index = documents.firstIndex(where: { $0.id == doc.id }) else { return false }
        var recovered = doc
        recovered.status = .recovered
        recovered.recoveredAt = recovered.recoveredAt ?? Date()
        recovered.failureReason = "The recording stopped, but its final details have not been saved. " + (lastError ?? "Retry saving.")
        documents[index] = recovered
        pendingRecordingSaves[doc.id] = PendingRecordingSave(document: doc, disposition: retryDisposition)
        return false
    }

    func hasPendingRecordingSave(_ id: UUID) -> Bool {
        pendingRecordingSaves[id] != nil
    }

    func retryPendingRecordingSave(_ id: UUID) -> PendingRecordingSave.Disposition? {
        guard let pending = pendingRecordingSaves[id] else { return nil }
        // Capture owns media facts and terminal status. Keep edits that can be
        // made while the manifest save is pending, including title and notes.
        var document = self.document(id: id) ?? pending.document
        document.status = pending.document.status
        document.failureReason = pending.document.failureReason
        document.recoveredAt = pending.document.recoveredAt
        document.duration = pending.document.duration
        document.tracks = pending.document.tracks
        document.videoTracks = pending.document.videoTracks
        guard finalizeRecording(document, retryDisposition: pending.disposition) else { return nil }
        return pending.disposition
    }

    func document(id: UUID) -> ScribeDocument? {
        documents.first { $0.id == id }
    }

    @discardableResult
    func delete(_ doc: ScribeDocument) -> Bool {
        guard !hasPendingRecordingSave(doc.id) else {
            lastError = "Retry saving this stopped recording before deleting it."
            return false
        }
        guard document(id: doc.id)?.status != .recording else {
            lastError = "Stop the recording before deleting it."
            return false
        }
        do {
            let folder = folder(for: doc.id)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            documents.removeAll { $0.id == doc.id }
            lastError = nil
            return true
        } catch {
            lastError = "Could not delete \(doc.title). \(error.localizedDescription)"
            return false
        }
    }
}

struct PendingRecordingSave {
    enum Disposition {
        case keep
        case enqueue
        case discard
    }

    var document: ScribeDocument
    var disposition: Disposition
}

func audioDuration(of url: URL) -> TimeInterval {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
    return Double(file.length) / file.fileFormat.sampleRate
}
